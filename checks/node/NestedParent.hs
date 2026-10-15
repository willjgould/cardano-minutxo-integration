{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module NestedParent (submitParentFunded) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental as Era
import qualified Cardano.Api.Experimental.Tx as Exp
import Cardano.Ledger.Binary (mkSized)
import Cardano.Ledger.Coin (Coin)
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra.Rules as Dijkstra
import qualified Cardano.Ledger.Dijkstra.UTxODeposit.SubTx as SubTx
import qualified Cardano.Ledger.Dijkstra.UTxODeposit.TopTx as TopTx
import qualified Cardano.Ledger.State as State
import Cardano.Ledger.StrictlyPositiveCoin (StrictlyPositiveCoin, mkStrictlyPositiveCoin)

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Aeson (object, (.=))
import qualified Data.ByteString as BS
import Data.Function ((&))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import Lens.Micro ((^.))
import Submission (writeEvidence)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Timeout (timeout)
import qualified TokenFunding as Funding

-- One child supplies only tokens. The parent pays the additional deposit and
-- fee from the ordinary ADA change created by the funding prerequisite.
submitParentFunded :: FilePath -> FilePath -> IO ()
submitParentFunded directory socket = do
    hSetBuffering stdout LineBuffering
    putStrLn "RUN node assertions: submit a token-only child with parent-funded capacity"
    payment <-
        Api.readFileTextEnvelope (Api.File (directory </> "payment.skey"))
            >>= either (fail . show) pure
    let connection =
            Api.LocalNodeConnectInfo
                { Api.localConsensusModeParams = Api.CardanoModeParams (Api.EpochSlots 50)
                , Api.localNodeNetworkId = Api.Testnet (Api.NetworkMagic 42)
                , Api.localNodeSocketPath = Api.File socket
                }
        era = Api.ShelleyBasedEraDijkstra
    before <- Funding.queryLedgerState connection
    pparams <- Funding.queryDijkstra connection Api.QueryProtocolParameters
    let Api.UTxO original = Api.fromLedgerUTxO era (before ^. State.utxoL)
        store = Funding.depositStore before
        tokenInputs =
            [(input, output) | (input, output@(Api.TxOut _ Api.TxOutValueStoreBacked{} _ _)) <- Map.toAscList original]
        adaInputs =
            [(input, output) | (input, output@(Api.TxOut _ Api.TxOutValueShelleyBased{} _ _)) <- Map.toAscList original]
    ((tokenInput, tokenOutput), (parentInput, Api.TxOut address parentValue _ _)) <-
        case (tokenInputs, adaInputs) of
            ([first@(_, output), (_, reserve)], [ada]) | output == reserve -> pure (first, ada)
            _ -> fail "Expected two identical funded token outputs and one ordinary ADA output"
    tokenOutputs <- splitTokenOutput tokenOutput
    released <-
        maybe (fail "Token input has no recorded allocation") pure $
            Map.lookup (Api.toShelleyTxIn tokenInput) (State.depositStoreAllocations store)
    let price output =
            Dijkstra.requiredUTxODeposit pparams $
                mkSized
                    (Core.eraProtVerLow @(Api.ShelleyLedgerEra Api.DijkstraEra))
                    (Api.toShelleyTxOut era output)
        allocations = map price tokenOutputs
        netDeposit = mconcat allocations - released
        fee = 1_000_000
        parentCoin = Api.selectLovelace (Api.txOutValueToValue parentValue)
        changeCoin = parentCoin - fee - netDeposit
        changeOutput = Api.TxOut address (Api.lovelaceToTxOutValue era changeCoin) Api.TxOutDatumNone Api.ReferenceScriptNone
    unless (Api.txOutValueToValue parentValue == Api.lovelaceToValue parentCoin) $
        fail "Parent input must contain only ADA"
    positiveDeposit <-
        maybe (fail "The child split must require a positive additional deposit") pure $
            mkStrictlyPositiveCoin netDeposit

    tokenContribution <- signTokenContribution payment tokenInput tokenOutputs positiveDeposit
    transaction <- buildParent payment parentInput changeOutput positiveDeposit fee tokenContribution

    let Exp.SignedSubTx child = tokenContribution
        childId = Api.fromShelleyTxId (Core.txIdTxBody (child ^. Core.bodyTxL))
        parentId = Api.getTxId (Api.getTxBody transaction)
        childInputs = [Api.TxIn childId (Api.TxIx ix) | ix <- [0, 1]]
        created = Map.fromList $ (Api.TxIn parentId (Api.TxIx 0), changeOutput) : zip childInputs tokenOutputs
        spent = Set.fromList [tokenInput, parentInput]
        expectedUTxO = Map.union created (Map.withoutKeys original spent)
        expectedStore =
            State.DepositStore
                (State.depositStoreBalance store + netDeposit)
                ( Map.union
                    (Map.fromList (zip (map Api.toShelleyTxIn childInputs) allocations))
                    (Map.delete (Api.toShelleyTxIn tokenInput) (State.depositStoreAllocations store))
                )
        evidence =
            [ "parentTxId" .= Api.serialiseToRawBytesHexText parentId
            , "childTxId" .= Api.serialiseToRawBytesHexText childId
            , "childCount" .= (1 :: Int)
            , "tokenInput" .= show tokenInput
            , "parentInput" .= show parentInput
            , "childInputsLovelace" .= (0 :: Int)
            , "childOutputsLovelace" .= (0 :: Int)
            , "childOutputTokens" .= ([3, 4] :: [Int])
            , "releasedDepositLovelace" .= released
            , "newAllocationsLovelace" .= allocations
            , "parentFundedDepositLovelace" .= netDeposit
            , "feeLovelace" .= fee
            , "changeLovelace" .= changeCoin
            ]
    BS.writeFile (directory </> "nested-parent.cbor") (Api.serialiseToCBOR transaction)
    result <- Api.submitTxToNodeLocal connection (Api.TxInMode era transaction)
    case result of
        Api.TxSubmitSuccess -> do
            writeEvidence directory "nested-parent-submitted.json" $
                object (("acceptedIntoMempool" .= True) : evidence)
            putStrLn $ "Accepted into mempool: " <> Text.unpack (Api.serialiseToRawBytesHexText parentId)
        _ -> do
            writeEvidence directory "nested-parent-rejected.json" $
                object (("rejection" .= show result) : evidence)
            fail $ "Parent-funded nested submission failed: " <> show result
    included <- timeout 120_000_000 $ awaitInclusion connection (Map.keysSet created) expectedUTxO
    after <- maybe (fail "Timed out waiting for parent-funded nested inclusion") pure included
    Funding.verifyStore expectedStore (Funding.totalAda before) after
    writeEvidence directory "nested-parent-included.json" $
        object $
            [ "included" .= True
            , "wholeUTxOMatches" .= True
            , "parentAndChildInputsConsumed" .= True
            , "depositStoreBefore" .= store
            , "depositStoreAfter" .= Funding.depositStore after
            , "totalAdaBefore" .= Funding.totalAda before
            , "totalAdaAfter" .= Funding.totalAda after
            ]
                <> evidence
    putStrLn "PASS: parent-funded nested transaction included; token split, deposit replacement and total ADA verified"

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

-- Embed the signed child before signing the parent. The parent pays one net
-- deposit; the child's declaration requests funding, not another transfer.
buildParent ::
    Api.SigningKey Api.PaymentKey ->
    Api.TxIn ->
    Api.TxOut Api.CtxUTxO Api.DijkstraEra ->
    StrictlyPositiveCoin ->
    Coin ->
    Exp.SignedSubTx ->
    IO (Api.Tx Api.DijkstraEra)
buildParent payment input change deposit fee child = do
    unsigned <-
        either (fail . show) pure $
            Exp.makeUnsignedTx Era.DijkstraEra $
                Exp.defaultTxBodyContent
                    { Exp.txNetUTxODepositChange = TopTx.DeclaresNetUTxODepositAllocation deposit
                    }
                    & Exp.setTxIns [(input, Exp.AnyKeyWitnessPlaceholder)]
                    & Exp.setTxOuts [Exp.TxOut (Api.toShelleyTxOut Api.ShelleyBasedEraDijkstra change)]
                    & Exp.setTxFee fee
                    & Exp.setTxSignedSubTransactions [child]
    let witness = Exp.makeKeyWitness Era.DijkstraEra unsigned (Api.WitnessPaymentKey payment)
        Exp.SignedTx signed = Exp.signTx Era.DijkstraEra [] [witness] unsigned
    pure (Api.ShelleyTx Api.ShelleyBasedEraDijkstra signed)

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
