{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module AutoBalance (balance, balanceWithChangeOutput, checkOrdinary) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental.Tx as Exp
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.State as State
import qualified Cardano.Ledger.Dijkstra.Core as Dijkstra
import qualified Cardano.Ledger.Dijkstra.UTxOs.Deposit.TopTx as TopTx
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Type as Network

import Control.Monad (unless)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (object, (.=))
import Data.Foldable (toList)
import Data.Function ((&))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Lens.Micro ((^.))
import Submission (writeEvidence)

-- Use the live node's era history and parameters. Inputs are selected by the
-- caller; the API must calculate the fee and change without an override.
balance ::
    Api.LocalNodeConnectInfo ->
    Core.PParams (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    Api.UTxO Api.DijkstraEra ->
    State.UTxOStore (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    Exp.TxBodyContent (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    Api.AddressInEra Api.DijkstraEra ->
    IO (Exp.UnsignedTx (Api.ShelleyLedgerEra Api.DijkstraEra), Exp.TxBodyContent (Api.ShelleyLedgerEra Api.DijkstraEra))
balance = balanceWithChangeOutput Exp.ImplicitDepositChange

balanceWithChangeOutput ::
    Exp.ChangeOutputKind ->
    Api.LocalNodeConnectInfo ->
    Core.PParams (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    Api.UTxO Api.DijkstraEra ->
    State.UTxOStore (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    Exp.TxBodyContent (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    Api.AddressInEra Api.DijkstraEra ->
    IO (Exp.UnsignedTx (Api.ShelleyLedgerEra Api.DijkstraEra), Exp.TxBodyContent (Api.ShelleyLedgerEra Api.DijkstraEra))
balanceWithChangeOutput changeKind connection pparams utxo store content address = do
    systemStart <-
        runExceptT (Api.queryNodeLocalState connection Network.VolatileTip Api.QuerySystemStart)
            >>= either (fail . show) pure
    history <-
        runExceptT (Api.queryNodeLocalState connection Network.VolatileTip Api.QueryEraHistory)
            >>= either (fail . show) pure
    either (fail . ("Automatic balancing failed: " <>) . Api.displayError) pure $
        Exp.makeTransactionBodyAutoBalanceWithChangeOutput @Api.DijkstraEra
            changeKind
            systemStart
            (Api.toLedgerEpochInfo history)
            pparams
            Set.empty
            Map.empty
            Map.empty
            (Api.toLedgerUTxO Api.ShelleyBasedEraDijkstra utxo)
            (State.allocations store)
            content
            address
            Nothing

-- A construction-only control: the same balancer must still handle an
-- ordinary ADA payment. Keep the live input unspent for the nested example.
checkOrdinary ::
    FilePath ->
    Api.LocalNodeConnectInfo ->
    Core.PParams (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    Api.TxIn ->
    Api.TxOut Api.CtxUTxO Api.DijkstraEra ->
    IO ()
checkOrdinary directory connection pparams input inputOutput@(Api.TxOut address inputValue _ _) = do
    putStrLn "RUN construction control: automatically balance an ordinary ADA payment"
    let era = Api.ShelleyBasedEraDijkstra
        inputCoin = Api.selectLovelace (Api.txOutValueToValue inputValue)
        paymentCoin = 10_000_000
        paymentOutput = Api.TxOut address (Api.lovelaceToTxOutValue era paymentCoin) Api.TxOutDatumNone Api.ReferenceScriptNone
        content =
            Exp.defaultTxBodyContent
                & Exp.setTxIns [(input, Exp.AnyKeyWitnessPlaceholder)]
                & Exp.setTxOuts [Exp.TxOut (Api.toShelleyTxOut era paymentOutput)]
    unless (Api.txOutValueToValue inputValue == Api.lovelaceToValue inputCoin) $
        fail "Ordinary balancing control requires an ADA-only input"
    queried <- Api.executeLocalStateQueryExpr connection Network.VolatileTip $
        Api.queryUTxOAllocations Api.ShelleyBasedEraDijkstra (Set.singleton input)
    entries <- either (fail . show) pure queried >>= either (fail . show) pure
    store <- either (fail . show) pure (State.fromAllocations $ State.unAllocations entries)
    (Exp.UnsignedTx transaction, _) <-
        balance connection pparams (Api.UTxO (Map.singleton input inputOutput)) store content address
    let body = transaction ^. Core.bodyTxL
        fee = body ^. Core.feeTxBodyL
    unless
        ( body ^. Core.inputsTxBodyL == Set.singleton (Api.toShelleyTxIn input)
            && null (body ^. Dijkstra.subTransactionsTxBodyL)
            && not (TopTx.hasUTxODepositDeclaration (body ^. Dijkstra.netUTxODepositChangeTxBodyL))
        )
        $ fail "Ordinary balancing changed the input or added nested/deposit operations"
    change <- case toList (body ^. Core.outputsTxBodyL) of
        [actualPayment, actualChange]
            | actualPayment == Api.toShelleyTxOut era paymentOutput ->
                pure (Api.fromShelleyTxOut era actualChange :: Api.TxOut Api.CtxUTxO Api.DijkstraEra)
        _ -> fail "Ordinary balancing must preserve the payment and add exactly one change output"
    changeCoin <- case change of
        Api.TxOut changeAddress value@Api.TxOutValueShelleyBased{} Api.TxOutDatumNone Api.ReferenceScriptNone -> do
            let coin = Api.selectLovelace (Api.txOutValueToValue value)
            unless (changeAddress == address && coin > 0 && Api.txOutValueToValue value == Api.lovelaceToValue coin) $
                fail "Ordinary balancing produced invalid ADA change"
            pure coin
        _ -> fail "Ordinary balancing must produce plain ADA change"
    unless (fee > 0 && inputCoin == paymentCoin + changeCoin + fee) $
        fail "Ordinary automatic fee and change do not conserve ADA"
    writeEvidence directory "ordinary-autobalance.json" $
        object
            [ "constructionOnly" .= True
            , "submitted" .= False
            , "feeAndChangeAutomaticallyCalculated" .= True
            , "inputLovelace" .= inputCoin
            , "paymentLovelace" .= paymentCoin
            , "changeLovelace" .= changeCoin
            , "feeLovelace" .= fee
            , "adaConserved" .= True
            ]
    putStrLn "PASS: ordinary automatic balancing constructed valid fee and change (not submitted)"
