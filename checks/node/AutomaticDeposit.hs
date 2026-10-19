{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module AutomaticDeposit (createTokenOutput) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental as Era
import qualified Cardano.Api.Experimental.AnyScriptWitness as Witness
import qualified Cardano.Api.Experimental.Tx as Exp
import Cardano.Ledger.Binary (mkSized)
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra.Core as Dijkstra
import qualified Cardano.Ledger.Dijkstra.Rules as Dijkstra
import qualified Cardano.Ledger.Dijkstra.UTxODeposit.TopTx as TopTx
import qualified Cardano.Ledger.Keys as Keys
import qualified Cardano.Ledger.Shelley.Scripts as Native
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
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Lens.Micro ((^.))
import Submission (queryUTxO, writeEvidence)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Timeout (timeout)
import qualified TokenFunding as Funding

-- The caller selects an ordinary ADA input and requests a token-only output.
-- The API must calculate its backing as well as the fee and ordinary change.
createTokenOutput :: FilePath -> FilePath -> IO ()
createTokenOutput directory socket = do
    hSetBuffering stdout LineBuffering
    putStrLn "RUN node assertions: automatically calculate backing for one token-only output"
    payment <-
        Api.readFileTextEnvelope (Api.File (directory </> "payment.skey"))
            >>= either (fail . show) pure
    addressText <- Text.strip <$> Text.readFile (directory </> "address.txt")
    source <-
        maybe (fail "Invalid genesis payment address") pure $
            Api.deserialiseAddress Api.AsAddressAny addressText
    changeAddress <- either (fail . show) pure (Api.anyAddressInEra Api.DijkstraEra source)
    tokenOwnerAddressText <- Text.strip <$> Text.readFile (directory </> "token-owner-address.txt")
    tokenOwner <-
        maybe (fail "Invalid token owner address") pure $
            Api.deserialiseAddress Api.AsAddressAny tokenOwnerAddressText
    tokenAddress <- either (fail . show) pure (Api.anyAddressInEra Api.DijkstraEra tokenOwner)
    let connection =
            Api.LocalNodeConnectInfo
                { Api.localConsensusModeParams = Api.CardanoModeParams (Api.EpochSlots 50)
                , Api.localNodeNetworkId = Api.Testnet (Api.NetworkMagic 42)
                , Api.localNodeSocketPath = Api.File socket
                }
        era = Api.ShelleyBasedEraDijkstra
    pparams <- Funding.queryDijkstra connection Api.QueryProtocolParameters
    before <- Funding.queryLedgerState connection
    unless (Funding.depositStore before == State.DepositStore 0 mempty) $
        fail "Expected an empty deposit store on the fresh chain"
    Api.UTxO funded <- queryUTxO connection (Api.QueryUTxOByAddress (Set.singleton source))
    (input, inputValue) <- case Map.toList funded of
        [(txIn, Api.TxOut _ value@Api.TxOutValueShelleyBased{} Api.TxOutDatumNone Api.ReferenceScriptNone)] ->
            pure (txIn, Api.txOutValueToValue value)
        _ -> fail $ "Expected exactly one ordinary genesis output; got " <> show funded
    unless (inputValue == Api.lovelaceToValue 900_000_000_000) $
        fail $
            "Unexpected genesis funding: " <> show inputValue
    assetName <- either (fail . show) pure (Api.deserialiseFromRawBytes Api.AsAssetName "offer")
    let Api.PaymentKeyHash keyHash = Api.verificationKeyHash (Api.getVerificationKey payment)
        policyScript :: Era.SimpleScript (Api.ShelleyLedgerEra Api.DijkstraEra)
        policyScript = Era.SimpleScript (Native.mkRequireSignature (Keys.asWitness keyHash))
        policyId = Api.PolicyId (Api.fromShelleyScriptHash (Era.hashSimpleScript @Api.DijkstraEra policyScript))
        mint =
            Exp.TxMintValue $
                Map.singleton
                    policyId
                    ( Api.PolicyAssets (Map.singleton assetName (Api.Quantity 7))
                    , Witness.AnyScriptWitnessSimple (Era.SScript policyScript)
                    )
        tokens = Api.valueFromList [(Api.AssetId policyId assetName, Api.Quantity 7)]
        tokenOutput :: Api.TxOut Api.CtxUTxO Api.DijkstraEra
        tokenOutput =
            Api.TxOut
                tokenAddress
                (Api.TxOutValueStoreBacked (Core.ApplicationAssets (Api.toMaryValue tokens)))
                Api.TxOutDatumNone
                Api.ReferenceScriptNone
        -- Leave the default declaration absent: no amount is supplied here.
        content =
            Exp.defaultTxBodyContent
                & Exp.setTxIns [(input, Exp.AnyKeyWitnessPlaceholder)]
                & Exp.setTxOuts [Exp.TxOut (Api.toShelleyTxOut era tokenOutput)]
                & Exp.setTxMintValue mint
    unless (Exp.txNetUTxODepositChange content == TopTx.NoUTxODepositDeclaration) $
        fail "The caller must not supply a deposit declaration"
    (unsigned@(Exp.UnsignedTx balanced), balancedContent) <-
        AutoBalance.balance connection pparams (Api.UTxO funded) content changeAddress

    -- Calculate the oracle after the API call; it never becomes builder input.
    let deposit =
            Dijkstra.requiredUTxODeposit pparams $
                mkSized
                    (Core.eraProtVerLow @(Api.ShelleyLedgerEra Api.DijkstraEra))
                    (Api.toShelleyTxOut era tokenOutput)
    positiveDeposit <- maybe (fail "Expected a positive backing requirement") pure (mkStrictlyPositiveCoin deposit)
    let expectedDeclaration = TopTx.DeclaresNetUTxODepositAllocation positiveDeposit
        body = balanced ^. Core.bodyTxL
        actualDeclaration = body ^. Dijkstra.netUTxODepositChangeTxBodyL
        returnedDeclaration = Exp.txNetUTxODepositChange balancedContent
        fee = body ^. Core.feeTxBodyL
        inputCoin = Api.selectLovelace inputValue
        expectedChangeCoin = inputCoin - fee - deposit
        outputs = map (Api.fromShelleyTxOut era) (toList (body ^. Core.outputsTxBodyL))
        actualChangeCoin = case outputs of
            [_, Api.TxOut _ value _ _] -> Just (Api.selectLovelace (Api.txOutValueToValue value))
            _ -> Nothing
        evidence =
            [ "spentInput" .= show input
            , "policyId" .= Api.serialiseToRawBytesHexText policyId
            , "tokenOwnerAddress" .= tokenOwnerAddressText
            , "tokensPerOutput" .= (7 :: Int)
            , "tokenOutputLovelace" .= (0 :: Int)
            , "callerDeclaration" .= show (Exp.txNetUTxODepositChange content)
            , "expectedDeclaration" .= show expectedDeclaration
            , "actualDeclaration" .= show actualDeclaration
            , "returnedContentDeclaration" .= show returnedDeclaration
            , "inputLovelace" .= inputCoin
            , "requiredDepositLovelace" .= deposit
            , "feeLovelace" .= fee
            , "expectedChangeLovelace" .= expectedChangeCoin
            , "actualChangeLovelace" .= actualChangeCoin
            ]
    writeEvidence directory "automatic-deposit-balanced.json" $
        object (("submitted" .= False) : evidence)
    unless (actualDeclaration == expectedDeclaration && returnedDeclaration == expectedDeclaration) $
        fail $
            "Automatic balancing did not calculate the store deposit: expected "
                <> show expectedDeclaration
                <> ", got body "
                <> show actualDeclaration
                <> " and returned content "
                <> show returnedDeclaration
    unless
        ( body ^. Core.inputsTxBodyL == Set.singleton (Api.toShelleyTxIn input)
            && null (body ^. Dijkstra.subTransactionsTxBodyL)
            && null (body ^. Dijkstra.collateralInputsTxBodyL)
            && body ^. Core.withdrawalsTxBodyL == mempty
            && null (body ^. Core.certsTxBodyL)
        )
        $ fail "Automatic deposit calculation changed the selected input or added another funding source"
    unless (fee > 0 && expectedChangeCoin > 0) $
        fail "Expected a positive fee and remaining ADA change after paying the deposit"
    let expectedChange =
            Api.TxOut changeAddress (Api.lovelaceToTxOutValue era expectedChangeCoin) Api.TxOutDatumNone Api.ReferenceScriptNone
    unless (outputs == [tokenOutput, expectedChange]) $
        fail "Automatic balancing must preserve the token output and deduct both backing and fee from ADA change"
    putStrLn "PASS balancing: exact deposit declaration, token output, fee and ADA change verified"

    let witness = Exp.makeKeyWitness Era.DijkstraEra unsigned (Api.WitnessPaymentKey payment)
        Exp.SignedTx signed = Exp.signTx Era.DijkstraEra [] [witness] unsigned
        transaction = Api.ShelleyTx era signed
        txId = Api.getTxId (Api.getTxBody transaction)
        created = Map.fromList (zipWith (\ix output -> (Api.TxIn txId (Api.TxIx ix), output)) [0 ..] outputs)
        Api.UTxO original = Api.fromLedgerUTxO era (before ^. State.utxoL)
        expectedUTxO = Map.union created (Map.delete input original)
        expectedStore =
            State.DepositStore deposit $
                Map.singleton (Api.toShelleyTxIn (Api.TxIn txId (Api.TxIx 0))) deposit
        submittedEvidence =
            [ "txId" .= Api.serialiseToRawBytesHexText txId
            , "createdInputs" .= map show (Map.keys created)
            , "automaticDepositFeeAndChangeVerified" .= True
            ]
                <> evidence
    BS.writeFile (directory </> "automatic-deposit.cbor") (Api.serialiseToCBOR transaction)
    result <- Api.submitTxToNodeLocal connection (Api.TxInMode era transaction)
    case result of
        Api.TxSubmitSuccess -> do
            writeEvidence directory "automatic-deposit-submitted.json" $
                object (("acceptedIntoMempool" .= True) : submittedEvidence)
            putStrLn "Accepted automatically backed token output into mempool"
        _ -> do
            writeEvidence directory "automatic-deposit-rejected.json" $
                object (("rejection" .= show result) : submittedEvidence)
            fail $ "Automatic deposit submission failed: " <> show result
    included <- timeout 120_000_000 $ awaitInclusion connection (Map.keysSet created) expectedUTxO
    after <- maybe (fail "Timed out waiting for automatic deposit transaction inclusion") pure included
    Funding.verifyStore expectedStore (Funding.totalAda before) after
    writeEvidence directory "automatic-deposit-included.json" $
        object $
            [ "included" .= True
            , "inputConsumed" .= True
            , "wholeUTxOMatches" .= True
            , "depositStoreBefore" .= Funding.depositStore before
            , "depositStoreAfter" .= Funding.depositStore after
            , "totalAdaBefore" .= Funding.totalAda before
            , "totalAdaAfter" .= Funding.totalAda after
            ]
                <> submittedEvidence
    putStrLn "PASS: automatically backed output included; exact UTxO, store allocation and total ADA verified"

awaitInclusion :: Api.LocalNodeConnectInfo -> Set.Set Api.TxIn -> Map.Map Api.TxIn (Api.TxOut Api.CtxUTxO Api.DijkstraEra) -> IO Funding.LiveState
awaitInclusion connection created expected = do
    state <- Funding.queryLedgerState connection
    let Api.UTxO actual = Api.fromLedgerUTxO Api.ShelleyBasedEraDijkstra (state ^. State.utxoL)
    if Map.null (Map.restrictKeys actual created)
        then threadDelay 1_000_000 >> awaitInclusion connection created expected
        else do
            unless (actual == expected) $
                fail "Automatic deposit UTxO differs from the token output, ADA change and untouched inputs"
            pure state
