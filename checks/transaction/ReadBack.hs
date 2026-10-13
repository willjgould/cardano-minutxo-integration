{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Ledger as Ledger

import qualified Cardano.Ledger.Core as Core

import Control.Monad (unless)
import Data.Function ((&))
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

-- Build through the public API, then read the resulting ledger body back through
-- the public API. Matching the returned value forces the otherwise lazy conversion.
main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  putStrLn "RUN transaction assertions: store-backed ledger-to-API read-back"
  txId <-
    either (die . show) pure $
      Api.deserialiseFromRawBytesHex
        "0000000000000000000000000000000000000000000000000000000000000000"
  paymentKeyHash <-
    either (die . show) pure $
      Api.deserialiseFromRawBytesHex
        "11111111111111111111111111111111111111111111111111111111"
  let era = Api.ShelleyBasedEraDijkstra
      address =
        Api.makeShelleyAddressInEra
          era
          (Api.Testnet (Api.NetworkMagic 42))
          (Api.PaymentCredentialByKey paymentKeyHash)
          Api.NoStakeAddress
      expectedAssets = Core.ApplicationAssets (Ledger.MaryValue (Ledger.Coin 2_000_000) mempty)
      output =
        Api.TxOut
          address
          (Api.TxOutValueStoreBacked expectedAssets)
          Api.TxOutDatumNone
          Api.ReferenceScriptNone
      content =
        Api.defaultTxBodyContent era
          & Api.setTxIns
            [(Api.TxIn txId (Api.TxIx 0), Api.BuildTxWith (Api.KeyWitness Api.KeyWitnessForSpending))]
          & Api.setTxOuts [output]
          & Api.setTxFee (Api.TxFeeExplicit era 200_000)
  body <- either (die . show) pure $ Api.createTransactionBody era content
  case Api.txOuts (Api.getTxBodyContent body) of
    [Api.TxOut _ (Api.TxOutValueStoreBacked actualAssets) _ _] ->
      unless (actualAssets == expectedAssets) $
        die "FAIL: read-back changed application assets; expected 2000000 lovelace and no native assets"
    [_] ->
      die "FAIL: read-back did not preserve the store-backed output kind"
    outputs ->
      die $ "FAIL: expected exactly one output after read-back, got " <> show (length outputs)
  putStrLn "PASS: API read-back preserves the store-backed output kind and application assets"
