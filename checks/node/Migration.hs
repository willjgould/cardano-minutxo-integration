{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Migration (verifyMigration) where

import qualified Cardano.Api as Api
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin)
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.State as State
import qualified Cardano.Ledger.State.UTxOs.Allocations.UTxO as Unspent
import Control.Monad (forM, unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE, withExceptT)
import Data.Aeson (FromJSON (..), Value, eitherDecodeFileStrict, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import Lens.Micro ((^.))
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Type as Network
import System.FilePath (takeDirectory, (</>))

data ExpectedFixture = ExpectedFixture
    { expectedInput :: Api.TxIn
    , expectedValue :: Coin
    , expectedMinimum :: Coin
    , expectedLegacyCount :: Int
    , expectedExplicitCount :: Int
    , expectedDepositTotal :: Coin
    , expectedPoint :: Api.ChainPoint
    }

instance FromJSON ExpectedFixture where
    parseJSON = withObject "migration fixture expectations" $ \o ->
        ExpectedFixture
            <$> o .: "txIn"
            <*> o .: "totalLovelace"
            <*> o .: "legacyMinimumAtCreation"
            <*> o .: "legacyOutputs"
            <*> o .: "explicitOutputs"
            <*> o .: "totalDeposit"
            <*> (o .: "target" >>= parsePoint)

parsePoint :: Value -> Parser Api.ChainPoint
parsePoint = withObject "tip" $ \o -> Api.ChainPoint <$> o .: "slot" <*> o .: "hash"

readJSON :: (FromJSON a) => FilePath -> IO a
readJSON path = eitherDecodeFileStrict path >>= either (fail . ((path <> ": ") <>)) pure

-- The baseline and expectations were captured independently with the old node
-- and CLI. This checks the state served by the restarted node, not the migration
-- tool's readiness manifest. The runner separately proves snapshot loading.
verifyMigration :: FilePath -> FilePath -> FilePath -> IO ()
verifyMigration socket baselineDirectory evidenceFile = do
    expected <- readJSON (takeDirectory baselineDirectory </> "expected.json")
    baselineTip <- readJSON (baselineDirectory </> "tip.json")
    baselinePoint <- either fail pure $ parseEither parsePoint baselineTip
    baselineUTxO <- readJSON (baselineDirectory </> "utxo.json")
    unless (baselinePoint == expectedPoint expected) $
        fail "The independently captured baseline tip differs from the pinned fixture target"
    let era = Api.ShelleyBasedEraDijkstra
        connection =
            Api.LocalNodeConnectInfo
                { Api.localConsensusModeParams = Api.CardanoModeParams (Api.EpochSlots 50)
                , Api.localNodeNetworkId = Api.Testnet (Api.NetworkMagic 42)
                , Api.localNodeSocketPath = Api.File socket
                }
    queried <- Api.executeLocalStateQueryExpr connection Network.VolatileTip $ runExceptT $ do
        point <- withExceptT show $ ExceptT Api.queryChainPoint
        eraUTxO <- withExceptT show $ ExceptT $ Api.queryUtxo era Api.QueryUTxOWhole
        utxo <- either (throwE . show) pure eraUTxO
        allocations <-
            withExceptT Api.displayError $
                ExceptT $
                    Api.queryUTxOAllocations era (Map.keysSet $ Api.unUTxO utxo)
        depositTotal <- withExceptT Api.displayError $ ExceptT $ Api.queryUTxODepositTotal era
        pure (point, utxo, allocations, depositTotal)
    (point, utxo, allocations, depositTotal) <-
        either (fail . show) pure queried >>= either fail pure
    unless (point == baselinePoint) $
        fail $
            "Migrated node tip differs from the exact baseline: " <> show point
    unless (utxo == baselineUTxO) $
        fail "Migration changed the whole UTxO relative to the old node's baseline"
    let entries = State.unAllocations allocations
        projectedUTxO :: Api.UTxO Api.DijkstraEra
        projectedUTxO =
            Api.UTxO $
                Map.mapKeys Api.fromShelleyTxIn $
                    Map.map (Api.fromShelleyTxOut era . Unspent.toTxOut) entries
    unless (projectedUTxO == utxo) $
        fail "Allocation keys or outputs differ from the UTxO at the acquired point"
    legacyCount <- fmap sum $ forM (Map.toList entries) $ \(input, entry) ->
        case Unspent.toTxOut entry of
            Core.LegacyTxOut{} -> case State.legacyMinimumAtCreation entry of
                SNothing -> fail $ "Surviving legacy output has no historical minimum: " <> show input
                SJust minimumAtCreation -> do
                    unless (minimumAtCreation >= 0 && minimumAtCreation <= Unspent.toTxOut entry ^. Core.coinTxOutL) $
                        fail $
                            "Invalid recorded legacy minimum: " <> show input
                    unless (Unspent.depositAmount entry == 0) $
                        fail "A legacy minimum was incorrectly counted as a separate deposit"
                    pure (1 :: Int)
            Core.NewTxOut{} -> do
                unless (State.legacyMinimumAtCreation entry == SNothing) $
                    fail $
                        "Explicit output carries conflicting legacy metadata: " <> show input
                pure 0
    let explicitCount = Map.size entries - legacyCount
        summedDeposits = foldMap Unspent.depositAmount entries
    unless (legacyCount == expectedLegacyCount expected && explicitCount == expectedExplicitCount expected) $
        fail "Migrated output kinds or counts differ from the pinned fixture"
    unless (depositTotal == summedDeposits && depositTotal == expectedDepositTotal expected) $
        fail "The node's cached separate-deposit total differs from the allocations or baseline"
    entry <-
        maybe (fail "The historical Conway output is missing") pure $
            Map.lookup (Api.toShelleyTxIn $ expectedInput expected) entries
    totalValue <- case Unspent.toTxOut entry of
        Core.LegacyTxOut{} -> pure $ Unspent.toTxOut entry ^. Core.coinTxOutL
        Core.NewTxOut{} -> fail "Migration changed the historical Conway output's representation"
    recordedMinimum <- case State.legacyMinimumAtCreation entry of
        SNothing -> fail "The historical Conway output has no recorded minimum"
        SJust amount -> pure amount
    unless (totalValue == expectedValue expected && recordedMinimum == expectedMinimum expected) $
        fail "The historical Conway output's total ADA or creation minimum differs from the independent expectation"
    LBS.writeFile evidenceFile $
        encode $
            object
                [ "status" .= ("verified" :: String)
                , "point" .= point
                , "utxoCount" .= Map.size entries
                , "legacyOutputs" .= legacyCount
                , "explicitOutputs" .= explicitCount
                , "totalDeposit" .= depositTotal
                , "historicalInput" .= expectedInput expected
                , "totalLovelace" .= totalValue
                , "legacyMinimumAtCreation" .= recordedMinimum
                , "wholeUTxOUnchanged" .= True
                , "allocationsMatchUTxO" .= True
                , "allLegacyMinimaKnown" .= True
                , "depositTotalVerified" .= True
                ]
    putStrLn "PASS: restarted node preserves the exact UTxO and historical minima at the pinned tip"
