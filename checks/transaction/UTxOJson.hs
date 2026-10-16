{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Cardano.Api as Api
import qualified Cardano.Ledger.Core as Core

import Control.Monad (unless)
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as Map
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

-- Exercise the public JSON instances for the same typed UTxO returned by node
-- queries. These local fixtures need no node or transaction submission.
main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    txId <-
        either (die . show) pure $
            Api.deserialiseFromRawBytesHex
                "0000000000000000000000000000000000000000000000000000000000000000"
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
        ordinaryOutput =
            Api.TxOut address (Api.lovelaceToTxOutValue era 3_000_000) Api.TxOutDatumNone Api.ReferenceScriptNone
        tokens = Api.valueFromList [(Api.AssetId policyId assetName, Api.Quantity 7)]
        storeBackedOutput =
            Api.TxOut
                address
                (Api.TxOutValueStoreBacked (Core.ApplicationAssets (Api.toMaryValue tokens)))
                Api.TxOutDatumNone
                Api.ReferenceScriptNone
        ordinaryEntry = (Api.TxIn txId (Api.TxIx 0), ordinaryOutput)
        storeBackedEntry = (Api.TxIn txId (Api.TxIx 1), storeBackedOutput)
    checkRoundTrip "ordinary ADA UTxO control" $ Api.UTxO (Map.fromList [ordinaryEntry])
    checkRoundTrip "mixed ordinary and token-only store-backed UTxO" $
        Api.UTxO (Map.fromList [ordinaryEntry, storeBackedEntry])

checkRoundTrip :: String -> Api.UTxO Api.DijkstraEra -> IO ()
checkRoundTrip label expected = do
    putStrLn $ "RUN JSON assertions: " <> label
    decoded <-
        either (die . (("FAIL: " <> label <> " JSON decoding: ") <>)) pure $
            Aeson.eitherDecode (Aeson.encode expected)
    unless (decoded == expected) $
        die $
            "FAIL: " <> label <> " JSON round-trip changed input references, addresses, output kinds or assets"
    putStrLn $ "PASS: " <> label <> " JSON round-trip preserves the complete UTxO"
