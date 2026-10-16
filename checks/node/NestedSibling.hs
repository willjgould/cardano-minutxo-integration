{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module NestedSibling (submitSiblingFunded) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental as Era
import qualified Cardano.Api.Experimental.Tx as Exp
import Cardano.Ledger.Binary (mkSized)
import Cardano.Ledger.Coin (Coin)
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra.Core as Dijkstra
import qualified Cardano.Ledger.Dijkstra.Rules as Dijkstra
import qualified Cardano.Ledger.Dijkstra.UTxODeposit.SubTx as SubTx
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
import qualified Data.Text.IO as Text
import Lens.Micro ((^.))
import NestedCommon (awaitInclusion, signTokenContribution, splitTokenOutput, verifyDistinctOwners, verifyOwnerWitness)
import Submission (writeEvidence)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Timeout (timeout)
import qualified TokenFunding as Funding

-- Two signed children supply tokens and deposit ADA separately. The parent's
-- own input pays only the fee; it records the net deposit exactly once.
-- Token owner, ADA sibling, and parent each sign only their own body.
-- The API calculates the parent's fee/change from all three selected inputs.
submitSiblingFunded :: FilePath -> FilePath -> IO ()
submitSiblingFunded directory socket = do
    hSetBuffering stdout LineBuffering
    payment <-
        Api.readFileTextEnvelope (Api.File (directory </> "payment.skey"))
            >>= either (fail . show) pure
    tokenOwner <-
        Api.readFileTextEnvelope (Api.File (directory </> "token-owner.skey"))
            >>= either (fail . show) pure
    siblingOwner <-
        Api.readFileTextEnvelope (Api.File (directory </> "sibling-owner.skey"))
            >>= either (fail . show) pure
    verifyDistinctOwners [payment, tokenOwner, siblingOwner]
    let connection =
            Api.LocalNodeConnectInfo
                { Api.localConsensusModeParams = Api.CardanoModeParams (Api.EpochSlots 50)
                , Api.localNodeNetworkId = Api.Testnet (Api.NetworkMagic 42)
                , Api.localNodeSocketPath = Api.File socket
                }
        era = Api.ShelleyBasedEraDijkstra
    funded <- Funding.queryLedgerState connection
    pparams <- Funding.queryDijkstra connection Api.QueryProtocolParameters
    let Api.UTxO fundedUTxO = Api.fromLedgerUTxO era (funded ^. State.utxoL)
        store = Funding.depositStore funded
        tokenInputs =
            [(input, output) | (input, output@(Api.TxOut _ Api.TxOutValueStoreBacked{} _ _)) <- Map.toAscList fundedUTxO]
        adaInputs =
            [(input, output) | (input, output@(Api.TxOut _ Api.TxOutValueShelleyBased{} _ _)) <- Map.toAscList fundedUTxO]
    ((tokenInput, tokenOutput), (fundingInput, fundingOutput@(Api.TxOut address _ _ _))) <-
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
    positiveDeposit <-
        maybe (fail "The child split must require a positive additional deposit") pure $
            mkStrictlyPositiveCoin netDeposit

    -- A real ordinary transaction separates the sibling's deposit ADA from the
    -- parent's ADA. Neither nested child spends a synthetic or shared input.
    (before, siblingInput, parentInput) <-
        prepareAdaInputs directory connection payment funded fundingInput fundingOutput netDeposit
    let Api.UTxO original = Api.fromLedgerUTxO era (before ^. State.utxoL)
    parentCoin <- adaInputCoin original parentInput
    siblingCoin <- adaInputCoin original siblingInput
    unless (siblingCoin == netDeposit) $
        fail "The ADA sibling input must fund exactly the child's additional deposit"
    putStrLn "RUN node assertions: automatically balance token and ADA siblings with the parent paying only the fee"
    tokenContribution <- signTokenContribution tokenOwner tokenInput tokenOutputs positiveDeposit
    adaContribution <- signAdaContribution siblingOwner siblingInput
    let selectedUTxO = Api.UTxO (Map.restrictKeys original (Set.fromList [parentInput, tokenInput, siblingInput]))
    transaction <- buildParent connection pparams selectedUTxO payment parentInput address positiveDeposit tokenContribution adaContribution
    (fee, changeOutput) <- case transaction of
        Api.ShelleyTx _ signed ->
            let body = signed ^. Core.bodyTxL
             in case toList (body ^. Core.outputsTxBodyL) of
                    [output] -> pure (body ^. Core.feeTxBodyL, Api.fromShelleyTxOut era output)
                    _ -> fail "Automatic balancing must create exactly one parent change output"
    -- Check the API's result independently: the sibling already covers the
    -- net deposit, so the parent's own ADA must pay only the calculated fee.
    let changeCoin = parentCoin - fee
    unless (fee > 0 && changeCoin > 0 && changeOutput == adaOutput address changeCoin) $
        fail "Automatically balanced parent must return all its ADA except the fee"

    let Exp.SignedSubTx tokenChild = tokenContribution
        Exp.SignedSubTx adaChild = adaContribution
        tokenId = Api.fromShelleyTxId (Core.txIdTxBody (tokenChild ^. Core.bodyTxL))
        adaId = Api.fromShelleyTxId (Core.txIdTxBody (adaChild ^. Core.bodyTxL))
        parentId = Api.getTxId (Api.getTxBody transaction)
        childInputs = [Api.TxIn tokenId (Api.TxIx ix) | ix <- [0, 1]]
        created = Map.fromList $ (Api.TxIn parentId (Api.TxIx 0), changeOutput) : zip childInputs tokenOutputs
        spent = Set.fromList [tokenInput, siblingInput, parentInput]
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
            , "tokenChildTxId" .= Api.serialiseToRawBytesHexText tokenId
            , "adaChildTxId" .= Api.serialiseToRawBytesHexText adaId
            , "childCount" .= (2 :: Int)
            , "parentOwnerKeyHash" .= Api.serialiseToRawBytesHexText (Api.verificationKeyHash (Api.getVerificationKey payment))
            , "tokenOwnerKeyHash" .= Api.serialiseToRawBytesHexText (Api.verificationKeyHash (Api.getVerificationKey tokenOwner))
            , "siblingOwnerKeyHash" .= Api.serialiseToRawBytesHexText (Api.verificationKeyHash (Api.getVerificationKey siblingOwner))
            , "inputOwnershipAndWitnessesVerified" .= True
            , "automaticFeeAndChangeVerified" .= True
            , "tokenInput" .= show tokenInput
            , "siblingInput" .= show siblingInput
            , "parentInput" .= show parentInput
            , "tokenChildInputsLovelace" .= (0 :: Int)
            , "tokenChildOutputsLovelace" .= (0 :: Int)
            , "childOutputTokens" .= ([3, 4] :: [Int])
            , "releasedDepositLovelace" .= released
            , "newAllocationsLovelace" .= allocations
            , "siblingFundedDepositLovelace" .= siblingCoin
            , "parentInputsLovelace" .= parentCoin
            , "parentNetSpendLovelace" .= (parentCoin - changeCoin)
            , "parentDeclaredDepositLovelace" .= netDeposit
            , "feeLovelace" .= fee
            , "changeLovelace" .= changeCoin
            ]
    -- Check the assembled transaction, so accidentally moving the sibling input
    -- to the parent cannot turn this into another parent-funded example.
    case transaction of
        Api.ShelleyTx _ signed -> do
            verifyOwnerWitness payment original signed
            let body = signed ^. Core.bodyTxL
            unless (body ^. Core.inputsTxBodyL == Set.singleton (Api.toShelleyTxIn parentInput)) $
                fail "Parent must spend only its own fee-paying input"
            unless (body ^. Dijkstra.netUTxODepositChangeTxBodyL == TopTx.DeclaresNetUTxODepositAllocation positiveDeposit) $
                fail "Automatic balancing must preserve the explicit parent deposit declaration"
            unless (toList (body ^. Dijkstra.subTransactionsTxBodyL) == [tokenChild, adaChild]) $
                fail "Parent must contain the separately signed token and ADA siblings"
            verifyOwnerWitness tokenOwner original tokenChild
            verifyOwnerWitness siblingOwner original adaChild
    BS.writeFile (directory </> "nested-sibling.cbor") (Api.serialiseToCBOR transaction)
    result <- Api.submitTxToNodeLocal connection (Api.TxInMode era transaction)
    case result of
        Api.TxSubmitSuccess -> do
            writeEvidence directory "nested-sibling-submitted.json" $
                object (("acceptedIntoMempool" .= True) : evidence)
            putStrLn $ "Accepted into mempool: " <> Text.unpack (Api.serialiseToRawBytesHexText parentId)
        _ -> do
            writeEvidence directory "nested-sibling-rejected.json" $
                object (("rejection" .= show result) : evidence)
            fail $ "Sibling-funded nested submission failed: " <> show result
    included <- timeout 120_000_000 $ awaitInclusion connection (Map.keysSet created) expectedUTxO
    after <- maybe (fail "Timed out waiting for sibling-funded nested inclusion") pure included
    Funding.verifyStore expectedStore (Funding.totalAda before) after
    writeEvidence directory "nested-sibling-included.json" $
        object $
            [ "included" .= True
            , "wholeUTxOMatches" .= True
            , "parentAndBothChildInputsConsumed" .= True
            , "depositStoreBefore" .= store
            , "depositStoreAfter" .= Funding.depositStore after
            , "totalAdaBefore" .= Funding.totalAda before
            , "totalAdaAfter" .= Funding.totalAda after
            ]
                <> evidence
    putStrLn "PASS: sibling-funded nested transaction included; token split, sibling-funded deposit, parent fee and total ADA verified"

-- Split the existing ADA change into an exact deposit input for the sibling
-- and a separate parent input. This is fixture preparation, using a fixed fee.
prepareAdaInputs ::
    FilePath ->
    Api.LocalNodeConnectInfo ->
    Api.SigningKey Api.PaymentKey ->
    Funding.LiveState ->
    Api.TxIn ->
    Api.TxOut Api.CtxUTxO Api.DijkstraEra ->
    Coin ->
    IO (Funding.LiveState, Api.TxIn, Api.TxIn)
prepareAdaInputs directory connection payment before input (Api.TxOut address value _ _) deposit = do
    putStrLn "RUN prerequisite: create separate sibling-deposit and parent-fee inputs"
    siblingAddressText <- Text.strip <$> Text.readFile (directory </> "sibling-owner-address.txt")
    siblingAddress <-
        maybe (fail "Invalid ADA sibling address") pure $
            Api.deserialiseAddress (Api.AsAddressInEra Api.AsDijkstraEra) siblingAddressText
    let era = Api.ShelleyBasedEraDijkstra
        inputValue = Api.txOutValueToValue value
        inputCoin = Api.selectLovelace inputValue
        fee = 1_000_000
        outputs = [adaOutput siblingAddress deposit, adaOutput address (inputCoin - deposit - fee)]
        Api.UTxO original = Api.fromLedgerUTxO era (before ^. State.utxoL)
    unless (inputValue == Api.lovelaceToValue inputCoin) $
        fail "ADA preparation input must contain only ADA"
    unsigned <-
        either (fail . show) pure $
            Exp.makeUnsignedTx Era.DijkstraEra $
                Exp.defaultTxBodyContent
                    & Exp.setTxIns [(input, Exp.AnyKeyWitnessPlaceholder)]
                    & Exp.setTxOuts (map (Exp.TxOut . Api.toShelleyTxOut era) outputs)
                    & Exp.setTxFee fee
    let witness = Exp.makeKeyWitness Era.DijkstraEra unsigned (Api.WitnessPaymentKey payment)
        Exp.SignedTx signed = Exp.signTx Era.DijkstraEra [] [witness] unsigned
        transaction = Api.ShelleyTx era signed
        txId = Api.getTxId (Api.getTxBody transaction)
        siblingInput = Api.TxIn txId (Api.TxIx 0)
        parentInput = Api.TxIn txId (Api.TxIx 1)
        created = Map.fromList (zip [siblingInput, parentInput] outputs)
        expected = Map.union created (Map.delete input original)
        evidence =
            [ "txId" .= Api.serialiseToRawBytesHexText txId
            , "spentInput" .= show input
            , "siblingInput" .= show siblingInput
            , "parentInput" .= show parentInput
            , "siblingInputLovelace" .= deposit
            , "parentInputLovelace" .= (inputCoin - deposit - fee)
            , "feeLovelace" .= fee
            ]
    BS.writeFile (directory </> "sibling-funding.cbor") (Api.serialiseToCBOR transaction)
    result <- Api.submitTxToNodeLocal connection (Api.TxInMode era transaction)
    case result of
        Api.TxSubmitSuccess ->
            writeEvidence directory "sibling-funding-submitted.json" $
                object (("acceptedIntoMempool" .= True) : evidence)
        _ -> do
            writeEvidence directory "sibling-funding-rejected.json" $
                object (("rejection" .= show result) : evidence)
            fail $ "ADA input preparation failed before sibling-funded submission: " <> show result
    included <- timeout 120_000_000 $ awaitInclusion connection (Map.keysSet created) expected
    after <- maybe (fail "Timed out waiting for separate ADA input funding") pure included
    Funding.verifyStore (Funding.depositStore before) (Funding.totalAda before) after
    writeEvidence directory "sibling-funding-included.json" $
        object $
            [ "included" .= True
            , "wholeUTxOMatches" .= True
            , "depositStoreUnchanged" .= True
            , "totalAdaBefore" .= Funding.totalAda before
            , "totalAdaAfter" .= Funding.totalAda after
            ]
                <> evidence
    putStrLn "PASS: separate sibling and parent ADA inputs included; store and total ADA unchanged"
    pure (after, siblingInput, parentInput)

-- The sibling supplies the deposit through aggregate transaction accounting.
-- It creates no output and has no deposit-store operation of its own.
signAdaContribution :: Api.SigningKey Api.PaymentKey -> Api.TxIn -> IO Exp.SignedSubTx
signAdaContribution payment input = do
    unsigned <-
        either (fail . show) pure $
            Exp.makeUnsignedSubTx
                Exp.defaultSubTxBodyContent
                    { Exp.subTxIns = [(input, Exp.AnyKeyWitnessPlaceholder)]
                    , Exp.subTxOuts = []
                    , Exp.subTxNetUTxODepositChange = SubTx.NoUTxODepositDeclaration
                    }
    let witness = Exp.makeSubTxKeyWitness unsigned (Api.WitnessPaymentKey payment)
    pure (Exp.signSubTx [] [witness] unsigned)

-- The parent declares the allocation once and pays only the fee from its own
-- input. Both children are signed before being embedded in the signed parent.
buildParent ::
    Api.LocalNodeConnectInfo ->
    Core.PParams (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    Api.UTxO Api.DijkstraEra ->
    Api.SigningKey Api.PaymentKey ->
    Api.TxIn ->
    Api.AddressInEra Api.DijkstraEra ->
    StrictlyPositiveCoin ->
    Exp.SignedSubTx ->
    Exp.SignedSubTx ->
    IO (Api.Tx Api.DijkstraEra)
buildParent connection pparams utxo payment input changeAddress deposit tokenChild adaChild = do
    let content =
            Exp.defaultTxBodyContent
                { Exp.txNetUTxODepositChange = TopTx.DeclaresNetUTxODepositAllocation deposit
                }
                & Exp.setTxIns [(input, Exp.AnyKeyWitnessPlaceholder)]
                & Exp.setTxSignedSubTransactions [tokenChild, adaChild]
    (unsigned, _) <- AutoBalance.balance connection pparams utxo content changeAddress
    let witness = Exp.makeKeyWitness Era.DijkstraEra unsigned (Api.WitnessPaymentKey payment)
        Exp.SignedTx signed = Exp.signTx Era.DijkstraEra [] [witness] unsigned
    pure (Api.ShelleyTx Api.ShelleyBasedEraDijkstra signed)

adaOutput :: Api.AddressInEra Api.DijkstraEra -> Coin -> Api.TxOut Api.CtxUTxO Api.DijkstraEra
adaOutput address coin =
    Api.TxOut address (Api.lovelaceToTxOutValue Api.ShelleyBasedEraDijkstra coin) Api.TxOutDatumNone Api.ReferenceScriptNone

adaInputCoin :: Map.Map Api.TxIn (Api.TxOut Api.CtxUTxO Api.DijkstraEra) -> Api.TxIn -> IO Coin
adaInputCoin utxo input = case Map.lookup input utxo of
    Just (Api.TxOut _ value Api.TxOutDatumNone Api.ReferenceScriptNone) -> do
        let assets = Api.txOutValueToValue value
            coin = Api.selectLovelace assets
        unless (assets == Api.lovelaceToValue coin) $ fail "Expected an ADA-only input"
        pure coin
    _ -> fail "Expected a funded ADA input without a datum or reference script"
