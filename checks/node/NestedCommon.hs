{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}

module NestedCommon (awaitInclusion, signTokenContribution, splitTokenOutput) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental.Tx as Exp
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra.UTxODeposit.SubTx as SubTx
import qualified Cardano.Ledger.State as State
import Cardano.Ledger.StrictlyPositiveCoin (StrictlyPositiveCoin)

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Lens.Micro ((^.))
import qualified TokenFunding as Funding

-- Split seven tokens into three and four; neither output contains ADA.
splitTokenOutput :: Api.TxOut Api.CtxUTxO Api.DijkstraEra -> IO [Api.TxOut Api.CtxUTxO Api.DijkstraEra]
splitTokenOutput (Api.TxOut address value Api.TxOutDatumNone Api.ReferenceScriptNone) =
    case Api.valueToList (Api.txOutValueToValue value) of
        [(asset@Api.AssetId{}, Api.Quantity 7)] ->
            pure
                [ Api.TxOut
                    address
                    (Api.TxOutValueStoreBacked (Core.ApplicationAssets (Api.toMaryValue (Api.valueFromList [(asset, Api.Quantity quantity)]))))
                    Api.TxOutDatumNone
                    Api.ReferenceScriptNone
                | quantity <- [3, 4]
                ]
        _ -> fail "Token child requires exactly seven tokens and zero ADA"
splitTokenOutput _ = fail "Expected a token input without a datum or reference script"

signTokenContribution ::
    Api.SigningKey Api.PaymentKey ->
    Api.TxIn ->
    [Api.TxOut Api.CtxUTxO Api.DijkstraEra] ->
    StrictlyPositiveCoin ->
    IO Exp.SignedSubTx
signTokenContribution payment input outputs deposit = do
    unsigned <-
        either (fail . show) pure $
            Exp.makeUnsignedSubTx
                Exp.defaultSubTxBodyContent
                    { Exp.subTxIns = [(input, Exp.AnyKeyWitnessPlaceholder)]
                    , Exp.subTxOuts = map (Exp.TxOut . Api.toShelleyTxOut Api.ShelleyBasedEraDijkstra) outputs
                    , Exp.subTxNetUTxODepositChange = SubTx.RequestsUTxODepositFromTopTx deposit
                    }
    let witness = Exp.makeSubTxKeyWitness unsigned (Api.WitnessPaymentKey payment)
    pure (Exp.signSubTx [] [witness] unsigned)

awaitInclusion ::
    Api.LocalNodeConnectInfo ->
    Set.Set Api.TxIn ->
    Map.Map Api.TxIn (Api.TxOut Api.CtxUTxO Api.DijkstraEra) ->
    IO Funding.LiveState
awaitInclusion connection created expected = do
    state <- Funding.queryLedgerState connection
    let Api.UTxO actual = Api.fromLedgerUTxO Api.ShelleyBasedEraDijkstra (state ^. State.utxoL)
    if Map.null (Map.restrictKeys actual created)
        then do
            threadDelay 1_000_000
            awaitInclusion connection created expected
        else do
            unless (actual == expected) $
                fail $
                    "Nested inclusion UTxO differs from expected child outputs, parent change and untouched inputs: " <> show actual
            pure state
