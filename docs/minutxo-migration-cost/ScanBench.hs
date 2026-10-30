{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
module Main where

import Codec.CBOR.Decoding
import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Term (decodeTerm)
import Control.Exception (evaluate)
import Control.Monad (replicateM_, unless, void, forM_)
import Crypto.Hash (Digest, Blake2b_256, hash)
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Bits (xor)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (getArgs)
import System.Mem (performGC)
import Text.Printf (printf)

-- Structural traversal only. Does not construct ledger values or validate rules.
skip :: Decoder s ()
skip = peekTokenType >>= \case
  TypeUInt -> void decodeWord
  TypeUInt64 -> void decodeWord64
  TypeNInt -> void decodeInt
  TypeNInt64 -> void decodeInt64
  TypeBytes -> void decodeBytes
  TypeBytesIndef -> decodeBytesIndef >> loop skip
  TypeString -> void decodeString
  TypeStringIndef -> decodeStringIndef >> loop skip
  TypeListLen -> decodeListLen >>= (`replicateM_` skip)
  TypeListLen64 -> decodeListLen >>= (`replicateM_` skip)
  TypeListLenIndef -> decodeListLenIndef >> loop skip
  TypeMapLen -> decodeMapLen >>= (\n -> replicateM_ n (skip >> skip))
  TypeMapLen64 -> decodeMapLen >>= (\n -> replicateM_ n (skip >> skip))
  TypeMapLenIndef -> decodeMapLenIndef >> loop (skip >> skip)
  TypeTag -> decodeTag >> skip
  TypeTag64 -> decodeTag64 >> skip
  TypeBool -> void decodeBool
  TypeNull -> decodeNull
  TypeSimple -> void decodeSimple
  TypeBreak -> fail "unexpected break"
  TypeInvalid -> fail "invalid CBOR"
  _ -> void decodeTerm
  where
    loop action = decodeBreakOr >>= \done -> unless done (action >> loop action)

bodySpans :: Decoder s [(Int,Int)]
bodySpans = do
  n <- decodeListLenOrIndef
  case n of
    Just k -> sequence (replicate k one)
    Nothing -> go
  where
    one = do
      (_,start,end) <- decodeWithByteSpan skip
      pure (fromIntegral start,fromIntegral (end-start))
    go = decodeBreakOr >>= \done -> if done then pure [] else (:) <$> one <*> go

block :: Decoder s [(Int,Int)]
block = do
  outer <- decodeListLen
  unless (outer == 2) (fail "expected hard-fork pair")
  era <- decodeWord
  unless (era == 7) (fail "benchmark only supports Conway block tag 7")
  n <- decodeListLen
  unless (n == 5) (fail "expected five Conway block components")
  skip -- header
  spans <- bodySpans
  replicateM_ 3 skip -- witnesses, auxiliary-data map, invalid-transaction indices
  pure spans

scan :: Bool -> BS.ByteString -> (Int,Int,Int,Word64)
scan doHash bytes = go 0 (BL.fromStrict bytes) 0 0 0 0
  where
    go !offset !rest !blocks !txs !bodyBytes !checksum
      | BL.null rest = if offset == BS.length bytes
          then (blocks,txs,bodyBytes,checksum)
          else error "final byte count does not equal complete chunk length"
      | otherwise = case deserialiseFromBytes block rest of
          Left err -> error ("decode error at chunk offset " ++ show offset ++ ": " ++ show err)
          Right (remaining, spans) ->
            let !consumed = fromIntegral (BL.length rest - BL.length remaining)
                (!count,!size,!summed) = foldl consume (0,0,0) spans
                consume (!c,!s,!a) (start,len) =
                  let body = BS.take len (BS.drop (offset+start) bytes)
                      digest = BA.convert (hash body :: Digest Blake2b_256) :: BS.ByteString
                      !check = if doHash then BS.foldl' (\z b -> z * 131 + fromIntegral b) 0 digest else fromIntegral len
                  in (c+1,s+len,a `xor` check)
            in if consumed <= 0 then error "no decoder progress"
               else go (offset+consumed) remaining (blocks+1) (txs+count) (bodyBytes+size) (checksum `xor` summed)
{-# NOINLINE scan #-}

main :: IO ()
main = do
  [path,repsArg] <- getArgs
  let reps = read repsArg :: Int
  start <- getMonotonicTimeNSec
  bytes <- BS.readFile path
  evaluate (BS.length bytes)
  end <- getMonotonicTimeNSec
  printf "{\"kind\":\"read\",\"bytes\":%d,\"seconds\":%.9f,\"cold_io_guaranteed\":false}\n"
    (BS.length bytes) (fromIntegral (end-start) / 1e9 :: Double)
  forM_ [("structural",False),("structural_plus_hash",True)] $ \(label,doHash) -> do
    forM_ [1..reps] $ \iteration -> do
      performGC
      before <- getMonotonicTimeNSec
      -- IO-created wrapper keeps each iteration as a distinct application.
      bs <- evaluate (BS.drop (iteration - iteration) bytes)
      (!blocks,!txs,!bodyBytes,!checksum) <- evaluate (scan doHash bs)
      after <- getMonotonicTimeNSec
      let elapsed = fromIntegral (after-before) / 1e9 :: Double
      printf "{\"kind\":\"%s\",\"iteration\":%d,\"blocks\":%d,\"transactions\":%d,\"body_bytes\":%d,\"checksum\":%d,\"seconds\":%.9f,\"MB_per_second\":%.3f}\n"
        label iteration blocks txs bodyBytes checksum elapsed (fromIntegral (BS.length bytes)/1e6/elapsed)
