{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module CliTransaction (submitTokenOutput) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental as Era
import Cardano.Ledger.Binary (mkSized)
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra.Core as Dijkstra
import qualified Cardano.Ledger.Dijkstra.Rules as Dijkstra
import qualified Cardano.Ledger.Dijkstra.UTxOs.Deposit.TopTx as TopTx
import qualified Cardano.Ledger.Keys as Keys
import qualified Cardano.Ledger.Shelley.Scripts as Native
import Cardano.Ledger.StrictlyPositiveCoin (mkStrictlyPositiveCoin)

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Aeson (object, toJSON, (.=))
import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Lens.Micro ((^.))
import qualified NestedCommon
import Submission (queryUTxO, writeEvidence)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hPutStr, hSetBuffering, stderr, stdout)
import System.Process (readProcessWithExitCode, showCommandForUser)
import System.Timeout (timeout)
import qualified TokenFunding as Funding

-- The CLI performs every write operation. API decoding and node queries are
-- independent oracles; no API-built transaction is passed to the CLI.
submitTokenOutput :: FilePath -> FilePath -> FilePath -> IO ()
submitTokenOutput cli directory socket = do
    hSetBuffering stdout LineBuffering
    putStrLn "RUN node assertions: CLI build, sign and submit a token-only store-backed output"
    payment <-
        Api.readFileTextEnvelope (Api.File (directory </> "payment.skey"))
            >>= either (fail . show) pure
    sourceText <- Text.strip <$> Text.readFile (directory </> "address.txt")
    tokenOwnerText <- Text.strip <$> Text.readFile (directory </> "token-owner-address.txt")
    source <- maybe (fail "Invalid genesis payment address") pure $ Api.deserialiseAddress Api.AsAddressAny sourceText
    owner <- maybe (fail "Invalid token owner address") pure $ Api.deserialiseAddress Api.AsAddressAny tokenOwnerText
    unless (source /= owner) $ fail "Token recipient must be independent of the funding owner"
    changeAddress <- either (fail . show) pure (Api.anyAddressInEra Api.DijkstraEra source)
    tokenAddress <- either (fail . show) pure (Api.anyAddressInEra Api.DijkstraEra owner)
    let era = Api.ShelleyBasedEraDijkstra
        connection =
            Api.LocalNodeConnectInfo
                { Api.localConsensusModeParams = Api.CardanoModeParams (Api.EpochSlots 50)
                , Api.localNodeNetworkId = Api.Testnet (Api.NetworkMagic 42)
                , Api.localNodeSocketPath = Api.File socket
                }
    pparams <- Funding.queryDijkstra connection Api.QueryProtocolParameters
    before <- Funding.queryLedgerState connection
    unless (Funding.depositStore before == Funding.BackingSummary 0 mempty) $
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
    let paymentHash@(Api.PaymentKeyHash keyHash) = Api.verificationKeyHash (Api.getVerificationKey payment)
        policyScript :: Era.SimpleScript (Api.ShelleyLedgerEra Api.DijkstraEra)
        policyScript = Era.SimpleScript (Native.mkRequireSignature (Keys.asWitness keyHash))
        policyId = Api.PolicyId (Api.fromShelleyScriptHash (Era.hashSimpleScript @Api.DijkstraEra policyScript))
        asset = Text.unpack (Api.serialiseToRawBytesHexText policyId <> "." <> Api.serialiseToRawBytesHexText assetName)
        policyFile = directory </> "cli-transaction-policy.json"
        bodyFile = directory </> "cli-transaction-body.json"
        signedFile = directory </> "cli-transaction-signed.json"
        tokens = Api.valueFromList [(Api.AssetId policyId assetName, Api.Quantity 7)]
        tokenOutput :: Api.TxOut Api.CtxUTxO Api.DijkstraEra
        tokenOutput =
            Api.TxOut
                tokenAddress
                (Api.TxOutValueStoreBacked (Core.ApplicationAssets (Api.toMaryValue tokens)))
                Api.TxOutDatumNone
                Api.ReferenceScriptNone
    writeEvidence directory "cli-transaction-policy.json" $
        object ["type" .= ("sig" :: Text.Text), "keyHash" .= Api.serialiseToRawBytesHexText paymentHash]
    runCli
        cli
        directory
        "build"
        [ "dijkstra"
        , "transaction"
        , "build"
        , "--socket-path"
        , socket
        , "--testnet-magic"
        , "42"
        , "--tx-in"
        , Text.unpack (Api.renderTxIn input)
        , "--tx-out-store-backed"
        , Text.unpack tokenOwnerText <> "+0+7 " <> asset
        , "--change-address"
        , Text.unpack sourceText
        , "--mint"
        , "7 " <> asset
        , "--mint-script-file"
        , policyFile
        , "--out-file"
        , bodyFile
        ]
    unsigned@(Api.ShelleyTx _ built) <- readTransaction bodyFile
    -- Price only after CLI construction. This amount never enters its request.
    let deposit =
            Dijkstra.requiredUTxODeposit pparams $
                mkSized (Core.eraProtVerLow @(Api.ShelleyLedgerEra Api.DijkstraEra)) (Api.toShelleyTxOut era tokenOutput)
    positiveDeposit <- maybe (fail "Expected a positive backing requirement") pure (mkStrictlyPositiveCoin deposit)
    let body = built ^. Core.bodyTxL
        declaration = body ^. Dijkstra.netUTxODepositChangeTxBodyL
        expectedDeclaration = TopTx.DeclaresNetUTxODepositAllocation positiveDeposit
        fee = body ^. Core.feeTxBodyL
        inputCoin = Api.selectLovelace inputValue
        changeCoin = inputCoin - fee - deposit
        outputs = map (Api.fromShelleyTxOut era) (toList (body ^. Core.outputsTxBodyL))
        expectedChange = Api.TxOut changeAddress (Api.lovelaceToTxOutValue era changeCoin) Api.TxOutDatumNone Api.ReferenceScriptNone
        evidence =
            [ "spentInput" .= Api.renderTxIn input
            , "policyId" .= Api.serialiseToRawBytesHexText policyId
            , "tokenOwnerAddress" .= tokenOwnerText
            , "tokens" .= (7 :: Int)
            , "tokenOutputLovelace" .= (0 :: Int)
            , "inputLovelace" .= inputCoin
            , "requiredDepositLovelace" .= deposit
            , "actualDeclaration" .= show declaration
            , "expectedDeclaration" .= show expectedDeclaration
            , "feeLovelace" .= fee
            , "changeLovelace" .= changeCoin
            ]
    writeEvidence directory "cli-transaction-balanced.json" $ object evidence
    unless (declaration == expectedDeclaration) $
        fail $
            "CLI build did not calculate the expected deposit: " <> show declaration
    unless
        ( body ^. Core.inputsTxBodyL == Set.singleton (Api.toShelleyTxIn input)
            && Api.fromMultiAsset (body ^. Dijkstra.mintTxBodyL) == tokens
            && null (body ^. Dijkstra.subTransactionsTxBodyL)
            && null (body ^. Dijkstra.collateralInputsTxBodyL)
            && body ^. Core.withdrawalsTxBodyL == mempty
            && null (body ^. Core.certsTxBodyL)
        )
        $ fail "CLI build changed the input/mint or added another funding source"
    unless (fee > 0 && changeCoin > 0 && outputs == [tokenOutput, expectedChange]) $
        fail "CLI build must preserve the token output and return exact ordinary change after fee and backing"
    unless (null (built ^. Core.witsTxL . Core.addrTxWitsL)) $
        fail "CLI build unexpectedly supplied key witnesses"
    putStrLn "PASS CLI build: exact token output, deposit, fee and ordinary change verified"

    runCli
        cli
        directory
        "sign"
        [ "dijkstra"
        , "transaction"
        , "sign"
        , "--tx-file"
        , bodyFile
        , "--signing-key-file"
        , directory </> "payment.skey"
        , "--out-file"
        , signedFile
        ]
    transaction@(Api.ShelleyTx _ signed) <- readTransaction signedFile
    unless
        ( Api.getTxBody transaction == Api.getTxBody unsigned
            && signed ^. Core.witsTxL . Core.scriptTxWitsL == built ^. Core.witsTxL . Core.scriptTxWitsL
        )
        $ fail "CLI signing changed the transaction body or native mint witness"
    NestedCommon.verifyOwnerWitness payment funded signed
    putStrLn "PASS CLI sign: body/native script preserved and funding-owner signature verified"
    let txId = Api.getTxId (Api.getTxBody transaction)
        created = Map.fromList (zipWith (\ix output -> (Api.TxIn txId (Api.TxIx ix), output)) [0 ..] outputs)
        Api.UTxO original = Api.fromLedgerUTxO era (Funding.ledgerUTxO before)
        expectedUTxO = Map.union created (Map.delete input original)
        expectedStore =
            Funding.BackingSummary deposit $
                Map.singleton (Api.toShelleyTxIn (Api.TxIn txId (Api.TxIx 0))) deposit
        submittedEvidence = ("txId" .= Api.serialiseToRawBytesHexText txId) : evidence
    runCli
        cli
        directory
        "submit"
        [ "dijkstra"
        , "transaction"
        , "submit"
        , "--socket-path"
        , socket
        , "--testnet-magic"
        , "42"
        , "--tx-file"
        , signedFile
        ]
    writeEvidence directory "cli-transaction-submitted.json" $
        object (("acceptedIntoMempool" .= True) : submittedEvidence)
    included <- timeout 120_000_000 $ awaitInclusion connection (Map.keysSet created) expectedUTxO
    after <- maybe (fail "Timed out waiting for CLI transaction inclusion") pure included
    Funding.verifyStore expectedStore (Funding.totalAda before) after
    writeEvidence directory "cli-transaction-included.json" $
        object $
            [ "included" .= True
            , "wholeUTxOMatches" .= True
            , "inputConsumed" .= True
            , "depositStoreBefore" .= Funding.depositStore before
            , "depositStoreAfter" .= Funding.depositStore after
            , "totalAdaBefore" .= Funding.totalAda before
            , "totalAdaAfter" .= Funding.totalAda after
            ]
                <> submittedEvidence
    putStrLn "PASS: CLI transaction included; exact UTxO, deposit allocation and total ADA verified"

readTransaction :: FilePath -> IO (Api.Tx Api.DijkstraEra)
readTransaction path = Api.readFileTextEnvelope (Api.File path) >>= either (fail . show) pure

runCli :: FilePath -> FilePath -> String -> [String] -> IO ()
runCli cli directory step arguments = do
    let prefix = "cli-transaction-" <> step
    writeEvidence directory (prefix <> ".command.json") (toJSON (cli : arguments))
    putStrLn $ "$ " <> showCommandForUser cli arguments
    (result, output, errors) <- readProcessWithExitCode cli arguments ""
    writeFile (directory </> prefix <> ".stdout") output
    writeFile (directory </> prefix <> ".stderr") errors
    putStr output
    hPutStr stderr errors
    unless (result == ExitSuccess) $
        fail $
            "CLI " <> step <> " failed: " <> show result <> "; subsequent assertions did not run"

awaitInclusion :: Api.LocalNodeConnectInfo -> Set.Set Api.TxIn -> Map.Map Api.TxIn (Api.TxOut Api.CtxUTxO Api.DijkstraEra) -> IO Funding.LiveState
awaitInclusion connection created expected = do
    state <- Funding.queryLedgerState connection
    let Api.UTxO actual = Api.fromLedgerUTxO Api.ShelleyBasedEraDijkstra (Funding.ledgerUTxO state)
    if Map.null (Map.restrictKeys actual created)
        then threadDelay 1_000_000 >> awaitInclusion connection created expected
        else do
            unless (actual == expected) $ fail "CLI transaction UTxO differs from the token output, change and untouched inputs"
            pure state
