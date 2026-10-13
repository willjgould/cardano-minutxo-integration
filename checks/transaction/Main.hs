{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Ledger as Ledger

import Control.Monad (unless)
import Data.Foldable (toList)
import Data.Function ((&))
import Lens.Micro ((^.))
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

-- Exercise the existing public writer API, including its conversion to ledger
-- outputs. The synthetic input is not looked up or submitted to a node.
main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  putStrLn "RUN transaction assertions: Dijkstra implicit-deposit output"
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
      output =
        Api.TxOut
          address
          (Api.lovelaceToTxOutValue era 2_000_000)
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
        [Ledger.ImplicitDepositTxOut implicitOutput] ->
          unless (implicitOutput ^. Ledger.valueTxOutL == Ledger.MaryValue (Ledger.Coin 2_000_000) mempty) $
            die "FAIL: transaction output value changed; expected 2000000 lovelace and no assets"
        [Ledger.StoreBackedTxOut{}] ->
          die "FAIL: expected an implicit-deposit output, got a store-backed output"
        outputs ->
          die $ "FAIL: expected exactly one transaction output, got " <> show (length outputs)
  putStrLn
    "PASS: unsigned transaction contains one implicit-deposit output with 2000000 lovelace and no assets"
