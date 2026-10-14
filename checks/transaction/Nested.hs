{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
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

import Control.Monad (unless)
import Data.Foldable (toList)
import Data.Function ((&))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Lens.Micro ((^.))
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

-- Construction only: a fixed deposit, synthetic UTxO, and no key signatures.
-- The same token contribution is composed with each funding arrangement.
main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    fixture@Fixture{tokenInput, tokenOutput} <- exampleFixture
    tokenContribution <-
        either (die . show) pure $
            prepareTokenContribution tokenInput tokenOutput

    exampleParentFundsDeposit fixture tokenContribution
    exampleSiblingFundsDeposit fixture tokenContribution

-- One child supplies tokens; the top-level transaction supplies deposit + fee.
exampleParentFundsDeposit :: Fixture -> Exp.UnsignedSubTx -> IO ()
exampleParentFundsDeposit fixture@Fixture{tokenInput, tokenOutput, parentInput, address, deposit, fee} tokenContribution = do
    putStrLn "RUN transaction assertions: nested token-only output, ParentFunds"
    let parentCoin = deposit <> fee
        utxo =
            Api.UTxO $
                Map.fromList
                    [ (tokenInput, tokenOutput)
                    , (parentInput, adaOutput address parentCoin)
                    ]
        contributions = [tokenContribution]
    transaction <-
        either (die . show) pure $
            composeTransaction parentInput deposit fee contributions
    checkConstruction fixture utxo parentCoin contributions transaction
    putStrLn "PASS: nested construction preserves token-only assets and explicit parent deposit, ParentFunds"

-- Two children supply tokens and deposit ADA separately; the top level supplies
-- only the fee. The parent still records the deposit operation exactly once.
exampleSiblingFundsDeposit :: Fixture -> Exp.UnsignedSubTx -> IO ()
exampleSiblingFundsDeposit fixture@Fixture{tokenInput, tokenOutput, parentInput, siblingInput, address, deposit, fee} tokenContribution = do
    putStrLn "RUN transaction assertions: nested token-only output, SiblingFunds"
    adaContribution <- either (die . show) pure $ prepareAdaContribution siblingInput
    let parentCoin = fee
        utxo =
            Api.UTxO $
                Map.fromList
                    [ (tokenInput, tokenOutput)
                    , (parentInput, adaOutput address parentCoin)
                    , (siblingInput, adaOutput address deposit)
                    ]
        contributions = [tokenContribution, adaContribution]
    transaction <-
        either (die . show) pure $
            composeTransaction parentInput deposit fee contributions
    checkConstruction fixture utxo parentCoin contributions transaction
    putStrLn "PASS: nested construction preserves token-only assets and explicit parent deposit, SiblingFunds"

-- The token contribution declares only its input and output, with no deposit
-- operation or funding request. Both examples reuse it unchanged.
prepareTokenContribution ::
    Api.TxIn ->
    Api.TxOut Api.CtxUTxO Api.DijkstraEra ->
    Either Exp.MakeUnsignedTxError Exp.UnsignedSubTx
prepareTokenContribution input output =
    Exp.makeUnsignedSubTx
        Exp.defaultSubTxBodyContent
            { Exp.subTxIns = [keyInput input]
            , Exp.subTxOuts = [Exp.TxOut (Api.toShelleyTxOut Api.ShelleyBasedEraDijkstra output)]
            , Exp.subTxDepositStoreChange = Nothing
            }

-- The ADA input contributes to aggregate accounting; only the parent records
-- the deposit, so the sibling has no deposit operation of its own.
-- Its input value is supplied by the fixture, not selected or balanced here.
prepareAdaContribution :: Api.TxIn -> Either Exp.MakeUnsignedTxError Exp.UnsignedSubTx
prepareAdaContribution input =
    Exp.makeUnsignedSubTx
        Exp.defaultSubTxBodyContent
            { Exp.subTxIns = [keyInput input]
            , Exp.subTxOuts = []
            , Exp.subTxDepositStoreChange = Nothing
            }

-- Assemble the unsigned parent with explicit amounts. This does not calculate
-- the required deposit, balance the transaction, or validate ledger rules.
composeTransaction ::
    Api.TxIn ->
    Ledger.Coin ->
    Ledger.Coin ->
    [Exp.UnsignedSubTx] ->
    Either Exp.MakeUnsignedTxError (Exp.UnsignedTx (Api.ShelleyLedgerEra Api.DijkstraEra))
composeTransaction input depositAmount feeAmount contributions =
    Exp.makeUnsignedTx Era.DijkstraEra $
        Exp.defaultTxBodyContent
            { Exp.txDepositStoreChange = Just (Dijkstra.DepositToStore depositAmount)
            }
            & Exp.setTxIns [keyInput input]
            & Exp.setTxFee feeAmount
            & Exp.setTxSubTransactions [child | Exp.UnsignedSubTx child <- contributions]

keyInput :: Api.TxIn -> (Api.TxIn, Exp.AnyWitness (Api.ShelleyLedgerEra Api.DijkstraEra))
keyInput input = (input, Exp.AnyKeyWitnessPlaceholder)

adaOutput :: Api.AddressInEra Api.DijkstraEra -> Ledger.Coin -> Api.TxOut Api.CtxUTxO Api.DijkstraEra
adaOutput destination coin =
    Api.TxOut
        destination
        (Api.TxOutValueShelleyBased Api.ShelleyBasedEraDijkstra (Api.toMaryValue (Api.lovelaceToValue coin)))
        Api.TxOutDatumNone
        Api.ReferenceScriptNone

-- Synthetic inputs and fixed amounts used only by this construction example.
data Fixture = Fixture
    { tokenInput :: Api.TxIn
    , parentInput :: Api.TxIn
    , siblingInput :: Api.TxIn
    , tokenOutput :: Api.TxOut Api.CtxUTxO Api.DijkstraEra
    , address :: Api.AddressInEra Api.DijkstraEra
    , tokens :: Api.Value
    , deposit :: Ledger.Coin
    , fee :: Ledger.Coin
    }

exampleFixture :: IO Fixture
exampleFixture = do
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
        tokens = Api.valueFromList [(Api.AssetId policyId assetName, Api.Quantity 7)]
        tokenAssets = Core.ApplicationAssets (Api.toMaryValue tokens)
    pure
        Fixture
            { tokenInput = Api.TxIn txId (Api.TxIx 0)
            , parentInput = Api.TxIn txId (Api.TxIx 1)
            , siblingInput = Api.TxIn txId (Api.TxIx 2)
            , tokenOutput = Api.TxOut address (Api.TxOutValueStoreBacked tokenAssets) Api.TxOutDatumNone Api.ReferenceScriptNone
            , address
            , tokens
            , deposit = Ledger.Coin 2_000_000
            , fee = Ledger.Coin 200_000
            }

checkConstruction ::
    Fixture ->
    Api.UTxO Api.DijkstraEra ->
    Ledger.Coin ->
    [Exp.UnsignedSubTx] ->
    Exp.UnsignedTx (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    IO ()
checkConstruction Fixture{tokenInput, parentInput, siblingInput, tokens, deposit, fee} utxo parentCoin contributions (Exp.UnsignedTx transaction) = do
    let tokenAssets = Core.ApplicationAssets (Api.toMaryValue tokens)
        children = [child | Exp.UnsignedSubTx child <- contributions]
        body = transaction ^. Core.bodyTxL
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
            assertEqual "no deposit operation in token child" Ledger.SNothing (tokenBody ^. Dijkstra.depositStoreSubTxChangeTxBodyL)
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
