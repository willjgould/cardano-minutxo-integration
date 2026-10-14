{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Main where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental as Era
import qualified Cardano.Api.Experimental.Tx as Exp
import qualified Cardano.Api.Ledger as Ledger

import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra.Core as Dijkstra

import Control.Monad (forM_, unless)
import Data.Foldable (toList)
import Data.Function ((&))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Lens.Micro ((^.))
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

data Funding = ParentFunds | SiblingFunds
    deriving (Show)

-- Construction only: a fixed deposit, synthetic UTxO, and no key signatures.
-- Nested builder names follow the archive. The two deposit-store fields are
-- proposed API additions; neither the current API nor the archive exposes them.
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
    let era = Api.ShelleyBasedEraDijkstra
        address =
            Api.makeShelleyAddressInEra
                era
                (Api.Testnet (Api.NetworkMagic 42))
                (Api.PaymentCredentialByKey paymentKeyHash)
                Api.NoStakeAddress
        output value = Api.TxOut address value Api.TxOutDatumNone Api.ReferenceScriptNone
        tokens = Api.valueFromList [(Api.AssetId policyId (Api.AssetName "offer"), Api.Quantity 7)]
        tokenAssets = Core.ApplicationAssets (Api.toMaryValue tokens)
        tokenOutput = output (Api.TxOutValueStoreBacked tokenAssets)
        adaOutput coin = output (Api.TxOutValueShelleyBased era (Api.toMaryValue (Api.lovelaceToValue coin)))
        tokenInput = Api.TxIn txId (Api.TxIx 0)
        parentInput = Api.TxIn txId (Api.TxIx 1)
        siblingInput = Api.TxIn txId (Api.TxIx 2)
        deposit = Ledger.Coin 2_000_000
        fee = Ledger.Coin 200_000
        keyInput input = (input, Exp.AnyKeyWitnessPlaceholder)

    forM_ [ParentFunds, SiblingFunds] $ \funding -> do
        putStrLn $ "RUN transaction assertions: nested token-only output, " <> show funding
        let (parentCoin, siblingInputs) = case funding of
                ParentFunds -> (deposit <> fee, [])
                SiblingFunds -> (fee, [(siblingInput, adaOutput deposit)])
            utxo = Api.UTxO $ Map.fromList $ (tokenInput, tokenOutput) : (parentInput, adaOutput parentCoin) : siblingInputs
            tokenContent =
                Exp.defaultSubTxBodyContent
                    { Exp.subTxIns = [keyInput tokenInput]
                    , Exp.subTxOuts = [Exp.TxOut (Api.toShelleyTxOut era tokenOutput)]
                    , Exp.subTxDepositStoreChange = Just (Dijkstra.SubTxRequestDepositFromTopTx deposit)
                    }
        Exp.UnsignedSubTx tokenChild <- either (die . show) pure $ Exp.makeUnsignedSubTx tokenContent
        children <- case funding of
            ParentFunds -> pure [tokenChild]
            SiblingFunds -> do
                -- The sibling supplies ADA to aggregate accounting. The parent records
                -- the deposit once; absence of a sibling operation is not delegation.
                Exp.UnsignedSubTx adaChild <-
                    either (die . show) pure $
                        Exp.makeUnsignedSubTx
                            Exp.defaultSubTxBodyContent
                                { Exp.subTxIns = [keyInput siblingInput]
                                , Exp.subTxOuts = []
                                , Exp.subTxDepositStoreChange = Nothing
                                }
                pure [tokenChild, adaChild]
        Exp.UnsignedTx transaction <-
            either (die . show) pure $
                Exp.makeUnsignedTx Era.DijkstraEra $
                    Exp.defaultTxBodyContent
                        { Exp.txDepositStoreChange = Just (Dijkstra.DepositToStore deposit)
                        }
                        & Exp.setTxIns [keyInput parentInput]
                        & Exp.setTxFee fee
                        & Exp.setTxSubTransactions children

        let body = transaction ^. Core.bodyTxL
            actualChildren = toList (body ^. Dijkstra.subTransactionsTxBodyL)
        assertEqual "embedded children and their order" children actualChildren
        assertEqual "parent inputs" (Set.singleton (Api.toShelleyTxIn parentInput)) (body ^. Core.inputsTxBodyL)
        assertEqual "parent outputs" [] (toList (body ^. Core.outputsTxBodyL))
        assertEqual "parent fee" fee (body ^. Core.feeTxBodyL)
        assertEqual "parent deposit" (Ledger.SJust (Dijkstra.DepositToStore deposit)) (body ^. Dijkstra.depositStoreChangeTxBodyL)
        parentValue <- inputValue utxo body
        assertEqual "parent input assets" (Api.lovelaceToValue parentCoin) parentValue

        childValues <- case actualChildren of
            actualTokenChild : otherChildren -> do
                let tokenBody = actualTokenChild ^. Core.bodyTxL
                assertEqual "token child inputs" (Set.singleton (Api.toShelleyTxIn tokenInput)) (tokenBody ^. Core.inputsTxBodyL)
                offered <- inputValue utxo tokenBody
                assertEqual "token-only input assets" tokens offered
                assertEqual "token input ADA" (Ledger.Coin 0) (Api.selectLovelace offered)
                assertEqual "child funding request" (Ledger.SJust (Dijkstra.SubTxRequestDepositFromTopTx deposit)) (tokenBody ^. Dijkstra.depositStoreSubTxChangeTxBodyL)
                case toList (tokenBody ^. Core.outputsTxBodyL) of
                    [Core.StoreBackedTxOut payload] ->
                        assertEqual "token-only output assets" tokenAssets (payload ^. Core.applicationAssetsTxOutL)
                    _ -> die "FAIL: expected exactly one store-backed token output"
                otherValues <- mapM (checkSupplier utxo siblingInput deposit) otherChildren
                pure (offered : otherValues)
            [] -> die "FAIL: token child is missing"
        assertEqual
            "fixture input assets equal token output plus one deposit and fee"
            (tokens <> Api.lovelaceToValue (deposit <> fee))
            (parentValue <> mconcat childValues)
        putStrLn $ "PASS: nested construction preserves token-only assets and explicit parent deposit, " <> show funding

checkSupplier ::
    Api.UTxO Api.DijkstraEra ->
    Api.TxIn ->
    Ledger.Coin ->
    Core.Tx Core.SubTx (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    IO Api.Value
checkSupplier utxo input deposit child = do
    let body = child ^. Core.bodyTxL
    assertEqual "ADA sibling inputs" (Set.singleton (Api.toShelleyTxIn input)) (body ^. Core.inputsTxBodyL)
    assertEqual "ADA sibling outputs" [] (toList (body ^. Core.outputsTxBodyL))
    assertEqual "no duplicate deposit in ADA sibling" Ledger.SNothing (body ^. Dijkstra.depositStoreSubTxChangeTxBodyL)
    value <- inputValue utxo body
    assertEqual "ADA-only sibling input assets" (Api.lovelaceToValue deposit) value
    pure value

inputValue ::
    Api.UTxO Api.DijkstraEra ->
    Core.TxBody level (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    IO Api.Value
inputValue (Api.UTxO utxo) body =
    fmap mconcat $ mapM lookupInput $ toList (body ^. Core.inputsTxBodyL)
  where
    lookupInput input = case Map.lookup (Api.fromShelleyTxIn input) utxo of
        Just (Api.TxOut _ value _ _) -> pure $ Api.txOutValueToValue value
        Nothing -> die $ "FAIL: input absent from fixture UTxO: " <> show input

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
    unless (expected == actual) $
        die $
            "FAIL: " <> label <> "; expected " <> show expected <> ", got " <> show actual
