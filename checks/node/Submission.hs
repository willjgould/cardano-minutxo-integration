{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Submission (transfer) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental as Era
import qualified Cardano.Api.Experimental.Tx as Exp
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Type as Network

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString.Lazy as LBS
import Data.Function ((&))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.FilePath ((</>))
import System.Timeout (timeout)

-- Establish ordinary transaction submission before introducing store-backed
-- outputs or nested transactions. The input comes from the running node.
transfer :: FilePath -> FilePath -> IO ()
transfer directory socket = do
    putStrLn "RUN node assertions: submit an ordinary ADA transfer"
    payment <-
        Api.readFileTextEnvelope (Api.File (directory </> "payment.skey"))
            >>= either (fail . show) pure
    addressText <- Text.strip <$> Text.readFile (directory </> "address.txt")
    source <-
        maybe (fail "Invalid genesis payment address") pure $
            Api.deserialiseAddress Api.AsAddressAny addressText
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
    let inputCoin = Api.selectLovelace inputValue
        fee = 1_000_000
        outputCoin = inputCoin - fee
    unless (inputValue == Api.lovelaceToValue 900_000_000_000) $
        fail $
            "Unexpected genesis funding: " <> show inputValue

    recipient <- Api.generateSigningKey Api.AsPaymentKey
    let era = Api.ShelleyBasedEraDijkstra
        destination =
            Api.makeShelleyAddressInEra
                era
                (Api.Testnet (Api.NetworkMagic 42))
                (Api.PaymentCredentialByKey (Api.verificationKeyHash (Api.getVerificationKey recipient)))
                Api.NoStakeAddress
        output :: Api.TxOut Api.CtxUTxO Api.DijkstraEra
        output =
            Api.TxOut
                destination
                (Api.lovelaceToTxOutValue era outputCoin)
                Api.TxOutDatumNone
                Api.ReferenceScriptNone
    unsigned <-
        either (fail . show) pure $
            Exp.makeUnsignedTx Era.DijkstraEra $
                Exp.defaultTxBodyContent
                    & Exp.setTxIns [(input, Exp.AnyKeyWitnessPlaceholder)]
                    & Exp.setTxOuts [Exp.TxOut (Api.toShelleyTxOut era output)]
                    & Exp.setTxFee fee
    let witness = Exp.makeKeyWitness Era.DijkstraEra unsigned (Api.WitnessPaymentKey payment)
        Exp.SignedTx signed = Exp.signTx Era.DijkstraEra [] [witness] unsigned
        transaction = Api.ShelleyTx era signed
        txId = Api.getTxId (Api.getTxBody transaction)
        createdInput = Api.TxIn txId (Api.TxIx 0)
        evidence =
            [ "txId" .= Api.serialiseToRawBytesHexText txId
            , "spentInput" .= show input
            , "createdInput" .= show createdInput
            , "recipient" .= Api.serialiseAddress destination
            , "inputLovelace" .= inputCoin
            , "feeLovelace" .= fee
            , "outputLovelace" .= outputCoin
            ]
    result <- Api.submitTxToNodeLocal connection (Api.TxInMode era transaction)
    case result of
        Api.TxSubmitSuccess -> do
            putStrLn $ "Accepted into mempool: " <> Text.unpack (Api.serialiseToRawBytesHexText txId)
            writeEvidence directory "ordinary-submitted.json" $
                object (("acceptedIntoMempool" .= True) : evidence)
        _ -> fail $ "Ordinary ADA transfer submission failed: " <> show result

    included <- timeout 120_000_000 (awaitInclusion connection input createdInput output)
    case included of
        Nothing -> fail "Timed out after 120 seconds waiting for ordinary ADA transfer inclusion"
        Just () -> do
            writeEvidence directory "ordinary-included.json" $
                object $
                    [ "included" .= True
                    , "inputConsumed" .= True
                    , "outputMatches" .= True
                    ]
                        <> evidence
            putStrLn "PASS: ordinary ADA transfer included; input consumed and recipient output matches exactly"

queryUTxO :: Api.LocalNodeConnectInfo -> Api.QueryUTxOFilter -> IO (Api.UTxO Api.DijkstraEra)
queryUTxO connection selection = do
    result <-
        runExceptT $
            Api.queryNodeLocalState connection Network.VolatileTip $
                Api.QueryInEra $
                    Api.QueryInShelleyBasedEra Api.ShelleyBasedEraDijkstra (Api.QueryUTxO selection)
    eraResult <- either (fail . show) pure result
    either (fail . show) pure eraResult

awaitInclusion ::
    Api.LocalNodeConnectInfo ->
    Api.TxIn ->
    Api.TxIn ->
    Api.TxOut Api.CtxUTxO Api.DijkstraEra ->
    IO ()
awaitInclusion connection spent created expected = do
    Api.UTxO actual <- queryUTxO connection (Api.QueryUTxOByTxIn (Set.fromList [spent, created]))
    case Map.lookup created actual of
        Nothing -> do
            threadDelay 1_000_000
            awaitInclusion connection spent created expected
        Just output -> do
            unless (output == expected) $
                fail $
                    "Included output differs from the submitted output: " <> show output
            unless (Map.notMember spent actual) $
                fail "Included transaction's input is still unspent"

writeEvidence :: FilePath -> FilePath -> Value -> IO ()
writeEvidence directory name value = LBS.writeFile (directory </> name) (encode value <> "\n")
