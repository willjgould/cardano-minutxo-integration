{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Ledger as Ledger
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Read.Ledger.Eras as Read
import Cardano.Read.Ledger.Tx.Outputs (Outputs (..))
import qualified Cardano.Wallet.Primitive.Ledger.Convert as Wallet
import qualified Cardano.Wallet.Primitive.Ledger.Read.Tx.Features.Outputs as Wallet
import Control.Monad (unless)
import GHC.Exts (fromList)
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    putStrLn "RUN wallet assertions: output read-write roundtrip preserves kind, address and assets"
    paymentKeyHash <-
        either (die . show) pure $
            Api.deserialiseFromRawBytesHex
                "11111111111111111111111111111111111111111111111111111111"
    policyId <-
        either (die . show) pure $
            Api.deserialiseFromRawBytesHex
                "22222222222222222222222222222222222222222222222222222222"
    assetName <- either (die . show) pure $ Api.deserialiseFromRawBytes Api.AsAssetName "offer"
    let era = Api.ShelleyBasedEraDijkstra
        address =
            Api.makeShelleyAddressInEra
                era
                (Api.Testnet (Api.NetworkMagic 42))
                (Api.PaymentCredentialByKey paymentKeyHash)
                Api.NoStakeAddress
        tokens = Api.valueFromList [(Api.AssetId policyId assetName, Api.Quantity 7)]
        tokensAndAda = tokens <> Api.lovelaceToValue (Ledger.Coin 2_000_000)
        makeOutput value =
            Api.toShelleyTxOut era $
                Api.TxOut address value Api.TxOutDatumNone Api.ReferenceScriptNone
        storeBacked value =
            makeOutput (Api.TxOutValueStoreBacked (Core.ApplicationAssets (Api.toMaryValue value)))
    checkRoundtrip "store-backed, seven tokens and zero ADA" StoreBacked (storeBacked tokens)
    checkRoundtrip
        "implicit-deposit, seven tokens and 2000000 lovelace"
        ImplicitDeposit
        (makeOutput (Api.TxOutValueShelleyBased era (Api.toMaryValue tokensAndAda)))
    checkRoundtrip
        "store-backed, seven tokens and 2000000 lovelace"
        StoreBacked
        (storeBacked tokensAndAda)
    putStrLn "PASS: wallet output roundtrips preserve kind, address and exact assets"

data ExpectedKind = ImplicitDeposit | StoreBacked

checkRoundtrip :: String -> ExpectedKind -> Core.TxOut Read.Dijkstra -> IO ()
checkRoundtrip label expectedKind original = do
    expectKind (label <> " fixture") expectedKind original
    case Wallet.getOutputs @Read.Dijkstra (Outputs (fromList [original])) of
        [walletOutput] -> do
            let actual = Wallet.toBabbageTxOutInEra @Read.Dijkstra walletOutput
            expectKind label expectedKind actual
            unless (actual == original) $
                die $
                    "FAIL: "
                        <> label
                        <> ": roundtrip changed the ledger output; expected "
                        <> show original
                        <> ", got "
                        <> show actual
        outputs ->
            die $ "FAIL: " <> label <> ": expected one wallet output, got " <> show (length outputs)

expectKind :: String -> ExpectedKind -> Core.TxOut Read.Dijkstra -> IO ()
expectKind label expectedKind output = case (expectedKind, output) of
    (StoreBacked, Core.StoreBackedTxOut{}) -> pure ()
    (ImplicitDeposit, Core.ImplicitDepositTxOut{}) -> pure ()
    (StoreBacked, Core.ImplicitDepositTxOut{}) ->
        die $ "FAIL: " <> label <> ": expected store-backed output, got implicit-deposit output"
    (ImplicitDeposit, Core.StoreBackedTxOut{}) ->
        die $ "FAIL: " <> label <> ": expected implicit-deposit output, got store-backed output"
