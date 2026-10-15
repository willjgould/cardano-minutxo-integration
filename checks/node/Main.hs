{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Cardano.Api as Api
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Type as Network

import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Genesis
import qualified Submission
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["prepare", directory] -> Genesis.prepare directory
        ["probe", socket] -> probe socket
        ["transfer", directory, socket] -> Submission.transfer directory socket
        _ -> die "Usage: check-node prepare DIRECTORY | probe SOCKET | transfer DIRECTORY SOCKET"

probe :: FilePath -> IO ()
probe socket = do
    let connection =
            Api.LocalNodeConnectInfo
                { Api.localConsensusModeParams = Api.CardanoModeParams (Api.EpochSlots 50)
                , Api.localNodeNetworkId = Api.Testnet (Api.NetworkMagic 42)
                , Api.localNodeSocketPath = Api.File socket
                }
    era <-
        runExceptT (Api.queryNodeLocalState connection Network.VolatileTip Api.QueryCurrentEra)
            >>= either (die . show) pure
    tip <- Api.getLocalChainTip connection
    let isDijkstra = case era of
            Api.AnyCardanoEra Api.DijkstraEra -> True
            _ -> False
        (slot, block) = case tip of
            Api.ChainTipAtGenesis -> (0, 0)
            Api.ChainTip (Api.SlotNo s) _ (Api.BlockNo b) -> (s, b)
    LBS.putStrLn $
        encode $
            object
                [ "era" .= show era
                , "isDijkstra" .= isDijkstra
                , "slot" .= slot
                , "block" .= block
                ]
