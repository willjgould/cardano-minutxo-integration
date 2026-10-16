{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module NestedParent (submitParentFunded) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental as Era
import qualified Cardano.Api.Experimental.Tx as Exp
import Cardano.Ledger.Binary (mkSized)
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra.Core as Dijkstra
import qualified Cardano.Ledger.Dijkstra.Rules as Dijkstra
import qualified Cardano.Ledger.Dijkstra.UTxODeposit.TopTx as TopTx
import qualified Cardano.Ledger.State as State
import Cardano.Ledger.StrictlyPositiveCoin (StrictlyPositiveCoin, mkStrictlyPositiveCoin)

import qualified AutoBalance
import Control.Monad (unless)
import Data.Aeson (object, (.=))
import qualified Data.ByteString as BS
import Data.Foldable (toList)
import Data.Function ((&))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import Lens.Micro ((^.))
import NestedCommon (awaitInclusion, signTokenContribution, splitTokenOutput, verifyDistinctOwners, verifyOwnerWitness)
import Submission (writeEvidence)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Timeout (timeout)
import qualified TokenFunding as Funding

-- One child supplies only tokens. The parent pays the additional deposit and
-- fee from the ordinary ADA change created by the funding prerequisite.
-- The token owner and parent sign only their own transaction bodies.
-- Deposit pricing is explicit; the API must calculate the parent's fee/change.
submitParentFunded :: FilePath -> FilePath -> IO ()
submitParentFunded directory socket = do
    hSetBuffering stdout LineBuffering
    putStrLn "RUN node assertions: submit a token-only child with parent-funded capacity"
    payment <-
        Api.readFileTextEnvelope (Api.File (directory </> "payment.skey"))
            >>= either (fail . show) pure
    tokenOwner <-
        Api.readFileTextEnvelope (Api.File (directory </> "token-owner.skey"))
            >>= either (fail . show) pure
    verifyDistinctOwners [payment, tokenOwner]
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
    ((tokenInput, tokenOutput), (parentInput, parentOutput@(Api.TxOut address parentValue _ _))) <-
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
        parentCoin = Api.selectLovelace (Api.txOutValueToValue parentValue)
    unless (Api.txOutValueToValue parentValue == Api.lovelaceToValue parentCoin) $
        fail "Parent input must contain only ADA"
    positiveDeposit <-
        maybe (fail "The child split must require a positive additional deposit") pure $
            mkStrictlyPositiveCoin netDeposit

    AutoBalance.checkOrdinary directory connection pparams parentInput parentOutput
    tokenContribution <- signTokenContribution tokenOwner tokenInput tokenOutputs positiveDeposit
    putStrLn "RUN node assertions: automatically balance the parent fee and change with a signed token child"
    let selectedUTxO = Api.UTxO (Map.restrictKeys original (Set.fromList [parentInput, tokenInput]))
    transaction <- buildParent connection pparams selectedUTxO payment parentInput address positiveDeposit tokenContribution
    (fee, changeOutput) <- case transaction of
        Api.ShelleyTx _ signed ->
            let body = signed ^. Core.bodyTxL
             in case toList (body ^. Core.outputsTxBodyL) of
                    [output] -> pure (body ^. Core.feeTxBodyL, Api.fromShelleyTxOut era output)
                    _ -> fail "Automatic balancing must create exactly one parent change output"
    -- Independently check the returned change; never supply it to the builder.
    let changeCoin = parentCoin - fee - netDeposit
        expectedChange = Api.TxOut address (Api.lovelaceToTxOutValue era changeCoin) Api.TxOutDatumNone Api.ReferenceScriptNone
    unless (fee > 0 && changeCoin > 0 && changeOutput == expectedChange) $
        fail "Automatically balanced parent must pay the fee and net deposit and return the remaining ADA"

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
            , "parentOwnerKeyHash" .= Api.serialiseToRawBytesHexText (Api.verificationKeyHash (Api.getVerificationKey payment))
            , "tokenOwnerKeyHash" .= Api.serialiseToRawBytesHexText (Api.verificationKeyHash (Api.getVerificationKey tokenOwner))
            , "inputOwnershipAndWitnessesVerified" .= True
            , "automaticFeeAndChangeVerified" .= True
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
    case transaction of
        Api.ShelleyTx _ signed -> do
            verifyOwnerWitness payment original signed
            unless (signed ^. Core.bodyTxL . Dijkstra.netUTxODepositChangeTxBodyL == TopTx.DeclaresNetUTxODepositAllocation positiveDeposit) $
                fail "Automatic balancing must preserve the explicit parent deposit declaration"
            case toList (signed ^. Core.bodyTxL . Dijkstra.subTransactionsTxBodyL) of
                [embeddedChild] | embeddedChild == child -> verifyOwnerWitness tokenOwner original embeddedChild
                _ -> fail "Automatic balancing must preserve the signed token-owner child"
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

-- Embed the signed child before signing the parent. The parent pays one net
-- deposit; the child's declaration requests funding, not another transfer.
buildParent ::
    Api.LocalNodeConnectInfo ->
    Core.PParams (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    Api.UTxO Api.DijkstraEra ->
    Api.SigningKey Api.PaymentKey ->
    Api.TxIn ->
    Api.AddressInEra Api.DijkstraEra ->
    StrictlyPositiveCoin ->
    Exp.SignedSubTx ->
    IO (Api.Tx Api.DijkstraEra)
buildParent connection pparams utxo payment input changeAddress deposit child = do
    let content =
            Exp.defaultTxBodyContent
                { Exp.txNetUTxODepositChange = TopTx.DeclaresNetUTxODepositAllocation deposit
                }
                & Exp.setTxIns [(input, Exp.AnyKeyWitnessPlaceholder)]
                & Exp.setTxSignedSubTransactions [child]
    (unsigned, _) <- AutoBalance.balance connection pparams utxo content changeAddress
    let witness = Exp.makeKeyWitness Era.DijkstraEra unsigned (Api.WitnessPaymentKey payment)
        Exp.SignedTx signed = Exp.signTx Era.DijkstraEra [] [witness] unsigned
    pure (Api.ShelleyTx Api.ShelleyBasedEraDijkstra signed)
