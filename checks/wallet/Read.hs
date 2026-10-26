{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import qualified Cardano.Api as Api
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Read.Ledger.Eras as Read
import Cardano.Read.Ledger.Tx.Outputs (Outputs (..))
import qualified Cardano.Wallet.Primitive.Ledger.Read.Tx.Features.Outputs as Wallet
import qualified Cardano.Wallet.Primitive.Types.Address as W
import qualified Cardano.Wallet.Primitive.Types.AssetId as W
import qualified Cardano.Wallet.Primitive.Types.AssetName as W
import qualified Cardano.Wallet.Primitive.Types.Coin as W
import qualified Cardano.Wallet.Primitive.Types.Hash as W
import qualified Cardano.Wallet.Primitive.Types.TokenBundle as TokenBundle
import qualified Cardano.Wallet.Primitive.Types.TokenPolicyId as W
import qualified Cardano.Wallet.Primitive.Types.TokenQuantity as W
import qualified Cardano.Wallet.Primitive.Types.Tx.TxOut as W
import Control.Monad (unless)
import GHC.Exts (fromList)
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    putStrLn "RUN wallet assertions: read a store-backed output with seven tokens and zero ADA"
    paymentKeyHash <-
        either (die . show) pure $
            Api.deserialiseFromRawBytesHex
                "11111111111111111111111111111111111111111111111111111111"
    policyId <-
        either (die . show) pure $
            Api.deserialiseFromRawBytesHex
                "22222222222222222222222222222222222222222222222222222222"
    assetName <- either (die . show) pure $ Api.deserialiseFromRawBytes Api.AsAssetName "offer"
    let era = Api.ShelleyBasedEraDijkstra
        address =
            Api.makeShelleyAddressInEra
                era
                (Api.Testnet (Api.NetworkMagic 42))
                (Api.PaymentCredentialByKey paymentKeyHash)
                Api.NoStakeAddress
        assets = Api.valueFromList [(Api.AssetId policyId assetName, Api.Quantity 7)]
        output =
            Api.TxOut
                address
                (Api.TxOutValueStoreBacked (Core.ApplicationAssets (Api.toMaryValue assets)))
                Api.TxOutDatumNone
                Api.ReferenceScriptNone
        expectedAsset =
            W.AssetId
                (W.UnsafeTokenPolicyId (W.Hash (Api.serialiseToRawBytes policyId)))
                (W.UnsafeAssetName "offer")
        expected =
            W.StoreBackedTxOut
                (W.Address (Api.serialiseToRawBytes address))
                (TokenBundle.fromFlatList (W.Coin 0) [(expectedAsset, W.TokenQuantity 7)])
    -- Keep the genuine Dijkstra wrapper: unwrapping it into a Babbage output
    -- would bypass the missing wallet support this check is meant to expose.
    case Api.toShelleyTxOut era output of
        ledgerOutput@Core.StoreBackedTxOut{} ->
            case Wallet.getOutputs @Read.Dijkstra (Outputs (fromList [ledgerOutput])) of
                [actual] ->
                    unless (actual == expected) $
                        die $
                            "FAIL: expected wallet output " <> show expected <> ", got " <> show actual
                outputs ->
                    die $ "FAIL: expected exactly one wallet output, got " <> show (length outputs)
        Core.ImplicitDepositTxOut{} ->
            die "FAIL: fixture must contain a store-backed ledger output"
    putStrLn "PASS: wallet reading preserves the address, seven tokens and zero ADA"
