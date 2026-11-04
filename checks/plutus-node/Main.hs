{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import qualified Cardano.Api as Api
import qualified TokenFunding as Funding
import qualified Cardano.Api.Consensus as Consensus
import qualified Cardano.Api.Experimental as Era
import qualified Cardano.Api.Experimental.AnyScriptWitness as Witness
import qualified Cardano.Api.Experimental.Plutus as Plutus
import qualified Cardano.Api.Experimental.Tx as Exp
import qualified Cardano.Ledger.Alonzo.Rules as Alonzo
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (mkSized)
import qualified Cardano.Ledger.Binary.Plain as Plain
import Cardano.Ledger.Coin (Coin (..))
import qualified Cardano.Ledger.Conway.Rules as Conway
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra as Dijkstra
import qualified Cardano.Ledger.Dijkstra.Core as Dijkstra
import qualified Cardano.Ledger.Dijkstra.Rules as Dijkstra
import qualified Cardano.Ledger.Dijkstra.Tx as Dijkstra
import qualified Cardano.Ledger.Dijkstra.UTxOs.Deposit.TopTx as TopTx
import qualified Cardano.Ledger.Keys as Keys
import Cardano.Ledger.Plutus (Language (PlutusV4), SLanguage (SPlutusV4))
import qualified Cardano.Ledger.Plutus.Evaluate as LedgerPlutus
import qualified Cardano.Ledger.Shelley.Scripts as Native
import qualified Cardano.Ledger.State as State
import qualified Cardano.Ledger.State.UTxOs.Allocations as Allocations
import Cardano.Ledger.StrictlyPositiveCoin (mkStrictlyPositiveCoin)
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Type as Network
import qualified PlutusLedgerApi.V4 as PV4

import qualified AutoBalance
import Control.Concurrent (threadDelay)
import Control.Monad (unless, when)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (object, (.=))
import Data.Aeson.Types (Pair)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Short as SBS
import Data.Foldable (toList)
import Data.Function ((&))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Lens.Micro ((^.))
import MinUTxO.Validator (validatorBytes)
import Nested (spendNestedParent)
import Submission (queryUTxO, writeEvidence)
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Timeout (timeout)
import TokenFunding (depositStore, queryDijkstra, queryLedgerState, totalAda, verifyStore)

type LedgerEra = Api.ShelleyLedgerEra Api.DijkstraEra

type Output = Api.TxOut Api.CtxUTxO Api.DijkstraEra

data OutputKind = Ordinary | StoreBacked

data SpendCase = Direct | Negative | NestedParent deriving (Eq)

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    arguments <- getArgs
    case arguments of
        ["ordinary", directory, socket] -> scriptSpend Ordinary Direct directory socket
        ["store-backed", directory, socket] -> scriptSpend StoreBacked Direct directory socket
        ["store-backed-negative", directory, socket] -> scriptSpend StoreBacked Negative directory socket
        ["nested-parent", directory, socket] -> scriptSpend StoreBacked NestedParent directory socket
        _ -> fail "Usage: check-plutus-node (ordinary|store-backed|store-backed-negative|nested-parent) DIRECTORY SOCKET"

-- Run the same validator rule with either representation of its script output.
-- The sponsor pays fees and any backing, and supplies separate ordinary
-- collateral. No released backing is used to pay either transaction's fee.
scriptSpend :: OutputKind -> SpendCase -> FilePath -> FilePath -> IO ()
scriptSpend kind spendCase directory socket = do
    let checkInvalidDatum = spendCase == Negative
        initialDatum = if spendCase == NestedParent then 23 else 0
        modeName = case kind of
            Ordinary -> "ordinary"
            StoreBacked -> "store-backed"
        evidencePrefix = if spendCase == NestedParent then "plutus-nested-parent" else "plutus-" <> modeName <> (if checkInvalidDatum then "-negative" else "")
    putStrLn $ "RUN node assertions: fund a " <> modeName <> " Plutus V4 script output"
    payment <-
        Api.readFileTextEnvelope (Api.File (directory </> "payment.skey"))
            >>= either (fail . show) pure
    addressText <- Text.strip <$> Text.readFile (directory </> "address.txt")
    source <-
        maybe (fail "Invalid genesis payment address") pure $
            Api.deserialiseAddress Api.AsAddressAny addressText
    sponsor <- either (fail . show) pure (Api.anyAddressInEra Api.DijkstraEra source)
    let era = Api.ShelleyBasedEraDijkstra
        connection =
            Api.LocalNodeConnectInfo
                { Api.localConsensusModeParams = Api.CardanoModeParams (Api.EpochSlots 50)
                , Api.localNodeNetworkId = Api.Testnet (Api.NetworkMagic 42)
                , Api.localNodeSocketPath = Api.File socket
                }
    pparams <- queryDijkstra connection Api.QueryProtocolParameters
    before <- queryLedgerState connection
    unless (depositStore before == Funding.BackingSummary 0 mempty) $
        fail "Expected an empty deposit store on the fresh chain"
    funded@(Api.UTxO genesis) <- queryUTxO connection Api.QueryUTxOWhole
    (genesisInput, genesisCoin) <- case Map.toList genesis of
        [(input, Api.TxOut address value@Api.TxOutValueShelleyBased{} Api.TxOutDatumNone Api.ReferenceScriptNone)]
            | address == sponsor
                && Api.txOutValueToValue value == Api.lovelaceToValue 900_000_000_000 ->
                pure (input, 900_000_000_000)
        _ -> fail $ "Expected exactly one ordinary genesis output: " <> show genesis
    assetName <- either (fail . show) pure (Api.deserialiseFromRawBytes Api.AsAssetName "offer")
    let Api.PaymentKeyHash keyHash = Api.verificationKeyHash (Api.getVerificationKey payment)
        policyScript :: Era.SimpleScript LedgerEra
        policyScript = Era.SimpleScript (Native.mkRequireSignature (Keys.asWitness keyHash))
        policyId = Api.PolicyId (Api.fromShelleyScriptHash (Era.hashSimpleScript @Api.DijkstraEra policyScript))
        tokens = Api.valueFromList [(Api.AssetId policyId assetName, Api.Quantity 7)]
        scriptBytes = validatorBytes (Api.serialiseToRawBytes policyId) (Api.serialiseToRawBytes assetName)
    script <-
        either (fail . show) pure $
            Plutus.deserialisePlutusScriptInEra SPlutusV4 (SBS.fromShort scriptBytes) ::
            IO (Plutus.PlutusScriptInEra 'PlutusV4 LedgerEra)
    let scriptHash = Api.fromShelleyScriptHash (Plutus.hashPlutusScriptInEra @Api.DijkstraEra script)
        scriptAddress =
            Api.makeShelleyAddressInEra
                era
                (Api.Testnet (Api.NetworkMagic 42))
                (Api.PaymentCredentialByScript scriptHash)
                Api.NoStakeAddress
        scriptCoin = case kind of
            Ordinary -> 5_000_000
            StoreBacked -> 0
        collateralCoin = 10_000_000
        scriptValue = case kind of
            Ordinary -> Api.TxOutValueShelleyBased era (Api.toMaryValue (Api.lovelaceToValue scriptCoin <> tokens))
            StoreBacked -> Api.TxOutValueStoreBacked (Core.ApplicationAssets (Api.toMaryValue tokens))
        scriptOutput n =
            Api.TxOut
                scriptAddress
                scriptValue
                (Api.TxOutDatumInline Api.BabbageEraOnwardsDijkstra (datum n))
                Api.ReferenceScriptNone
        initialScriptOutput = scriptOutput initialDatum
        price output =
            Dijkstra.requiredUTxODeposit pparams $
                mkSized
                    (Core.eraProtVerLow @LedgerEra)
                    (Api.toShelleyTxOut era output)
        scriptDeposit = case kind of
            Ordinary -> 0
            StoreBacked -> price initialScriptOutput
        expectedStore txId = case kind of
            Ordinary -> Funding.BackingSummary 0 mempty
            StoreBacked ->
                Funding.BackingSummary scriptDeposit $
                    Map.singleton (Api.toShelleyTxIn (Api.TxIn txId (Api.TxIx 0))) scriptDeposit
        collateralOutput =
            Api.TxOut sponsor (Api.lovelaceToTxOutValue era collateralCoin) Api.TxOutDatumNone Api.ReferenceScriptNone
        mint =
            Exp.TxMintValue $
                Map.singleton
                    policyId
                    ( Api.PolicyAssets (Map.singleton assetName (Api.Quantity 7))
                    , Witness.AnyScriptWitnessSimple (Era.SScript policyScript)
                    )
    fundingDeclaration <- case kind of
        Ordinary -> pure TopTx.NoUTxODepositDeclaration
        StoreBacked ->
            maybe (fail "Expected positive backing for the store-backed script output") (pure . TopTx.DeclaresNetUTxODepositAllocation) $
                mkStrictlyPositiveCoin scriptDeposit
    let fundingContent =
            Exp.defaultTxBodyContent
                { Exp.txNetUTxODepositChange = fundingDeclaration
                }
                & Exp.setTxIns [(genesisInput, Exp.AnyKeyWitnessPlaceholder)]
                & Exp.setTxOuts (map (Exp.TxOut . Api.toShelleyTxOut era) [initialScriptOutput, collateralOutput])
                & Exp.setTxMintValue mint
    (funding, _) <- AutoBalance.balance connection pparams funded (Funding.outputStore before) fundingContent sponsor
    assertBody funding (Set.singleton genesisInput) fundingDeclaration
    fundingChange <- case outputsOf funding of
        [actualScript, actualCollateral, change]
            | actualScript == initialScriptOutput && actualCollateral == collateralOutput -> pure change
        _ -> fail "Funding must preserve the script and collateral outputs and add one change output"
    let fundingFee = feeOf funding
        expectedFundingChangeCoin = genesisCoin - scriptCoin - collateralCoin - scriptDeposit - fundingFee
    assertChange sponsor expectedFundingChangeCoin fundingChange
    let commonEvidence =
            [ "scriptLanguage" .= ("PlutusV4" :: Text.Text)
            , "scriptHash" .= Api.serialiseToRawBytesHexText scriptHash
            , "scriptAddress" .= Api.serialiseAddress scriptAddress
            , "policyId" .= Api.serialiseToRawBytesHexText policyId
            , "assetName" .= Api.serialiseToRawBytesHexText assetName
            , "tokenQuantity" .= (7 :: Int)
            , "scriptOutputLovelace" .= scriptCoin
            , "outputKind" .= case kind of
                Ordinary -> ("implicit" :: Text.Text)
                StoreBacked -> "store-backed"
            ]
        fundingEvidence =
            [ "feeLovelace" .= fundingFee
            , "changeLovelace" .= expectedFundingChangeCoin
            , "collateralLovelace" .= collateralCoin
            , "storeDepositLovelace" .= scriptDeposit
            , "datum" .= initialDatum
            , "automaticFeeAndChangeVerified" .= True
            ]
                <> commonEvidence
    writeEvidence directory (evidencePrefix <> "-funding-balanced.json") (object fundingEvidence)
    BS.writeFile (directory </> "plutus-v4-validator.cbor") (SBS.fromShort scriptBytes)
    (fundingId, fundingUTxO, fundingStore) <-
        submitAndVerify directory (evidencePrefix <> "-funding") connection payment funding Map.empty expectedStore (totalAda before) fundingEvidence

    -- Exercise the public query with UTxO from the same acquired snapshot,
    -- independently comparing its records with the verified ledger store.
    let fundingInputs = Map.keysSet (Api.unUTxO fundingUTxO)
    queryResult <-
        Api.executeLocalStateQueryExpr connection Network.VolatileTip $
            (,)
                <$> Api.queryUtxo era (Api.QueryUTxOByTxIn fundingInputs)
                <*> Api.queryUTxOAllocations era fundingInputs
    (utxoResult, allocationsResult) <- either (fail . show) pure queryResult
    queriedFundingUTxO <- either (fail . show) pure utxoResult >>= either (fail . show) pure
    queriedAllocations <- either (fail . Api.displayError) pure allocationsResult
    unless
        ( queriedFundingUTxO == fundingUTxO
            && queriedAllocations
                == Allocations.restrictToInputs
                    (Set.map Api.toShelleyTxIn fundingInputs)
                    (State.allocations fundingStore)
        )
        $ fail "The acquired UTxO/backing query differs from the independently verified funding state"

    putStrLn "RUN node assertions: execute the V4 validator and advance its inline datum"
    let scriptInput = Api.TxIn fundingId (Api.TxIx 0)
        collateralInput = Api.TxIn fundingId (Api.TxIx 1)
        sponsorInput = Api.TxIn fundingId (Api.TxIx 2)
        continuation = scriptOutput (initialDatum + 1)
        continuationDeposit = case kind of
            Ordinary -> 0
            StoreBacked -> price continuation
        continuationBacking = case Api.toShelleyTxOut era continuation of
            Core.LegacyTxOut output ->
                Core.getMinCoinSizedTxOut pparams $
                    mkSized (Core.eraProtVerLow @LedgerEra) output
            Core.NewTxOut{} -> continuationDeposit
    recordedInputDeposit <- case kind of
        Ordinary -> pure 0
        StoreBacked ->
            maybe (fail "The funded script input has no recorded backing allocation") pure $
                Map.lookup (Api.toShelleyTxIn scriptInput) (Funding.backingAmounts fundingStore)
    recordedInputBacking <- case kind of
        Ordinary -> do
            entry <-
                maybe (fail "The funded script input has no accepted allocation entry") pure $
                    Map.lookup (Api.toShelleyTxIn scriptInput) $
                        State.unAllocations $ State.allocations fundingStore
            case State.legacyMinimumAtCreation entry of
                SNothing -> fail "The funded implicit script input has no recorded creation minimum"
                SJust minimumAtCreation -> pure minimumAtCreation
        StoreBacked -> pure recordedInputDeposit
    let expectedInputTotal = scriptCoin + recordedInputDeposit
        expectedOutputTotal = scriptCoin + continuationDeposit
        backingData allocation = case kind of
            Ordinary -> Api.ScriptDataConstructor 0 [Api.ScriptDataNumber (unCoin allocation)]
            StoreBacked -> Api.ScriptDataConstructor 1 [Api.ScriptDataNumber (unCoin allocation)]
        -- IsData encoding of (Integer, MinUTxOBacking, Integer, MinUTxOBacking).
        contextExpectations inputTotal =
            Api.unsafeHashableScriptData $
                Api.ScriptDataConstructor
                    0
                    [ Api.ScriptDataNumber (unCoin inputTotal)
                    , backingData recordedInputBacking
                    , Api.ScriptDataNumber (unCoin expectedOutputTotal)
                    , backingData continuationBacking
                    ]
        scriptWitnessWithContext expectedContext units =
            Exp.AnyPlutusScriptWitness $
                Witness.AnyPlutusSpendingScriptWitness $
                    Witness.PlutusSpendingScriptWitnessV4 $
                        Plutus.PlutusScriptWitness
                            SPlutusV4
                            (Plutus.PScript script)
                            Plutus.InlineDatum
                            expectedContext
                            units
        scriptWitnessWithUnits = scriptWitnessWithContext (contextExpectations expectedInputTotal)
        scriptWitness = scriptWitnessWithUnits (Api.ExecutionUnits 0 0)
    writeEvidence directory (evidencePrefix <> "-context-expectations.json") $
        object
            [ "inputTotalLovelace" .= expectedInputTotal
            , "outputTotalLovelace" .= expectedOutputTotal
            , "inputBackingLovelace" .= recordedInputBacking
            , "outputBackingLovelace" .= continuationBacking
            , "inputSeparateDepositLovelace" .= recordedInputDeposit
            , "outputSeparateDepositLovelace" .= continuationDeposit
            , "backingKind" .= case kind of
                Ordinary -> ("implicit" :: Text.Text)
                StoreBacked -> "explicit"
            , "allocationQueryMatchesLedgerStore" .= True
            , "allocationQuerySharesUTxOSnapshot" .= True
            ]
    if spendCase == NestedParent
        then
            spendNestedParent
                directory
                connection
                pparams
                payment
                sponsor
                fundingId
                fundingUTxO
                fundingStore
                (totalAda before)
                expectedFundingChangeCoin
                continuation
                scriptWitnessWithUnits
        else do
            unless (continuationDeposit == recordedInputDeposit) $
                fail "The continuation's required backing differs from the script input's recorded allocation"
            let spendDeclaration = case kind of
                    Ordinary -> TopTx.NoUTxODepositDeclaration
                    StoreBacked -> TopTx.DeclaresZeroNetUTxODeposit
                spendContent =
                    Exp.defaultTxBodyContent
                        { Exp.txNetUTxODepositChange = spendDeclaration
                        }
                        & Exp.setTxIns [(scriptInput, scriptWitness), (sponsorInput, Exp.AnyKeyWitnessPlaceholder)]
                        & Exp.setTxInsCollateral [collateralInput]
                        & Exp.setTxOuts [Exp.TxOut (Api.toShelleyTxOut era continuation)]
                        & Exp.setTxProtocolParams pparams
            (spend, balancedContent) <- AutoBalance.balance connection pparams fundingUTxO fundingStore spendContent sponsor
            assertBody spend (Set.fromList [scriptInput, sponsorInput]) spendDeclaration
            unless
                ( Exp.txInsCollateral balancedContent == [collateralInput]
                    && Exp.txScriptValidity balancedContent == Api.ScriptValid
                )
                $ fail "Balancing must preserve the disjoint ordinary collateral and valid-script flag"
            executionUnits <- case [ Witness.getAnyPlutusScriptWitnessExecutionUnits witness
                                   | (_, Exp.AnyPlutusScriptWitness witness) <- Exp.txIns balancedContent
                                   ] of
                [units] | Api.executionSteps units > 0 && Api.executionMemory units > 0 -> pure units
                _ -> fail "Expected exactly one evaluated Plutus spending witness with positive execution units"
            spendChange <- case outputsOf spend of
                [actualContinuation, change] | actualContinuation == continuation -> pure change
                _ -> fail "The script spend must preserve its full address and value, advance datum to 1, and add one sponsor change output"
            let spendFee = feeOf spend
                expectedSpendChangeCoin = expectedFundingChangeCoin - spendFee
                spendEvidence =
                    [ "scriptInput" .= show scriptInput
                    , "sponsorInput" .= show sponsorInput
                    , "collateralInput" .= show collateralInput
                    , "collateralLovelace" .= collateralCoin
                    , "feeLovelace" .= spendFee
                    , "sponsorChangeLovelace" .= expectedSpendChangeCoin
                    , "executionUnits" .= executionUnits
                    , "initialDatum" .= (0 :: Int)
                    , "continuationDatum" .= (1 :: Int)
                    , "recordedStoreBackingLovelace" .= recordedInputDeposit
                    , "continuationStoreBackingLovelace" .= continuationDeposit
                    , "validatorInputTotalLovelace" .= expectedInputTotal
                    , "validatorOutputTotalLovelace" .= expectedOutputTotal
                    , "validatorBackingMetadataVerified" .= True
                    , "automaticFeeAndChangeVerified" .= True
                    , "scriptValuePreserved" .= True
                    ]
                        <> commonEvidence
            assertChange sponsor expectedSpendChangeCoin spendChange
            writeEvidence directory (evidencePrefix <> "-spend-balanced.json") (object spendEvidence)
            when checkInvalidDatum $ do
                putStrLn "RUN validator rejection assertion: datum 0 to 2 against the same unspent script input"
                let invalidContinuation = scriptOutput 2
                    invalidContent =
                        spendContent
                            & Exp.setTxOuts [Exp.TxOut (Api.toShelleyTxOut era invalidContinuation)]
                unless (price invalidContinuation == continuationDeposit) $
                    fail "The invalid datum control changed the required store backing"
                unless (Exp.txScriptValidity invalidContent == Api.ScriptValid) $
                    fail "The invalid datum control must retain ScriptValid"
                inputPosition <-
                    maybe (fail "The script input is missing from the invalid datum control") pure $
                        Set.lookupIndex scriptInput (Set.fromList (map fst (Exp.txIns invalidContent)))
                let expectedIndex = Api.ScriptWitnessIndexTxIn (fromIntegral inputPosition)
                systemStart <-
                    runExceptT (Api.queryNodeLocalState connection Network.VolatileTip Api.QuerySystemStart)
                        >>= either (fail . show) pure
                history <-
                    runExceptT (Api.queryNodeLocalState connection Network.VolatileTip Api.QueryEraHistory)
                        >>= either (fail . show) pure
                let invalidBalance =
                        Exp.makeTransactionBodyAutoBalance @Api.DijkstraEra
                            systemStart
                            (Api.toLedgerEpochInfo history)
                            pparams
                            Set.empty
                            Map.empty
                            Map.empty
                            (Api.toLedgerUTxO era fundingUTxO)
                            (State.allocations fundingStore)
                            invalidContent
                            sponsor
                            Nothing
                (rejection, executionLogs) <- case invalidBalance of
                    Left err@(Exp.TxBodyScriptExecutionError [(index, Api.ScriptErrorEvaluationFailed debug)]) -> do
                        unless (index == expectedIndex) $
                            fail "The invalid datum control failed at an unexpected witness index"
                        unless
                            ( LedgerPlutus.pwcScriptHash (Api.dpfScriptWithContext debug)
                                == Api.toShelleyScriptHash scriptHash
                            )
                            $ fail "The invalid datum control failed in a different validator"
                        -- The pinned plutus-tx 1.71 library emits PT5 for check False.
                        -- Require this precise failure, not a decoder or budget error.
                        unless (Api.dpfExecutionLogs debug == ["PT5"]) $
                            fail $
                                "Expected the validator's failed application check: " <> Api.displayError err
                        pure (Api.displayError err, Api.dpfExecutionLogs debug)
                    Left err -> fail $ "Unexpected invalid datum control failure: " <> Api.displayError err
                    Right _ -> fail "The validator accepted the invalid datum transition from 0 to 2"
                unchangedUTxO <- queryUTxO connection Api.QueryUTxOWhole
                unless (unchangedUTxO == fundingUTxO) $
                    fail "The funded UTxO changed during the unsubmitted invalid datum control"
                afterRejection <- queryLedgerState connection
                verifyStore (Funding.BackingSummary (State.toCoin $ State.totalDepositAmount fundingStore) (Funding.backingAmounts fundingStore)) (totalAda before) afterRejection
                writeEvidence directory (evidencePrefix <> "-rejected-datum.json") $
                    object $
                        [ "stage" .= ("balancer-script-evaluation" :: Text.Text)
                        , "scriptInput" .= show scriptInput
                        , "witnessIndex" .= expectedIndex
                        , "initialDatum" .= (0 :: Int)
                        , "rejectedContinuationDatum" .= (2 :: Int)
                        , "executionLogs" .= executionLogs
                        , "rejection" .= rejection
                        , "invalidTransactionSubmitted" .= False
                        , "wholeUTxOUnchanged" .= True
                        , "depositStore" .= depositStore afterRejection
                        , "totalAdaBefore" .= totalAda before
                        , "totalAdaAfter" .= totalAda afterRejection
                        ]
                            <> commonEvidence
                putStrLn "PASS: the same validator rejected datum 0 to 2; input, collateral and backing remain unspent"

                putStrLn "RUN node rejection assertion: incorrect expected input total with ScriptValid"
                let wrongInputTotal = expectedInputTotal + 1
                    wrongTotalWitness = scriptWitnessWithContext (contextExpectations wrongInputTotal) executionUnits
                    wrongTotalContent =
                        balancedContent
                            & Exp.setTxIns
                                [ (input, if input == scriptInput then wrongTotalWitness else witness)
                                | (input, witness) <- Exp.txIns balancedContent
                                ]
                unless (Exp.txScriptValidity wrongTotalContent == Api.ScriptValid) $
                    fail "The incorrect-total transaction must retain ScriptValid"
                wrongTotalUnsigned <-
                    either (fail . show) pure $
                        Exp.makeUnsignedTx Era.DijkstraEra wrongTotalContent
                let wrongKeyWitness = Exp.makeKeyWitness Era.DijkstraEra wrongTotalUnsigned (Api.WitnessPaymentKey payment)
                    Exp.SignedTx wrongTotalSigned = Exp.signTx Era.DijkstraEra [] [wrongKeyWitness] wrongTotalUnsigned
                    wrongTotalTx = Api.ShelleyTx era wrongTotalSigned
                    wrongTotalBytes = Api.serialiseToCBOR wrongTotalTx
                    validKeyWitness = Exp.makeKeyWitness Era.DijkstraEra spend (Api.WitnessPaymentKey payment)
                    Exp.SignedTx validSigned = Exp.signTx Era.DijkstraEra [] [validKeyWitness] spend
                    validBytes = Api.serialiseToCBOR (Api.ShelleyTx era validSigned)
                -- Only a same-width redeemer number changes. The constructor
                -- recalculates integrity hash; retain the valid budget and fee.
                unless
                    ( BS.length wrongTotalBytes == BS.length validBytes
                        && feeOf wrongTotalUnsigned == spendFee
                        && outputsOf wrongTotalUnsigned == outputsOf spend
                    )
                    $ fail "Changing the expected total changed the transaction size, fee or outputs"
                let wrongTotalEvaluation =
                        Exp.evaluateTransactionExecutionUnits @Api.DijkstraEra
                            systemStart
                            (Api.toLedgerEpochInfo history)
                            pparams
                            (Api.toLedgerUTxO era fundingUTxO)
                            (State.allocations fundingStore)
                            wrongTotalSigned
                wrongTotalLogs <- case Map.toList wrongTotalEvaluation of
                    [(index, Left (Api.ScriptErrorEvaluationFailed debug))]
                        | index == expectedIndex
                            && LedgerPlutus.pwcScriptHash (Api.dpfScriptWithContext debug) == Api.toShelleyScriptHash scriptHash
                            && Api.dpfExecutionLogs debug == ["input-total", "PT5"] ->
                            pure (Api.dpfExecutionLogs debug)
                    other -> fail $ "Expected only the input-total validator failure at the spending witness: " <> show other
                let Api.LedgerEpochInfo epochInfo = Api.toLedgerEpochInfo history
                    annotated =
                        Dijkstra.mkDijkstraStAnnTopTx
                            epochInfo
                            systemStart
                            pparams
                            (State.allocations fundingStore)
                            Map.empty
                            wrongTotalSigned
                contexts <- either (fail . show) pure (Dijkstra.dsattPlutusScriptsWithContext annotated)
                exactContext <- case contexts of
                    [context]
                        | LedgerPlutus.pwcScriptHash context == Api.toShelleyScriptHash scriptHash -> pure context
                    _ -> fail "The signed incorrect-total transaction must execute exactly the expected validator"
                -- Re-evaluate using the committed budget, which the node will
                -- enforce, rather than the estimator's maximum evaluation budget.
                case LedgerPlutus.evaluatePlutusWithContext PV4.Verbose exactContext of
                    (logs, Left _) | logs == wrongTotalLogs -> pure ()
                    other -> fail $ "The committed budget did not produce the exact input-total failure: " <> show other
                BS.writeFile (directory </> evidencePrefix <> "-wrong-total.cbor") wrongTotalBytes
                nodeRejection <- Api.submitTxToNodeLocal connection (Api.TxInMode era wrongTotalTx)
                nodeContextBytes <- rejectedPlutusContext nodeRejection
                unless (nodeContextBytes == Base64.encode (Plain.serialize' exactContext)) $
                    fail "The node rejected a different script context or execution budget"
                afterWrongTotalUTxO <- queryUTxO connection Api.QueryUTxOWhole
                unless (afterWrongTotalUTxO == fundingUTxO) $
                    fail "The node changed an input or collateral after rejecting the incorrect total"
                afterWrongTotal <- queryLedgerState connection
                unless (Funding.outputStore afterWrongTotal == fundingStore) $ fail "Rejected transaction changed accepted allocations"
                verifyStore (Funding.BackingSummary (State.toCoin $ State.totalDepositAmount fundingStore) (Funding.backingAmounts fundingStore)) (totalAda before) afterWrongTotal
                writeEvidence directory (evidencePrefix <> "-rejected-total.json") $
                    object $
                        [ "stage" .= ("node-script-validation" :: Text.Text)
                        , "scriptInput" .= show scriptInput
                        , "witnessIndex" .= expectedIndex
                        , "actualInputTotalLovelace" .= expectedInputTotal
                        , "incorrectExpectedInputTotalLovelace" .= wrongInputTotal
                        , "executionLogs" .= wrongTotalLogs
                        , "rejection" .= show nodeRejection
                        , "invalidTransactionSubmitted" .= True
                        , "scriptValid" .= True
                        , "nodeFailureContextMatchesLocalEvaluation" .= True
                        , "unchangedSerializedSizeAndFee" .= True
                        , "wholeUTxOUnchanged" .= True
                        , "depositStore" .= depositStore afterWrongTotal
                        , "totalAdaBefore" .= totalAda before
                        , "totalAdaAfter" .= totalAda afterWrongTotal
                        ]
                            <> commonEvidence
                putStrLn "PASS: the node rejected the incorrect total in the expected validator; input, collateral and backing remain unspent"
            _ <-
                submitAndVerify
                    directory
                    (evidencePrefix <> "-spend")
                    connection
                    payment
                    spend
                    (Map.singleton collateralInput collateralOutput)
                    expectedStore
                    (totalAda before)
                    spendEvidence
            putStrLn $ case kind of
                Ordinary -> "PASS: ordinary V4 validator executed and was included; seven tokens and script ADA preserved, datum advanced, sponsor paid the fee, collateral unspent"
                StoreBacked -> "PASS: store-backed V4 validator executed and was included; seven tokens and zero script ADA preserved, datum advanced, backing moved to the continuation, sponsor paid the fee, collateral unspent"
            when checkInvalidDatum $
                putStrLn "PASS: the same funded input and validator rejected the incorrect total on chain, then accepted the correct total and datum 0 to 1"

-- Require the single phase-two failure for a ScriptValid transaction. A phase-one
-- failure, an era mismatch or a submission transport error is not this control.
rejectedPlutusContext :: Api.TxSubmitResult -> IO BS.ByteString
rejectedPlutusContext result = case result of
    Api.TxSubmitFail
        (Consensus.TxValidationErrorInCardanoMode
            (Consensus.ShelleyTxValidationError Api.ShelleyBasedEraDijkstra
                (Dijkstra.DijkstraApplyTxError failures))) ->
            case toList failures of
                [ Dijkstra.LedgerFailure
                    (Dijkstra.DijkstraUtxowFailure
                        (Dijkstra.UtxoFailure
                            (Dijkstra.UtxosFailure
                                (Conway.ValidationTagMismatch Dijkstra.Phase2Valid
                                    (Alonzo.FailedUnexpectedly descriptions)))))
                    ] -> case toList descriptions of
                        [Alonzo.PlutusFailure _ encodedContext] -> pure encodedContext
                        _ -> unexpected
                _ -> unexpected
    _ -> unexpected
  where
    unexpected = fail $ "Expected only a ScriptValid ValidationTagMismatch with one Plutus failure: " <> show result

datum :: Integer -> Api.HashableScriptData
datum = Api.unsafeHashableScriptData . Api.ScriptDataNumber

outputsOf :: Exp.UnsignedTx LedgerEra -> [Output]
outputsOf (Exp.UnsignedTx transaction) =
    map (Api.fromShelleyTxOut Api.ShelleyBasedEraDijkstra) (toList (transaction ^. Core.bodyTxL . Core.outputsTxBodyL))

feeOf :: Exp.UnsignedTx LedgerEra -> Coin
feeOf (Exp.UnsignedTx transaction) = transaction ^. Core.bodyTxL . Core.feeTxBodyL

assertBody :: Exp.UnsignedTx LedgerEra -> Set.Set Api.TxIn -> TopTx.TopTxUTxODepositDeclaration -> IO ()
assertBody (Exp.UnsignedTx transaction) expectedInputs expectedDeclaration = do
    let body = transaction ^. Core.bodyTxL
    unless
        ( body ^. Core.inputsTxBodyL == Set.map Api.toShelleyTxIn expectedInputs
            && body ^. Core.feeTxBodyL > 0
            && null (body ^. Dijkstra.subTransactionsTxBodyL)
            && body ^. Dijkstra.netUTxODepositChangeTxBodyL == expectedDeclaration
        )
        $ fail "Balancing must preserve the inputs and deposit declaration, charge a fee, and add no nested transactions"

assertChange :: Api.AddressInEra Api.DijkstraEra -> Coin -> Output -> IO ()
assertChange address coin actual =
    unless
        ( coin > 0
            && actual
                == Api.TxOut
                    address
                    (Api.lovelaceToTxOutValue Api.ShelleyBasedEraDijkstra coin)
                    Api.TxOutDatumNone
                    Api.ReferenceScriptNone
        )
        $ fail "The sponsor's ordinary ADA change does not match the independently calculated balance"

-- Compare the whole fresh-chain UTxO, so inclusion also proves the spent
-- inputs disappeared and any retained collateral remains unchanged.
submitAndVerify ::
    FilePath ->
    String ->
    Api.LocalNodeConnectInfo ->
    Api.SigningKey Api.PaymentKey ->
    Exp.UnsignedTx LedgerEra ->
    Map.Map Api.TxIn Output ->
    (Api.TxId -> Funding.BackingSummary) ->
    Coin ->
    [Pair] ->
    IO (Api.TxId, Api.UTxO Api.DijkstraEra, State.UTxOStore LedgerEra)
submitAndVerify directory name connection payment unsigned retained expectedStore expectedAda evidence = do
    let era = Api.ShelleyBasedEraDijkstra
        witness = Exp.makeKeyWitness Era.DijkstraEra unsigned (Api.WitnessPaymentKey payment)
        Exp.SignedTx signed = Exp.signTx Era.DijkstraEra [] [witness] unsigned
        transaction = Api.ShelleyTx era signed
        txId = Api.getTxId (Api.getTxBody transaction)
        created = Map.fromList (zipWith (\ix output -> (Api.TxIn txId (Api.TxIx ix), output)) [0 ..] (outputsOf unsigned))
        expected = Map.union created retained
        transactionEvidence =
            [ "txId" .= Api.serialiseToRawBytesHexText txId
            , "createdInputs" .= map show (Map.keys created)
            ]
                <> evidence
    BS.writeFile (directory </> name <> ".cbor") (Api.serialiseToCBOR transaction)
    result <- Api.submitTxToNodeLocal connection (Api.TxInMode era transaction)
    case result of
        Api.TxSubmitSuccess -> do
            writeEvidence directory (name <> "-submitted.json") $
                object (("acceptedIntoMempool" .= True) : transactionEvidence)
            putStrLn $ "Accepted into mempool: " <> Text.unpack (Api.serialiseToRawBytesHexText txId)
        _ -> do
            writeEvidence directory (name <> "-rejected.json") $
                object (("rejection" .= show result) : transactionEvidence)
            fail $ name <> " submission failed: " <> show result
    included <- timeout 120_000_000 (awaitExactUTxO connection (Map.keysSet created) expected)
    case included of
        Nothing -> fail $ "Timed out after 120 seconds waiting for " <> name <> " inclusion"
        Just () -> do
            after <- queryLedgerState connection
            verifyStore (expectedStore txId) expectedAda after
            writeEvidence directory (name <> "-included.json") $
                object $
                    [ "included" .= True
                    , "wholeUTxOMatches" .= True
                    , "retainedInputsUnchanged" .= True
                    , "depositStore" .= depositStore after
                    , "totalAdaBefore" .= expectedAda
                    , "totalAdaAfter" .= totalAda after
                    ]
                        <> transactionEvidence
            pure (txId, Api.UTxO expected, Funding.outputStore after)

awaitExactUTxO :: Api.LocalNodeConnectInfo -> Set.Set Api.TxIn -> Map.Map Api.TxIn Output -> IO ()
awaitExactUTxO connection created expected = do
    Api.UTxO actual <- queryUTxO connection Api.QueryUTxOWhole
    if Set.null (Map.keysSet actual `Set.intersection` created)
        then do
            threadDelay 1_000_000
            awaitExactUTxO connection created expected
        else
            unless (actual == expected) $
                fail $
                    "Included transaction's whole UTxO differs from the expected outputs and retained collateral: " <> show actual
