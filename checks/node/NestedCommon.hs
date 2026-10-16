{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeFamilies #-}

module NestedCommon (awaitInclusion, signTokenContribution, splitTokenOutput, verifyDistinctOwners, verifyOwnerWitness) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental.Tx as Exp
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra.UTxODeposit.SubTx as SubTx
import qualified Cardano.Ledger.Hashes as Hashes
import qualified Cardano.Ledger.Keys as Keys
import Cardano.Ledger.State (verifyWitVKey)
import qualified Cardano.Ledger.State as State
import Cardano.Ledger.StrictlyPositiveCoin (StrictlyPositiveCoin)

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Lens.Micro ((^.))
import qualified TokenFunding as Funding

verifyDistinctOwners :: [Api.SigningKey Api.PaymentKey] -> IO ()
verifyDistinctOwners owners =
    unless (Set.size (Set.fromList (map (Api.verificationKeyHash . Api.getVerificationKey) owners)) == length owners) $
        fail "Each participant must have a distinct payment key"

-- Check the actual body's input owner and its sole witness, at either level.
-- A valid signature alone would not establish ownership of the live input.
verifyOwnerWitness ::
    Api.SigningKey Api.PaymentKey ->
    Map.Map Api.TxIn (Api.TxOut Api.CtxUTxO Api.DijkstraEra) ->
    Core.Tx level (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    IO ()
verifyOwnerWitness owner utxo transaction = do
    let expectedHash@(Api.PaymentKeyHash keyHash) = Api.verificationKeyHash (Api.getVerificationKey owner)
        body = transaction ^. Core.bodyTxL
        witnesses = transaction ^. Core.witsTxL . Core.addrTxWitsL
        bodyHash = Hashes.extractHash (Hashes.hashAnnotated body)
    () <- case Set.toList (body ^. Core.inputsTxBodyL) of
        [input] -> case Map.lookup (Api.fromShelleyTxIn input) utxo of
            Just (Api.TxOut (Api.AddressInEra (Api.ShelleyAddressInEra _) address) _ _ _) ->
                unless (Api.shelleyPayAddrToPaymentKeyHash address == Just expectedHash) $
                    fail "Transaction input is not owned by its intended signer"
            _ -> fail "Expected a live input at a Shelley payment address"
        _ -> fail "Expected one input owned by this participant"
    unless (Set.size witnesses == 1 && Set.map Keys.witVKeyHash witnesses == Set.singleton (Keys.asWitness keyHash)) $
        fail "Transaction must carry only its own owner's key witness"
    unless (all (verifyWitVKey bodyHash) witnesses) $
        fail "Owner signature does not verify against its own transaction body"

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
