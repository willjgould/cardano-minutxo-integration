{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module DepositRelease (releaseDeposit) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental as Era
import qualified Cardano.Api.Experimental.Tx as Exp
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (mkSized)
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra.Core as Dijkstra
import qualified Cardano.Ledger.Dijkstra.Rules as Dijkstra
import qualified Cardano.Ledger.Dijkstra.UTxODeposit.TopTx as TopTx
import qualified Cardano.Ledger.Hashes as Hashes
import qualified Cardano.Ledger.Keys as Keys
import qualified Cardano.Ledger.State as State
import Cardano.Ledger.StrictlyPositiveCoin (mkStrictlyPositiveCoin)

import qualified AutoBalance
import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Aeson (object, (.=))
import qualified Data.ByteString as BS
import Data.Foldable (toList)
import Data.Function ((&))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Lens.Micro ((^.))
import Submission (writeEvidence)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Timeout (timeout)
import qualified TokenFunding as Funding

-- Consolidate two token-only outputs into one, freeing deposit capacity.
-- With no ADA input, the release must pay both the fee and ordinary ADA change.
-- Price the deposit explicitly; let the API calculate the fee and change.
releaseDeposit :: FilePath -> FilePath -> IO ()
releaseDeposit directory socket = do
    hSetBuffering stdout LineBuffering
    putStrLn "RUN node assertions: spend a deposit release with no ADA input"
    tokenOwner <-
        Api.readFileTextEnvelope (Api.File (directory </> "token-owner.skey"))
            >>= either (fail . show) pure
    let connection =
            Api.LocalNodeConnectInfo
                { Api.localConsensusModeParams = Api.CardanoModeParams (Api.EpochSlots 50)
                , Api.localNodeNetworkId = Api.Testnet (Api.NetworkMagic 42)
                , Api.localNodeSocketPath = Api.File socket
                }
        era = Api.ShelleyBasedEraDijkstra
        ownerHash@(Api.PaymentKeyHash keyHash) = Api.verificationKeyHash (Api.getVerificationKey tokenOwner)
    before <- Funding.queryLedgerState connection
    pparams <- Funding.queryDijkstra connection Api.QueryProtocolParameters
    let Api.UTxO original = Api.fromLedgerUTxO era (before ^. State.utxoL)
        store = Funding.depositStore before
        tokenInputs =
            [(input, output) | (input, output@(Api.TxOut _ Api.TxOutValueStoreBacked{} _ _)) <- Map.toAscList original]
    (inputs, tokenOutput) <- case tokenInputs of
        [(first, output), (second, other)] | output == other -> pure ([first, second], output)
        _ -> fail "Expected exactly two identical funded store-backed outputs"
    mergedOutput@(Api.TxOut address _ _ _) <- mergeTokenOutputs tokenOutput
    () <- case address of
        Api.AddressInEra (Api.ShelleyAddressInEra _) shelleyAddress ->
            unless (Api.shelleyPayAddrToPaymentKeyHash shelleyAddress == Just ownerHash) $
                fail "Both consumed outputs must belong to the token signer"
        _ -> fail "Expected a Shelley payment address"
    let spent = Set.fromList inputs
        ledgerSpent = Set.map Api.toShelleyTxIn spent
        selectedUTxO = Api.UTxO (Map.restrictKeys original spent)
        newAllocation =
            Dijkstra.requiredUTxODeposit pparams $
                mkSized
                    (Core.eraProtVerLow @(Api.ShelleyLedgerEra Api.DijkstraEra))
                    (Api.toShelleyTxOut era mergedOutput)
    -- Old allocations come from the live store, not today's output pricing.
    oldAllocations <- traverse
        (\input -> maybe (fail "Consumed input has no recorded deposit") pure $
            Map.lookup (Api.toShelleyTxIn input) (State.depositStoreAllocations store))
        inputs
    let released = mconcat oldAllocations - newAllocation
    positiveRelease <-
        maybe (fail "Consolidation must release a positive net deposit") pure $
            mkStrictlyPositiveCoin released
    let declaration = TopTx.DeclaresNetUTxODepositRelease positiveRelease (TopTx.TopTxSettlementOutput (TxIx 1))
        content =
            Exp.defaultTxBodyContent
                { Exp.txNetUTxODepositChange = declaration
                }
                & Exp.setTxIns [(input, Exp.AnyKeyWitnessPlaceholder) | input <- inputs]
                & Exp.setTxOuts [Exp.TxOut (Api.toShelleyTxOut era mergedOutput)]
    (unsigned@(Exp.UnsignedTx balanced), _) <-
        AutoBalance.balance connection pparams selectedUTxO content address
    let body = balanced ^. Core.bodyTxL
        fee = body ^. Core.feeTxBodyL
        outputs = map (Api.fromShelleyTxOut era) (toList (body ^. Core.outputsTxBodyL))
        changeCoin = released - fee
        changeValue = Api.lovelaceToTxOutValue era changeCoin
        expectedChange = Api.TxOut address changeValue Api.TxOutDatumNone Api.ReferenceScriptNone
    unless
        ( body ^. Core.inputsTxBodyL == ledgerSpent
            && body ^. Dijkstra.netUTxODepositChangeTxBodyL == declaration
            && null (body ^. Dijkstra.subTransactionsTxBodyL)
            && null (body ^. Dijkstra.collateralInputsTxBodyL)
            && body ^. Dijkstra.mintTxBodyL == mempty
            && body ^. Core.withdrawalsTxBodyL == mempty
            && null (body ^. Core.certsTxBodyL)
        )
        $ fail "Balancing changed the selected inputs/deposit or added another funding source"
    unless (fee > 0 && changeCoin > 0 && outputs == [mergedOutput, expectedChange]) $
        fail "The release alone must pay the fee and ADA change, preserving all fourteen tokens"
    unless (changeCoin >= Api.calculateMinimumUTxO era pparams (Api.TxOut address changeValue Api.TxOutDatumNone Api.ReferenceScriptNone)) $
        fail "Released ADA change is below the ordinary output's minimum ADA"
    let witness = Exp.makeKeyWitness Era.DijkstraEra unsigned (Api.WitnessPaymentKey tokenOwner)
        Exp.SignedTx signed = Exp.signTx Era.DijkstraEra [] [witness] unsigned
        transaction = Api.ShelleyTx era signed
        txId = Api.getTxId (Api.getTxBody transaction)
        witnesses = signed ^. Core.witsTxL . Core.addrTxWitsL
        bodyHash = Hashes.extractHash (Hashes.hashAnnotated body)
        created = Map.fromList (zipWith (\ix output -> (Api.TxIn txId (Api.TxIx ix), output)) [0 ..] outputs)
        expectedUTxO = Map.union created (Map.withoutKeys original spent)
        expectedStore =
            State.DepositStore
                (State.depositStoreBalance store - released)
                (Map.insert (Api.toShelleyTxIn (Api.TxIn txId (Api.TxIx 0))) newAllocation $
                    Map.withoutKeys (State.depositStoreAllocations store) ledgerSpent)
        evidence =
            [ "txId" .= Api.serialiseToRawBytesHexText txId
            , "spentInputs" .= map show inputs
            , "inputLovelace" .= (0 :: Int)
            , "inputTokens" .= ([7, 7] :: [Int])
            , "outputTokens" .= (14 :: Int)
            , "oldAllocationsLovelace" .= oldAllocations
            , "newAllocationLovelace" .= newAllocation
            , "netReleaseLovelace" .= released
            , "feeLovelace" .= fee
            , "changeLovelace" .= changeCoin
            , "settlementOutputIndex" .= (1 :: Int)
            , "automaticFeeAndChangeVerified" .= True
            , "inputOwnershipAndWitnessVerified" .= True
            ]
    unless
        ( signed ^. Core.bodyTxL == body
            && Set.size witnesses == 1
            && Set.map Keys.witVKeyHash witnesses == Set.singleton (Keys.asWitness keyHash)
            && all (State.verifyWitVKey bodyHash) witnesses
        )
        $ fail "Signing must preserve the balanced body and provide only the token owner's valid witness"
    BS.writeFile (directory </> "deposit-release.cbor") (Api.serialiseToCBOR transaction)
    writeEvidence directory "deposit-release-balanced.json" (object evidence)
    putStrLn $ "PASS balancing: release " <> show released <> " = fee " <> show fee <> " + ADA change " <> show changeCoin
    result <- Api.submitTxToNodeLocal connection (Api.TxInMode era transaction)
    case result of
        Api.TxSubmitSuccess -> do
            writeEvidence directory "deposit-release-submitted.json" $
                object (("acceptedIntoMempool" .= True) : evidence)
            putStrLn "Accepted deposit release into mempool"
        _ -> do
            writeEvidence directory "deposit-release-rejected.json" $
                object (("rejection" .= show result) : evidence)
            fail $ "Deposit release submission failed: " <> show result
    included <- timeout 120_000_000 $ awaitInclusion connection (Map.keysSet created) expectedUTxO
    after <- maybe (fail "Timed out waiting for deposit release inclusion") pure included
    Funding.verifyStore expectedStore (Funding.totalAda before) after
    writeEvidence directory "deposit-release-included.json" $
        object $
            [ "included" .= True
            , "wholeUTxOMatches" .= True
            , "depositStoreBefore" .= store
            , "depositStoreAfter" .= Funding.depositStore after
            , "totalAdaBefore" .= Funding.totalAda before
            , "totalAdaAfter" .= Funding.totalAda after
            ] <> evidence
    putStrLn "PASS: deposit release paid fee/change; inclusion, exact store and total ADA verified"

-- Both inputs are identical; combine their assets without introducing ADA.
mergeTokenOutputs :: Api.TxOut Api.CtxUTxO Api.DijkstraEra -> IO (Api.TxOut Api.CtxUTxO Api.DijkstraEra)
mergeTokenOutputs (Api.TxOut address value Api.TxOutDatumNone Api.ReferenceScriptNone) =
    case Api.valueToList (Api.txOutValueToValue value) of
        [(asset@Api.AssetId{}, Api.Quantity 7)] ->
            pure $
                Api.TxOut address
                    (Api.TxOutValueStoreBacked (Core.ApplicationAssets (Api.toMaryValue (Api.valueFromList [(asset, Api.Quantity 14)]))))
                    Api.TxOutDatumNone Api.ReferenceScriptNone
        _ -> fail "Each consumed output must contain exactly seven tokens and zero ADA"
mergeTokenOutputs _ = fail "Expected token outputs without a datum or reference script"

awaitInclusion :: Api.LocalNodeConnectInfo -> Set.Set Api.TxIn -> Map.Map Api.TxIn (Api.TxOut Api.CtxUTxO Api.DijkstraEra) -> IO Funding.LiveState
awaitInclusion connection created expected = do
    state <- Funding.queryLedgerState connection
    let Api.UTxO actual = Api.fromLedgerUTxO Api.ShelleyBasedEraDijkstra (state ^. State.utxoL)
    if Map.null (Map.restrictKeys actual created)
        then threadDelay 1_000_000 >> awaitInclusion connection created expected
        else do
            unless (actual == expected) $
                fail "Deposit release UTxO differs from the merged tokens, ADA change and untouched inputs"
            pure state
