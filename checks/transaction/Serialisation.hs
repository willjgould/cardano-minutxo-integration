{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeFamilies #-}

module Main where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental.Tx as Exp

import Nested (Fixture (..))
import qualified Nested
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

-- Round-trip the same unsigned parents as the construction check through the
-- public API's CBOR byte interface. This does not sign or submit a transaction.
main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    fixture@Fixture{tokenInput, tokenOutput, deposit} <- Nested.exampleFixture
    tokenContribution <-
        either (die . show) pure $
            Nested.prepareTokenContribution tokenInput tokenOutput deposit

    checkParentFundsDeposit fixture tokenContribution
    checkSiblingFundsDeposit fixture tokenContribution

checkParentFundsDeposit :: Fixture -> Exp.UnsignedSubTx -> IO ()
checkParentFundsDeposit Fixture{parentInput, deposit, fee} tokenContribution = do
    transaction <-
        either (die . show) pure $
            Nested.composeTransaction parentInput deposit fee [tokenContribution]
    checkRoundTrip "ParentFunds" transaction

checkSiblingFundsDeposit :: Fixture -> Exp.UnsignedSubTx -> IO ()
checkSiblingFundsDeposit Fixture{parentInput, siblingInput, deposit, fee} tokenContribution = do
    adaContribution <- either (die . show) pure $ Nested.prepareAdaContribution siblingInput
    transaction <-
        either (die . show) pure $
            Nested.composeTransaction parentInput deposit fee [tokenContribution, adaContribution]
    checkRoundTrip "SiblingFunds" transaction

checkRoundTrip ::
    String ->
    Exp.UnsignedTx (Api.ShelleyLedgerEra Api.DijkstraEra) ->
    IO ()
checkRoundTrip label transaction = do
    putStrLn $ "RUN serialization assertions: nested transaction, " <> label
    let bytes = Api.serialiseToRawBytes transaction
    decoded <-
        either (die . (("FAIL: " <> label <> " CBOR decoding: ") <>) . show) pure $
            Api.deserialiseFromRawBytes Api.asType bytes
    Nested.assertEqual (label <> ": complete transaction round-trip") transaction decoded
    Nested.assertEqual (label <> ": serialized bytes remain stable") bytes (Api.serialiseToRawBytes decoded)
    putStrLn $ "PASS: CBOR round-trip preserves the complete nested transaction, " <> label
