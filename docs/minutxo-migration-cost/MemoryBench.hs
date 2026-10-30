{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
module Main where

import Control.DeepSeq (NFData, force)
import Control.Exception (evaluate)
import Data.Bits (xor)
import qualified Data.Map.Strict as M
import qualified Data.Vector.Unboxed as U
import Data.Word (Word16, Word64)
import Foreign.StablePtr (newStablePtr, freeStablePtr)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import GHC.Stats
import System.Environment (getArgs)
import System.Mem (performMajorGC)
import Text.Printf (printf)

-- Matches the shape of cardano-crypto-class PackedBytes32: one constructor
-- and four unpacked Word64s. SafeHash and TxId are newtypes around this.
data Hash32 = Hash32 {-# UNPACK #-} !Word64 {-# UNPACK #-} !Word64
                     {-# UNPACK #-} !Word64 {-# UNPACK #-} !Word64
  deriving (Eq, Ord, Generic)
instance NFData Hash32

-- Mirrors ledger TxIn: a strict TxId and unpacked Word16 TxIx.
data TxInLike = TxInLike !Hash32 {-# UNPACK #-} !Word16
  deriving (Eq, Ord, Generic)
instance NFData TxInLike

data Base = Base {-# UNPACK #-} !Word64 deriving (Generic)
instance NFData Base
data WithAmount = WithAmount {-# UNPACK #-} !Word64 {-# UNPACK #-} !Word64
  deriving (Generic)
instance NFData WithAmount
-- Keep the original output object intact. The NOUNPACK avoids GHC flattening
-- our deliberately tiny Base type; a real TxOut is a substantially larger sum.
data Wrapped = Wrapped {-# NOUNPACK #-} !Base {-# UNPACK #-} !Word64
  deriving (Generic)
instance NFData Wrapped

key :: Int -> TxInLike
key i = TxInLike (Hash32 (fromIntegral i) 0 0 0) 0
{-# NOINLINE key #-}

amount :: Int -> Word64
amount i = 1000000 + fromIntegral (i `mod` 5000000)
{-# NOINLINE amount #-}

mapUnit :: Int -> M.Map TxInLike ()
mapUnit n = M.fromDistinctAscList [(key i, ()) | i <- [0 .. n-1]]
{-# NOINLINE mapUnit #-}

snapshot :: IO RTSStats
snapshot = performMajorGC >> getRTSStats

-- Stable pointers keep the full object graph live across the measurement.
measure :: NFData a => String -> Int -> a -> (a -> Integer) -> IO ()
measure mode n x checksum = do
  before <- snapshot
  start <- getMonotonicTimeNSec
  !obj <- evaluate (force x)
  !sumValue <- evaluate (checksum obj)
  end <- getMonotonicTimeNSec
  live <- newStablePtr obj
  after <- snapshot
  let retained = fromIntegral (gcdetails_live_bytes (gc after)) -
                 fromIntegral (gcdetails_live_bytes (gc before)) :: Integer
  printf "{\"mode\":\"%s\",\"n\":%d,\"build_seconds\":%.9f,\"retained_delta_bytes\":%d,\"bytes_per_entry\":%.6f,\"checksum\":%d}\n"
    mode n ((fromIntegral (end-start) / 1e9) :: Double) retained
    ((fromIntegral retained / fromIntegral (max 1 n)) :: Double) sumValue
  freeStablePtr live

measureShared :: Int -> IO ()
measureShared n = do
  !base <- evaluate (force (mapUnit n))
  baseLive <- newStablePtr base
  before <- snapshot
  start <- getMonotonicTimeNSec
  let new = M.mapWithKey (\(TxInLike (Hash32 i _ _ _) _) _ ->
                toInteger (amount (fromIntegral i))) base
  !obj <- evaluate (force new)
  !sumValue <- evaluate (M.foldl' (+) 0 obj)
  end <- getMonotonicTimeNSec
  newLive <- newStablePtr obj
  after <- snapshot
  let retained = fromIntegral (gcdetails_live_bytes (gc after)) -
                 fromIntegral (gcdetails_live_bytes (gc before)) :: Integer
  printf "{\"mode\":\"map-shared-keys-integer\",\"n\":%d,\"build_seconds\":%.9f,\"retained_delta_bytes\":%d,\"bytes_per_entry\":%.6f,\"checksum\":%d}\n"
    n ((fromIntegral (end-start) / 1e9) :: Double) retained
    ((fromIntegral retained / fromIntegral (max 1 n)) :: Double) sumValue
  freeStablePtr newLive
  freeStablePtr baseLive

main :: IO ()
main = do
  args <- getArgs
  case args of
    [mode, count] -> do
      let n = read count
      case mode of
        "map-unit" -> measure mode n (mapUnit n) (toInteger . M.size)
        "map-integer" -> measure mode n
          (M.fromDistinctAscList [(key i, toInteger (amount i)) | i <- [0 .. n-1]])
          (M.foldl' (+) 0)
        "map-word64" -> measure mode n
          (M.fromDistinctAscList [(key i, amount i) | i <- [0 .. n-1]])
          (M.foldl' (\acc v -> acc + toInteger v) 0)
        "map-base-value" -> measure mode n
          (M.fromDistinctAscList [(key i, Base (fromIntegral i)) | i <- [0 .. n-1]])
          (M.foldl' (\acc (Base v) -> acc + toInteger v) 0)
        "map-inline-word64" -> measure mode n
          (M.fromDistinctAscList [(key i, WithAmount (fromIntegral i) (amount i)) | i <- [0 .. n-1]])
          (M.foldl' (\acc (WithAmount v a) -> acc + toInteger (xor v a)) 0)
        "map-wrapper-word64" -> measure mode n
          (M.fromDistinctAscList [(key i, Wrapped (Base (fromIntegral i)) (amount i)) | i <- [0 .. n-1]])
          (M.foldl' (\acc (Wrapped (Base v) a) -> acc + toInteger (xor v a)) 0)
        "map-shared-keys-integer" -> measureShared n
        "vector-word64" -> measure mode n (U.generate n amount)
          (U.foldl' (\acc v -> acc + toInteger v) 0)
        _ -> error "Unknown mode"
    _ -> error "Usage: memory-bench MODE COUNT +RTS -T -s -N1 -RTS"
