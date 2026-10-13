{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Ledger as Ledger

import qualified Cardano.Ledger.Core as Core

import Control.Monad (unless)
import Data.Foldable (toList)
import Data.Function ((&))
import Lens.Micro ((^.))
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

-- Use the public API to request a store-backed output. Core supplies only the
-- application-assets type and inspection lens, not a ledger-output constructor.
main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  putStrLn "RUN transaction assertions: Dijkstra store-backed output"
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
  case body of
    Api.ShelleyTxBody _ ledgerBody _ _ _ _ ->
      case toList (ledgerBody ^. Ledger.outputsTxBodyL) of
        [Ledger.StoreBackedTxOut storeBackedOutput] ->
          unless (storeBackedOutput ^. Core.applicationAssetsTxOutL == expectedAssets) $
            die "FAIL: application assets changed; expected 2000000 lovelace and no native assets"
        [Ledger.ImplicitDepositTxOut{}] ->
          die "FAIL: expected a store-backed output, got an implicit-deposit output"
        outputs ->
          die $ "FAIL: expected exactly one transaction output, got " <> show (length outputs)
  putStrLn
    "PASS: unsigned transaction contains one store-backed output with the expected application assets"
