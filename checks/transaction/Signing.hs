{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeFamilies #-}

module Main where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental as Era
import qualified Cardano.Api.Experimental.Tx as Exp

import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Dijkstra.Core as Dijkstra
import qualified Cardano.Ledger.Dijkstra.UTxODeposit.TopTx as TopTx
import qualified Cardano.Ledger.Hashes as Hashes
import qualified Cardano.Ledger.Keys as Keys
import Cardano.Ledger.State (verifyWitVKey)

import Data.Foldable (toList)
import Data.Function ((&))
import qualified Data.Set as Set
import Lens.Micro ((^.))
import Nested (Fixture (..))
import qualified Nested
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

-- In-memory test keys sign the same synthetic transactions as Nested. This
-- verifies signatures and witness placement, not ownership of live inputs or
-- ledger acceptance. Child signing helpers exist in later upstream API history
-- but are absent from our older baseline; no low-level signing fallback is used.
main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    fixture@Fixture{tokenInput, tokenOutput, deposit} <- Nested.exampleFixture
    tokenKey <- Api.generateSigningKey Api.AsPaymentKey
    parentKey <- Api.generateSigningKey Api.AsPaymentKey
    tokenContribution <-
        either (die . show) pure $
            Nested.prepareTokenContribution tokenInput tokenOutput deposit
    putStrLn "RUN signing assertions: reusable token child"
    signedToken <- signContribution "token child" tokenKey tokenContribution
    checkParentFundsDeposit fixture parentKey signedToken
    checkSiblingFundsDeposit fixture parentKey signedToken

-- One signed child supplies tokens; the signed parent funds deposit + fee.
checkParentFundsDeposit :: Fixture -> Api.SigningKey Api.PaymentKey -> Exp.SignedSubTx -> IO ()
checkParentFundsDeposit fixture parentKey tokenContribution = do
    putStrLn "RUN signing assertions: nested transaction, ParentFunds"
    checkSignedParent "ParentFunds" fixture parentKey [tokenContribution]

-- Two separately signed children supply tokens and deposit ADA; the signed
-- parent supplies the fee and still records the deposit operation once.
checkSiblingFundsDeposit :: Fixture -> Api.SigningKey Api.PaymentKey -> Exp.SignedSubTx -> IO ()
checkSiblingFundsDeposit fixture@Fixture{siblingInput} parentKey tokenContribution = do
    putStrLn "RUN signing assertions: nested transaction, SiblingFunds"
    siblingKey <- Api.generateSigningKey Api.AsPaymentKey
    adaContribution <- either (die . show) pure $ Nested.prepareAdaContribution siblingInput
    signedAda <- signContribution "ADA sibling" siblingKey adaContribution
    checkSignedParent "SiblingFunds" fixture parentKey [tokenContribution, signedAda]

signContribution ::
    String -> Api.SigningKey Api.PaymentKey -> Exp.UnsignedSubTx -> IO Exp.SignedSubTx
signContribution label key unsigned@(Exp.UnsignedSubTx original) = do
    let witness = Exp.makeSubTxKeyWitness unsigned (Api.WitnessPaymentKey key)
        signed@(Exp.SignedSubTx transaction) = Exp.signSubTx [] [witness] unsigned
    Nested.assertEqual
        (label <> ": signing preserves body and deposit operation")
        (original ^. Core.bodyTxL)
        (transaction ^. Core.bodyTxL)
    checkWitness label key transaction
    pure signed

checkSignedParent ::
    String -> Fixture -> Api.SigningKey Api.PaymentKey -> [Exp.SignedSubTx] -> IO ()
checkSignedParent label Fixture{parentInput, deposit, fee} key contributions = do
    -- Embed already signed children before hashing/signing the parent body.
    unsigned@(Exp.UnsignedTx original) <-
        either (die . show) pure $
            Exp.makeUnsignedTx Era.DijkstraEra $
                Exp.defaultTxBodyContent
                    { Exp.txNetUTxODepositChange = TopTx.DeclaresNetUTxODepositAllocation deposit
                    }
                    & Exp.setTxIns [Nested.keyInput parentInput]
                    & Exp.setTxFee fee
                    & Exp.setTxSignedSubTransactions contributions
    let witness = Exp.makeKeyWitness Era.DijkstraEra unsigned (Api.WitnessPaymentKey key)
        signed@(Exp.SignedTx transaction) = Exp.signTx Era.DijkstraEra [] [witness] unsigned
        body = transaction ^. Core.bodyTxL
    Nested.assertEqual (label <> ": signing preserves parent body") (original ^. Core.bodyTxL) body
    Nested.assertEqual
        (label <> ": signed children and their order")
        [child | Exp.SignedSubTx child <- contributions]
        (toList (body ^. Dijkstra.subTransactionsTxBodyL))
    Nested.assertEqual
        (label <> ": parent deposit operation")
        (TopTx.DeclaresNetUTxODepositAllocation deposit)
        (body ^. Dijkstra.netUTxODepositChangeTxBodyL)
    checkWitness (label <> " parent") key transaction
    let bytes = Api.serialiseToRawBytes signed
    decoded <- either (die . show) pure $ Api.deserialiseFromRawBytes Api.asType bytes
    Nested.assertEqual (label <> ": signed transaction CBOR round-trip") signed decoded
    Nested.assertEqual (label <> ": signed CBOR bytes remain stable") bytes (Api.serialiseToRawBytes decoded)
    putStrLn $ "PASS: nested key signatures and signed CBOR round-trip, " <> label

checkWitness ::
    String ->
    Api.SigningKey Api.PaymentKey ->
    Core.Tx level (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    IO ()
checkWitness label key transaction = do
    let witnesses = transaction ^. Core.witsTxL . Core.addrTxWitsL
        Api.PaymentKeyHash expectedKey = Api.verificationKeyHash (Api.getVerificationKey key)
        bodyHash = Hashes.extractHash (Hashes.hashAnnotated (transaction ^. Core.bodyTxL))
    Nested.assertEqual (label <> ": exactly one key witness") 1 (Set.size witnesses)
    Nested.assertEqual
        (label <> ": expected signing key")
        (Set.singleton (Keys.asWitness expectedKey))
        (Set.map Keys.witVKeyHash witnesses)
    Nested.assertEqual
        (label <> ": signature verifies against its own transaction body")
        True
        (all (verifyWitVKey bodyHash) witnesses)
