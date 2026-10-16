{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module TokenFunding (fundTokens, LiveState, queryDijkstra, queryLedgerState, depositStore, totalAda, verifyStore) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental as Era
import qualified Cardano.Api.Experimental.AnyScriptWitness as Witness
import qualified Cardano.Api.Experimental.Tx as Exp
import Cardano.Ledger.Binary (mkSized)
import Cardano.Ledger.Coin (Coin)
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra.Rules as Dijkstra
import qualified Cardano.Ledger.Dijkstra.UTxODeposit.TopTx as TopTx
import qualified Cardano.Ledger.Keys as Keys
import qualified Cardano.Ledger.Shelley.AdaPots as AdaPots
import qualified Cardano.Ledger.Shelley.LedgerState as LedgerState
import qualified Cardano.Ledger.Shelley.Scripts as Native
import qualified Cardano.Ledger.State as State
import Cardano.Ledger.StrictlyPositiveCoin (mkStrictlyPositiveCoin)
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Type as Network

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (object, (.=))
import qualified Data.ByteString as BS
import Data.Function ((&))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Lens.Micro ((.~), (^.))
import Submission (queryUTxO, writeEvidence)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Timeout (timeout)

-- Before submitting the nested examples, create two real token-only inputs.
-- The genesis payment key funds and authorizes the native mint; an independent
-- token owner receives the outputs and will sign the token child.
fundTokens :: FilePath -> FilePath -> IO ()
fundTokens directory socket = do
    hSetBuffering stdout LineBuffering
    putStrLn "RUN node assertions: fund two token-only store-backed inputs for the nested examples"
    payment <-
        Api.readFileTextEnvelope (Api.File (directory </> "payment.skey"))
            >>= either (fail . show) pure
    addressText <- Text.strip <$> Text.readFile (directory </> "address.txt")
    source <-
        maybe (fail "Invalid genesis payment address") pure $
            Api.deserialiseAddress Api.AsAddressAny addressText
    destination <- either (fail . show) pure (Api.anyAddressInEra Api.DijkstraEra source)
    tokenOwnerAddressText <- Text.strip <$> Text.readFile (directory </> "token-owner-address.txt")
    tokenOwnerAddress <-
        maybe (fail "Invalid token owner address") pure $
            Api.deserialiseAddress Api.AsAddressAny tokenOwnerAddressText
    tokenDestination <- either (fail . show) pure (Api.anyAddressInEra Api.DijkstraEra tokenOwnerAddress)
    let connection =
            Api.LocalNodeConnectInfo
                { Api.localConsensusModeParams = Api.CardanoModeParams (Api.EpochSlots 50)
                , Api.localNodeNetworkId = Api.Testnet (Api.NetworkMagic 42)
                , Api.localNodeSocketPath = Api.File socket
                }
    pparams <- queryDijkstra connection Api.QueryProtocolParameters
    before <- queryLedgerState connection
    unless (depositStore before == State.DepositStore 0 mempty) $
        fail "Expected an empty deposit store on the fresh chain"
    Api.UTxO funded <- queryUTxO connection (Api.QueryUTxOByAddress (Set.singleton source))
    (input, inputValue) <- case Map.toList funded of
        [(txIn, Api.TxOut _ value Api.TxOutDatumNone Api.ReferenceScriptNone)] ->
            pure (txIn, Api.txOutValueToValue value)
        _ -> fail $ "Expected exactly one plain genesis output; got " <> show funded
    unless (inputValue == Api.lovelaceToValue 900_000_000_000) $
        fail $
            "Unexpected genesis funding: " <> show inputValue
    assetName <- either (fail . show) pure (Api.deserialiseFromRawBytes Api.AsAssetName "offer")
    let era = Api.ShelleyBasedEraDijkstra
        Api.PaymentKeyHash keyHash = Api.verificationKeyHash (Api.getVerificationKey payment)
        policyScript :: Era.SimpleScript (Api.ShelleyLedgerEra Api.DijkstraEra)
        policyScript = Era.SimpleScript (Native.mkRequireSignature (Keys.asWitness keyHash))
        policyId = Api.PolicyId (Api.fromShelleyScriptHash (Era.hashSimpleScript @Api.DijkstraEra policyScript))
        mint =
            Exp.TxMintValue $
                Map.singleton
                    policyId
                    ( Api.PolicyAssets (Map.singleton assetName (Api.Quantity 14))
                    , Witness.AnyScriptWitnessSimple (Era.SScript policyScript)
                    )
        tokens = Api.valueFromList [(Api.AssetId policyId assetName, Api.Quantity 7)]
        fee = 1_000_000
        -- Price the exact output encoding with the node's protocol parameters.
        -- This fixture supplies the resulting amount explicitly to the API;
        -- it does not exercise automatic transaction balancing.
        perOutputDeposit =
            Dijkstra.requiredUTxODeposit pparams $
                mkSized
                    (Core.eraProtVerLow @(Api.ShelleyLedgerEra Api.DijkstraEra))
                    (Api.toShelleyTxOut era tokenOutput)
        deposit = perOutputDeposit <> perOutputDeposit
        inputCoin = Api.selectLovelace inputValue
        -- Explicitly pay the store deposit; returning it as change would hide
        -- missing ledger accounting. Each example gets a separate token input.
        changeCoin = inputCoin - fee - deposit
        tokenOutput :: Api.TxOut Api.CtxUTxO Api.DijkstraEra
        tokenOutput =
            Api.TxOut
                tokenDestination
                (Api.TxOutValueStoreBacked (Core.ApplicationAssets (Api.toMaryValue tokens)))
                Api.TxOutDatumNone
                Api.ReferenceScriptNone
        changeOutput =
            Api.TxOut
                destination
                (Api.lovelaceToTxOutValue era changeCoin)
                Api.TxOutDatumNone
                Api.ReferenceScriptNone
        outputs = [tokenOutput, tokenOutput, changeOutput]
    positiveDeposit <- maybe (fail "Invalid positive store deposit") pure (mkStrictlyPositiveCoin deposit)
    unsigned <-
        either (fail . show) pure $
            Exp.makeUnsignedTx Era.DijkstraEra $
                Exp.defaultTxBodyContent
                    { Exp.txNetUTxODepositChange = TopTx.DeclaresNetUTxODepositAllocation positiveDeposit
                    }
                    & Exp.setTxIns [(input, Exp.AnyKeyWitnessPlaceholder)]
                    & Exp.setTxOuts (map (Exp.TxOut . Api.toShelleyTxOut era) outputs)
                    & Exp.setTxMintValue mint
                    & Exp.setTxFee fee
    let witness = Exp.makeKeyWitness Era.DijkstraEra unsigned (Api.WitnessPaymentKey payment)
        Exp.SignedTx signed = Exp.signTx Era.DijkstraEra [] [witness] unsigned
        transaction = Api.ShelleyTx era signed
        txId = Api.getTxId (Api.getTxBody transaction)
        expected = Map.fromList (zipWith (\ix output -> (Api.TxIn txId (Api.TxIx ix), output)) [0 ..] outputs)
        expectedStore =
            State.DepositStore deposit $
                Map.fromList
                    [ (Api.toShelleyTxIn (Api.TxIn txId (Api.TxIx ix)), perOutputDeposit)
                    | ix <- [0, 1]
                    ]
        evidence =
            [ "txId" .= Api.serialiseToRawBytesHexText txId
            , "spentInput" .= show input
            , "createdInputs" .= map show (Map.keys expected)
            , "policyId" .= Api.serialiseToRawBytesHexText policyId
            , "tokensPerOutput" .= (7 :: Int)
            , "tokenOutputLovelace" .= (0 :: Int)
            , "tokenOwnerAddress" .= tokenOwnerAddressText
            , "inputLovelace" .= inputCoin
            , "feeLovelace" .= fee
            , "storeDepositLovelace" .= deposit
            , "perOutputDepositLovelace" .= perOutputDeposit
            , "changeLovelace" .= changeCoin
            ]
    BS.writeFile (directory </> "token-funding.cbor") (Api.serialiseToCBOR transaction)
    result <- Api.submitTxToNodeLocal connection (Api.TxInMode era transaction)
    case result of
        Api.TxSubmitSuccess -> do
            writeEvidence directory "token-funding-submitted.json" $
                object (("acceptedIntoMempool" .= True) : evidence)
            putStrLn $ "Accepted into mempool: " <> Text.unpack (Api.serialiseToRawBytesHexText txId)
        _ -> do
            writeEvidence directory "token-funding-rejected.json" $
                object (("rejection" .= show result) : evidence)
            fail $ "Token funding submission failed before either nested example could run: " <> show result
    included <- timeout 120_000_000 $ do
        awaitFunding connection input expected
        atInclusion <- queryLedgerState connection
        verifyStore expectedStore (totalAda before) atInclusion
        putStrLn "PASS: funding included with recorded deposits and conserved ADA; checking the next epoch"
        afterEpoch <- awaitNextEpoch connection (LedgerState.nesEL atInclusion)
        verifyStore expectedStore (totalAda before) afterEpoch
        pure (atInclusion, afterEpoch)
    case included of
        Nothing -> fail "Timed out after 120 seconds waiting for token funding and next-epoch deposit retention"
        Just (atInclusion, afterEpoch) -> do
            writeEvidence directory "token-funding-included.json" $
                object $
                    [ "included" .= True
                    , "outputsMatch" .= True
                    , "inputConsumed" .= True
                    , "depositStore" .= depositStore atInclusion
                    , "depositStoreAfterEpoch" .= depositStore afterEpoch
                    , "inclusionEpoch" .= LedgerState.nesEL atInclusion
                    , "verifiedEpoch" .= LedgerState.nesEL afterEpoch
                    , "totalAdaBefore" .= totalAda before
                    , "totalAdaAtInclusion" .= totalAda atInclusion
                    , "totalAdaAfterEpoch" .= totalAda afterEpoch
                    ]
                        <> evidence
            putStrLn "PASS: token-only funding included; exact deposits retained across an epoch and total ADA conserved"

awaitFunding ::
    Api.LocalNodeConnectInfo ->
    Api.TxIn ->
    Map.Map Api.TxIn (Api.TxOut Api.CtxUTxO Api.DijkstraEra) ->
    IO ()
awaitFunding connection spent expected = do
    Api.UTxO actual <- queryUTxO connection (Api.QueryUTxOByTxIn (Set.insert spent (Map.keysSet expected)))
    if Map.null (Map.intersection actual expected)
        then do
            threadDelay 1_000_000
            awaitFunding connection spent expected
        else
            unless (actual == expected) $
                fail $
                    "Token funding UTxO does not match the expected outputs and consumed input: " <> show actual

type LiveState = LedgerState.NewEpochState (Api.ShelleyLedgerEra Api.DijkstraEra)

queryDijkstra :: Api.LocalNodeConnectInfo -> Api.QueryInShelleyBasedEra Api.DijkstraEra result -> IO result
queryDijkstra connection query = do
    result <-
        runExceptT $
            Api.queryNodeLocalState connection Network.VolatileTip $
                Api.QueryInEra $
                    Api.QueryInShelleyBasedEra Api.ShelleyBasedEraDijkstra query
    eraResult <- either (fail . show) pure result
    either (fail . show) pure eraResult

queryLedgerState :: Api.LocalNodeConnectInfo -> IO LiveState
queryLedgerState connection = do
    -- Consensus keeps the UTxO in separate tables, outside the debug state.
    -- Query both at one acquired point to obtain a complete ADA-pot total.
    result <-
        Api.executeLocalStateQueryExpr connection Network.VolatileTip $
            (,)
                <$> Api.queryDebugLedgerState Api.ShelleyBasedEraDijkstra
                <*> Api.queryUtxo Api.ShelleyBasedEraDijkstra Api.QueryUTxOWhole
    (debugResult, utxoResult) <- either (fail . show) pure result
    encoded <- either (fail . show) pure debugResult >>= either (fail . show) pure
    utxo <- either (fail . show) pure utxoResult >>= either (fail . show) pure
    decoded <- either (fail . show) pure (Api.decodeDebugLedgerState encoded)
    pure $
        Api.unDebugLedgerState decoded
            & State.utxoL .~ Api.toLedgerUTxO Api.ShelleyBasedEraDijkstra utxo

depositStore :: LiveState -> State.DepositStore
depositStore state =
    state
        ^. LedgerState.nesEsL
            . LedgerState.esLStateL
            . LedgerState.lsUTxOStateL
            . LedgerState.utxosDepositStoreL

totalAda :: LiveState -> Coin
totalAda = AdaPots.totalAdaES . LedgerState.nesEs

verifyStore :: State.DepositStore -> Coin -> LiveState -> IO ()
verifyStore expected expectedTotal state = do
    unless (depositStore state == expected) $
        fail $
            "Deposit store differs from the funded output allocations: " <> show (depositStore state)
    unless (totalAda state == expectedTotal) $
        fail $
            "Total ADA changed: expected " <> show expectedTotal <> ", got " <> show (totalAda state)

awaitNextEpoch :: Api.LocalNodeConnectInfo -> Api.EpochNo -> IO LiveState
awaitNextEpoch connection previous = do
    state <- queryLedgerState connection
    if LedgerState.nesEL state > previous
        then pure state
        else do
            threadDelay 1_000_000
            awaitNextEpoch connection previous
