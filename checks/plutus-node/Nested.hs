{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Nested (spendNestedParent) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental as Era
import qualified Cardano.Api.Experimental.Tx as Exp
import Cardano.Ledger.Binary (mkSized)
import Cardano.Ledger.Coin (Coin)
import qualified Cardano.Ledger.Core as Core
import Cardano.Ledger.Credential (Credential (KeyHashObj))
import qualified Cardano.Ledger.Dijkstra as Dijkstra
import qualified Cardano.Ledger.Dijkstra.Core as Dijkstra
import qualified Cardano.Ledger.Dijkstra.Rules as Dijkstra
import qualified Cardano.Ledger.Dijkstra.Tx as Dijkstra
import qualified Cardano.Ledger.Dijkstra.UTxOs.Deposit.SubTx as SubTx
import qualified Cardano.Ledger.Dijkstra.UTxOs.Deposit.TopTx as TopTx
import qualified Cardano.Ledger.Hashes as Hashes
import qualified Cardano.Ledger.Keys as Keys
import qualified Cardano.Ledger.Plutus as Plutus
import qualified Cardano.Ledger.State as State
import Cardano.Ledger.StrictlyPositiveCoin (mkStrictlyPositiveCoin)
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Type as Network
import qualified PlutusLedgerApi.V4 as PV4

import qualified AutoBalance
import Control.Monad (unless)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (object, (.=))
import qualified Data.ByteString as BS
import Data.Foldable (toList)
import Data.Function ((&))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import GHC.Exts (fromList)
import Lens.Micro ((^.))
import NestedCommon (awaitInclusion, verifyDistinctOwners, verifyOwnerWitness)
import Submission (writeEvidence)
import System.FilePath ((</>))
import System.Timeout (timeout)
import qualified TokenFunding as Funding

type LedgerEra = Api.ShelleyLedgerEra Api.DijkstraEra

type Output = Api.TxOut Api.CtxUTxO Api.DijkstraEra

-- The datum's CBOR encoding grows at 23 -> 24. The unchanged validator still
-- preserves its full token-only value, while the parent supplies extra backing.
-- Budget the real child context before its author signs; never rewrite a signed
-- child's execution units while balancing the parent.
spendNestedParent ::
    FilePath ->
    Api.LocalNodeConnectInfo ->
    Core.PParams LedgerEra ->
    Api.SigningKey Api.PaymentKey ->
    Api.AddressInEra Api.DijkstraEra ->
    Api.TxId ->
    Api.UTxO Api.DijkstraEra ->
    State.UTxOStore (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    Coin ->
    Coin ->
    Output ->
    (Api.ExecutionUnits -> Exp.AnyWitness LedgerEra) ->
    IO ()
spendNestedParent directory connection pparams parentPayment sponsor fundingId fundingUTxO@(Api.UTxO original) fundingStore expectedTotalAda sponsorInputCoin continuation mkScriptWitness = do
    putStrLn "RUN node assertions: prepare and sign a token-only Plutus child before funding its parent"
    tokenOwner <-
        Api.readFileTextEnvelope (Api.File (directory </> "token-owner.skey"))
            >>= either (fail . show) pure
    verifyDistinctOwners [parentPayment, tokenOwner]
    let era = Api.ShelleyBasedEraDijkstra
        scriptInput = Api.TxIn fundingId (Api.TxIx 0)
        collateralInput = Api.TxIn fundingId (Api.TxIx 1)
        sponsorInput = Api.TxIn fundingId (Api.TxIx 2)
        Api.PaymentKeyHash ownerHash = Api.verificationKeyHash (Api.getVerificationKey tokenOwner)
        ownerGuard = KeyHashObj (Keys.coerceKeyRole ownerHash)
        expectedCollateral =
            Api.TxOut sponsor (Api.lovelaceToTxOutValue era 10_000_000) Api.TxOutDatumNone Api.ReferenceScriptNone
        price output =
            Dijkstra.requiredUTxODeposit pparams $
                mkSized (Core.eraProtVerLow @LedgerEra) (Api.toShelleyTxOut era output)
        newDeposit = price continuation
    initial <- maybe (fail "Missing funded script input") pure (Map.lookup scriptInput original)
    assertTokenTransition initial continuation
    unless (Map.lookup collateralInput original == Just expectedCollateral) $
        fail "Expected separate ordinary sponsor collateral of 10 ADA"
    recordedDeposit <-
        maybe (fail "The script input has no recorded deposit allocation") pure $
            Map.lookup (Api.toShelleyTxIn scriptInput) (Funding.backingAmounts fundingStore)
    let netDeposit = newDeposit - recordedDeposit
    positiveDeposit <-
        maybe (fail "Datum 23 to 24 must require positive additional backing") pure $
            mkStrictlyPositiveCoin netDeposit
    systemStart <-
        runExceptT (Api.queryNodeLocalState connection Network.VolatileTip Api.QuerySystemStart)
            >>= either (fail . show) pure
    history <-
        runExceptT (Api.queryNodeLocalState connection Network.VolatileTip Api.QueryEraHistory)
            >>= either (fail . show) pure
    let Api.LedgerEpochInfo epochInfo = Api.toLedgerEpochInfo history
        parentContent =
            Exp.defaultTxBodyContent
                { Exp.txNetUTxODepositChange = TopTx.DeclaresNetUTxODepositAllocation positiveDeposit
                }
                & Exp.setTxIns [(sponsorInput, Exp.AnyKeyWitnessPlaceholder)]
                & Exp.setTxInsCollateral [collateralInput]
                & Exp.setTxProtocolParams pparams
        makeChild units =
            either (fail . show) pure $
                Exp.makeUnsignedSubTx
                    Exp.defaultSubTxBodyContent
                        { Exp.subTxIns = [(scriptInput, mkScriptWitness units)]
                        , Exp.subTxOuts = [Exp.TxOut (Api.toShelleyTxOut era continuation)]
                        , Exp.subTxProtocolParams = Just pparams
                        , Exp.subTxGuards = fromList [ownerGuard]
                        , Exp.subTxNetUTxODepositChange = SubTx.RequestsUTxODepositFromTopTx positiveDeposit
                        }
        provisionalParent (Exp.UnsignedSubTx child) =
            either (fail . show) pure $
                Exp.makeUnsignedTx Era.DijkstraEra $
                    parentContent & Exp.setTxSubTransactions [child]
        nestedContext transaction = do
            let annotated = Dijkstra.mkDijkstraStAnnTopTx epochInfo systemStart pparams (State.allocations fundingStore) Map.empty transaction
            topScripts <- either (fail . show) pure (Dijkstra.dsattPlutusScriptsWithContext annotated)
            unless (null topScripts) $ fail "This check must execute its sole Plutus script in the child"
            child <- case Dijkstra.dsattSubTransactions annotated of
                [one] -> pure one
                _ -> fail "Expected exactly one annotated child"
            contexts <- either (fail . show) pure (Dijkstra.dsastPlutusScriptsWithContext child)
            case contexts of
                [context@Plutus.PlutusWithContext{Plutus.pwcScript = script, Plutus.pwcArgs = args}] ->
                    case Plutus.plutusSLanguage script of
                        Plutus.SPlutusV4 -> do
                            let Plutus.PlutusV4Args scriptContext = args
                            unless (PV4.txInfoSubTxIx (PV4.scriptContextTxInfo scriptContext) == Just 0) $
                                fail "Expected the actual child context at index zero"
                            pure context
                        _ -> fail "Expected a Plutus V4 validator"
                _ -> fail "Expected one real Plutus V4 child context at index zero"
        evaluate context = do
            let (logs, result) = Plutus.evaluatePlutusWithContext PV4.Verbose context
            budget <- either (\err -> fail $ "Nested validator failed: " <> show (err, logs)) pure result
            units <- maybe (fail "Nested execution budget cannot be represented") pure (Plutus.exBudgetToExUnits budget)
            unless (Plutus.exUnitsSteps units > 0 && Plutus.exUnitsMem units > 0) $
                fail "Nested validator must consume positive execution units"
            pure units
        toApiUnits units =
            Api.ExecutionUnits
                { Api.executionSteps = Plutus.exUnitsSteps units
                , Api.executionMemory = Plutus.exUnitsMem units
                }
    initialChild <- makeChild (toApiUnits (pparams ^. Dijkstra.ppMaxTxExUnitsL))
    Exp.UnsignedTx provisional <- provisionalParent initialChild
    context <- nestedContext provisional
    measured <- evaluate context
    unsignedChild@(Exp.UnsignedSubTx childBeforeSigning) <- makeChild (toApiUnits measured)
    Exp.UnsignedTx measuredParent <- provisionalParent unsignedChild
    measuredContext <- nestedContext measuredParent
    measuredAgain <- evaluate measuredContext
    unless (measuredAgain == measured && Plutus.pwcExUnits measuredContext == measured) $
        fail "The final unsigned child must execute within its measured, committed budget"
    let childWitness = Exp.makeSubTxKeyWitness unsignedChild (Api.WitnessPaymentKey tokenOwner)
        signedChild@(Exp.SignedSubTx child) = Exp.signSubTx [] [childWitness] unsignedChild
        childBytes = Api.serialiseToCBOR signedChild
        childId = Exp.getSignedSubTxId signedChild
        childBody = child ^. Core.bodyTxL
    unless (childBody == childBeforeSigning ^. Core.bodyTxL) $
        fail "Child signing must preserve the prepared body"
    verifyChildSigner tokenOwner child
    unless
        ( childBody ^. Core.inputsTxBodyL == Set.singleton (Api.toShelleyTxIn scriptInput)
            && toList (childBody ^. Core.outputsTxBodyL) == [Api.toShelleyTxOut era continuation]
            && childBody ^. Dijkstra.subTxNetUTxODepositChangeTxBodyL == SubTx.RequestsUTxODepositFromTopTx positiveDeposit
        )
        $ fail "The signed child must contain only the script input, token continuation and exact backing request"
    let childEvidence =
            [ "childTxId" .= Api.serialiseToRawBytesHexText childId
            , "childSignerKeyHash" .= Api.serialiseToRawBytesHexText (Api.verificationKeyHash (Api.getVerificationKey tokenOwner))
            , "parentSignerKeyHash" .= Api.serialiseToRawBytesHexText (Api.verificationKeyHash (Api.getVerificationKey parentPayment))
            , "childRequiredSignerVerified" .= True
            , "childInputsLovelace" .= (0 :: Int)
            , "childOutputsLovelace" .= (0 :: Int)
            , "tokenQuantity" .= (7 :: Int)
            , "initialDatum" .= (23 :: Int)
            , "continuingDatum" .= (24 :: Int)
            , "recordedInputDepositLovelace" .= recordedDeposit
            , "continuationDepositLovelace" .= newDeposit
            , "parentFundedExtraBackingLovelace" .= netDeposit
            , "executionSteps" .= Plutus.exUnitsSteps measured
            , "executionMemory" .= Plutus.exUnitsMem measured
            , "executionEvaluatedInChildContext" .= True
            , "signedBeforeParentBalancing" .= True
            ]
    BS.writeFile (directory </> "plutus-nested-parent-child.cbor") childBytes
    writeEvidence directory "plutus-nested-parent-child-signed.json" (object childEvidence)

    putStrLn "RUN node assertions: automatically balance parent backing and fees around the signed Plutus child"
    (unsignedParent@(Exp.UnsignedTx balanced), balancedContent) <-
        AutoBalance.balance connection pparams fundingUTxO fundingStore (parentContent & Exp.setTxSignedSubTransactions [signedChild]) sponsor
    assertChildUnchanged childBytes balanced
    unless
        ( balanced ^. Core.bodyTxL . Core.inputsTxBodyL == Set.singleton (Api.toShelleyTxIn sponsorInput)
            && balanced ^. Core.bodyTxL . Dijkstra.netUTxODepositChangeTxBodyL == TopTx.DeclaresNetUTxODepositAllocation positiveDeposit
            && Exp.txInsCollateral balancedContent == [collateralInput]
            && Exp.txScriptValidity balancedContent == Api.ScriptValid
        )
        $ fail "Parent balancing must preserve its sponsor input, declaration, collateral and valid-script flag"
    let fee = balanced ^. Core.bodyTxL . Core.feeTxBodyL
        expectedChangeCoin = sponsorInputCoin - netDeposit - fee
        expectedChange = Api.TxOut sponsor (Api.lovelaceToTxOutValue era expectedChangeCoin) Api.TxOutDatumNone Api.ReferenceScriptNone
    unless
        ( fee > 0
            && expectedChangeCoin > 0
            && toList (balanced ^. Core.bodyTxL . Core.outputsTxBodyL) == [Api.toShelleyTxOut era expectedChange]
        )
        $ fail "Parent must pay exactly the additional backing and fee, returning its remaining ADA"
    let parentWitness = Exp.makeKeyWitness Era.DijkstraEra unsignedParent (Api.WitnessPaymentKey parentPayment)
        signedParent@(Exp.SignedTx signed) = Exp.signTx Era.DijkstraEra [] [parentWitness] unsignedParent
        transaction = Api.ShelleyTx era signed
        parentId = Api.getTxId (Api.getTxBody transaction)
        bytes = Api.serialiseToRawBytes signedParent
    verifyOwnerWitness parentPayment original signed
    assertChildUnchanged childBytes signed
    decoded@(Exp.SignedTx decodedTx) <-
        either (fail . show) pure $ Api.deserialiseFromRawBytes (Api.asType @(Exp.SignedTx Api.DijkstraEra)) bytes
    unless (decoded == signedParent && Api.serialiseToRawBytes decoded == bytes) $
        fail "Signed nested transaction CBOR round-trip must preserve every byte"
    assertChildUnchanged childBytes decodedTx
    finalContext <- nestedContext decodedTx
    finalUnits <- evaluate finalContext
    unless (finalUnits == measured && Plutus.pwcExUnits finalContext == measured) $
        fail "Final signed nested transaction must execute with the unchanged child's declared budget"
    let continuationInput = Api.TxIn childId (Api.TxIx 0)
        created = Map.fromList [(Api.TxIn parentId (Api.TxIx 0), expectedChange), (continuationInput, continuation)]
        spent = Set.fromList [scriptInput, sponsorInput]
        expectedUTxO = Map.union created (Map.withoutKeys original spent)
        expectedStore =
            Funding.BackingSummary
                ((State.toCoin . State.totalDepositAmount) fundingStore + netDeposit)
                ( Map.insert (Api.toShelleyTxIn continuationInput) newDeposit $
                    Map.delete (Api.toShelleyTxIn scriptInput) (Funding.backingAmounts fundingStore)
                )
        evidence =
            [ "parentTxId" .= Api.serialiseToRawBytesHexText parentId
            , "feeLovelace" .= fee
            , "parentChangeLovelace" .= expectedChangeCoin
            , "signedChildBytesUnchanged" .= True
            , "cborRoundTripVerified" .= True
            , "separateSignaturesVerified" .= True
            , "automaticFeeAndChangeVerified" .= True
            ]
                <> childEvidence
    BS.writeFile (directory </> "plutus-nested-parent.cbor") (Api.serialiseToCBOR transaction)
    writeEvidence directory "plutus-nested-parent-balanced.json" (object evidence)
    result <- Api.submitTxToNodeLocal connection (Api.TxInMode era transaction)
    case result of
        Api.TxSubmitSuccess -> do
            writeEvidence directory "plutus-nested-parent-submitted.json" $
                object (("acceptedIntoMempool" .= True) : evidence)
            putStrLn $ "Accepted into mempool: " <> Text.unpack (Api.serialiseToRawBytesHexText parentId)
        _ -> do
            writeEvidence directory "plutus-nested-parent-rejected.json" $
                object (("rejection" .= show result) : evidence)
            fail $ "Parent-funded nested Plutus submission failed: " <> show result
    included <- timeout 120_000_000 $ awaitInclusion connection (Map.keysSet created) expectedUTxO
    after <- maybe (fail "Timed out waiting for parent-funded nested Plutus inclusion") pure included
    Funding.verifyStore expectedStore expectedTotalAda after
    writeEvidence directory "plutus-nested-parent-included.json" $
        object $
            [ "included" .= True
            , "wholeUTxOMatches" .= True
            , "collateralUnchanged" .= True
            , "depositStoreBefore" .= fundingStore
            , "depositStoreAfter" .= Funding.depositStore after
            , "totalAdaBefore" .= expectedTotalAda
            , "totalAdaAfter" .= Funding.totalAda after
            ]
                <> evidence
    putStrLn "PASS: signed token-only Plutus child included unchanged; parent supplied additional backing and fee, datum advanced 23 to 24, collateral unspent"

assertTokenTransition :: Output -> Output -> IO ()
assertTokenTransition
    (Api.TxOut address before@Api.TxOutValueStoreBacked{} (Api.TxOutDatumInline _ initialDatum) Api.ReferenceScriptNone)
    (Api.TxOut continuationAddress after@Api.TxOutValueStoreBacked{} (Api.TxOutDatumInline _ continuingDatum) Api.ReferenceScriptNone) =
        unless
            ( address == continuationAddress
                && before == after
                && ( case Api.valueToList (Api.txOutValueToValue before) of
                        [(Api.AssetId{}, Api.Quantity 7)] -> True
                        _ -> False
                   )
                && initialDatum == Api.unsafeHashableScriptData (Api.ScriptDataNumber 23)
                && continuingDatum == Api.unsafeHashableScriptData (Api.ScriptDataNumber 24)
            )
            $ fail "Nested script transition must preserve seven tokens and zero ADA while advancing datum 23 to 24"
assertTokenTransition _ _ = fail "Nested script input and continuation must be token-only store-backed outputs with inline datums"

verifyChildSigner :: Api.SigningKey Api.PaymentKey -> Core.Tx Core.SubTx LedgerEra -> IO ()
verifyChildSigner owner child = do
    let Api.PaymentKeyHash keyHash = Api.verificationKeyHash (Api.getVerificationKey owner)
        body = child ^. Core.bodyTxL
        witnesses = child ^. Core.witsTxL . Core.addrTxWitsL
        bodyHash = Hashes.extractHash (Hashes.hashAnnotated body)
    unless
        ( toList (body ^. Dijkstra.guardsTxBodyL) == [KeyHashObj (Keys.coerceKeyRole keyHash)]
            && Set.size witnesses == 1
            && Set.map Keys.witVKeyHash witnesses == Set.singleton (Keys.asWitness keyHash)
            && all (State.verifyWitVKey bodyHash) witnesses
        )
        $ fail "Child must require and carry its own signer's valid signature"

assertChildUnchanged :: BS.ByteString -> Core.Tx Core.TopTx LedgerEra -> IO ()
assertChildUnchanged expected transaction =
    case toList (transaction ^. Core.bodyTxL . Dijkstra.subTransactionsTxBodyL) of
        [child] | Api.serialiseToCBOR (Exp.SignedSubTx child) == expected -> pure ()
        _ -> fail "The complete signed child must remain byte-for-byte unchanged"
