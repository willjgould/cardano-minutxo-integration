{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:target-version=1.2.0 #-}

module MinUTxO.Validator (validatorBytes) where

import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString)
import MinUTxO.Validator.OnChain (validator)
import qualified PlutusLedgerApi.V4 as PV4
import qualified PlutusTx

-- Fix the native asset before hashing the resulting spending validator.
validatorBytes :: ByteString -> ByteString -> ShortByteString
validatorBytes policyBytes assetNameBytes =
  PV4.serialiseCompiledCode $
    $$(PlutusTx.compile [||validator||])
      `PlutusTx.unsafeApplyCode` PlutusTx.liftCodeDef (PV4.toBuiltin policyBytes)
      `PlutusTx.unsafeApplyCode` PlutusTx.liftCodeDef (PV4.toBuiltin assetNameBytes)
