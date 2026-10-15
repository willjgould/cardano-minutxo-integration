{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module TokenFunding (fundTokens) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental as Era
import qualified Cardano.Api.Experimental.AnyScriptWitness as Witness
import qualified Cardano.Api.Experimental.Tx as Exp
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra.Core as Dijkstra
import qualified Cardano.Ledger.Keys as Keys
import qualified Cardano.Ledger.Shelley.Scripts as Native

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Aeson (object, (.=))
import qualified Data.ByteString as BS
import Data.Function ((&))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Submission (queryUTxO, writeEvidence)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Timeout (timeout)

-- Before submitting the nested examples, create two real token-only inputs.
-- The genesis payment key owns the outputs and authorizes the native mint.
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
    let connection =
            Api.LocalNodeConnectInfo
                { Api.localConsensusModeParams = Api.CardanoModeParams (Api.EpochSlots 50)
                , Api.localNodeNetworkId = Api.Testnet (Api.NetworkMagic 42)
                , Api.localNodeSocketPath = Api.File socket
                }
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
        deposit = 4_000_000
        inputCoin = Api.selectLovelace inputValue
        -- Explicitly pay the store deposit; returning it as change would hide
        -- missing ledger accounting. Each example gets a separate token input.
        changeCoin = inputCoin - fee - deposit
        tokenOutput :: Api.TxOut Api.CtxUTxO Api.DijkstraEra
        tokenOutput =
            Api.TxOut
                destination
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
    unsigned <-
        either (fail . show) pure $
            Exp.makeUnsignedTx Era.DijkstraEra $
                Exp.defaultTxBodyContent
                    { Exp.txDepositStoreChange = Just (Dijkstra.DepositToStore deposit)
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
        evidence =
            [ "txId" .= Api.serialiseToRawBytesHexText txId
            , "spentInput" .= show input
            , "createdInputs" .= map show (Map.keys expected)
            , "policyId" .= Api.serialiseToRawBytesHexText policyId
            , "tokensPerOutput" .= (7 :: Int)
            , "tokenOutputLovelace" .= (0 :: Int)
            , "inputLovelace" .= inputCoin
            , "feeLovelace" .= fee
            , "storeDepositLovelace" .= deposit
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
    included <- timeout 120_000_000 (awaitFunding connection input expected)
    case included of
        Nothing -> fail "Timed out after 120 seconds waiting for token funding inclusion"
        Just () -> do
            writeEvidence directory "token-funding-included.json" $
                object (("included" .= True) : ("outputsMatch" .= True) : evidence)
            putStrLn "PASS: two token-only store-backed outputs and ADA change included; genesis input consumed"

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
