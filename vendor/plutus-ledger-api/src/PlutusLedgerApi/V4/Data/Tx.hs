{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}
-- needed for asData pattern synonyms
{-# OPTIONS_GHC -fexpose-all-unfoldings #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# OPTIONS_GHC -fno-specialise #-}

module PlutusLedgerApi.V4.Data.Tx
  ( -- * Transactions
    TxId (..)

    -- * Transaction outputs
  , TxOutRef
  , pattern TxOutRef
  , matchTxOutRef
  , txOutRefId
  , txOutRefIdx
  , OutputDatum
  , matchOutputDatum
  , pattern NoOutputDatum
  , pattern OutputDatumHash
  , pattern OutputDatum
  , MinUTxOBacking
  , pattern Implicit
  , pattern Explicit
  , matchMinUTxOBacking
  , TxOut
  , pattern TxOut
  , matchTxOut
  , txOutAddress
  , txOutValue
  , txOutDatum
  , txOutReferenceScript
  , txOutBacking
  , backingAmount
  , applicationValue
  , valueWithoutExplicitBacking
  , txOutPubKey
  , txOutScriptHash
  , isPubKeyOut
  , isPayToScriptOut
  , pubKeyHashTxOut
  ) where

import Control.DeepSeq (NFData)
import Data.Maybe (isJust)
import GHC.Generics (Generic)
import PlutusLedgerApi.V1.Crypto (PubKeyHash)
import PlutusLedgerApi.V1.Data.Value (Lovelace, Value, lovelaceValue)
import PlutusLedgerApi.V1.Scripts (ScriptHash)
import PlutusLedgerApi.V2.Data.Tx
  ( OutputDatum
  , matchOutputDatum
  , pattern NoOutputDatum
  , pattern OutputDatum
  , pattern OutputDatumHash
  )
import PlutusLedgerApi.V3.Data.Tx (TxId (..))
import PlutusLedgerApi.V4.Data.Address
  ( Address
  , pubKeyHashAddress
  , toPubKeyHash
  , toScriptHash
  )
import PlutusTx qualified
import PlutusTx.AsData qualified as PlutusTx
import PlutusTx.Prelude qualified as PlutusTx
import Prettyprinter (Pretty (pretty), hang, vsep, (<+>))

PlutusTx.asDataAsList
  [d|
    data TxOutRef = TxOutRef
      { txOutRefId :: TxId
      , txOutRefIdx :: Integer
      }
      deriving stock (Show, Eq, Ord, Generic)
      deriving newtype (PlutusTx.FromData, PlutusTx.UnsafeFromData, PlutusTx.ToData)
      deriving anyclass (NFData)
    |]

PlutusTx.deriveEq ''TxOutRef
PlutusTx.makeLift ''TxOutRef

instance Pretty TxOutRef where
  pretty TxOutRef {txOutRefId, txOutRefIdx} = pretty txOutRefId <> "!" <> pretty txOutRefIdx

-- | The data-backed counterpart of 'PlutusLedgerApi.V4.Tx.MinUTxOBacking'.
-- Both constructors carry a known amount: the historical minimum already
-- inside an implicit output, or the separately held explicit allocation.
PlutusTx.asData
  [d|
    data MinUTxOBacking
      = Implicit Lovelace
      | Explicit Lovelace
      deriving stock (Show, Eq, Generic)
      deriving newtype (PlutusTx.FromData, PlutusTx.UnsafeFromData, PlutusTx.ToData)
    |]

PlutusTx.deriveEq ''MinUTxOBacking
PlutusTx.makeLift ''MinUTxOBacking

instance Pretty MinUTxOBacking where
  pretty (Implicit amount) = "implicit" <+> pretty amount
  pretty (Explicit amount) = "explicit" <+> pretty amount

-- | Transaction output for Plutus V4.
PlutusTx.asDataAsList
  [d|
    data TxOut = TxOut
      { txOutAddress :: Address
      , txOutValue :: Value
      -- ^ Total value associated with the output, including explicit backing.
      , txOutDatum :: OutputDatum
      , txOutReferenceScript :: Maybe ScriptHash
      , txOutBacking :: MinUTxOBacking
      }
      deriving stock (Show, Eq, Generic)
      deriving newtype (PlutusTx.FromData, PlutusTx.UnsafeFromData, PlutusTx.ToData)
    |]

PlutusTx.deriveEq ''TxOut

instance Pretty TxOut where
  pretty TxOut {txOutAddress, txOutValue, txOutDatum, txOutReferenceScript, txOutBacking} =
    hang 2 $
      vsep
        [ "-" <+> pretty txOutValue <+> "addressed to"
        , pretty txOutAddress
        , "with datum"
        , pretty txOutDatum
        , "with referenceScript"
        , pretty txOutReferenceScript
        , "with minUTxO backing"
        , pretty txOutBacking
        ]

-- | Recorded minimum or separate allocation. An implicit amount is already in
-- the output value and does not represent additional deposit-store money.
backingAmount :: TxOut -> Lovelace
backingAmount out = case txOutBacking out of
  Implicit amount -> amount
  Explicit amount -> amount
{-# INLINEABLE backingAmount #-}

-- | Exclude the recorded minimum or separate allocation from total value,
-- preserving every non-ADA asset.
applicationValue :: TxOut -> Value
applicationValue out = txOutValue out PlutusTx.- lovelaceValue (backingAmount out)
{-# INLINEABLE applicationValue #-}

-- | Exclude only separately allocated backing, preserving the full value of
-- implicit outputs, including their recorded minimum, and every non-ADA asset.
valueWithoutExplicitBacking :: TxOut -> Value
valueWithoutExplicitBacking out = case txOutBacking out of
  Implicit _ -> txOutValue out
  Explicit amount -> txOutValue out PlutusTx.- lovelaceValue amount
{-# INLINEABLE valueWithoutExplicitBacking #-}

-- | The public key attached to a 'TxOut', if there is one.
txOutPubKey :: TxOut -> Maybe PubKeyHash
txOutPubKey = toPubKeyHash . txOutAddress

-- | The validator hash attached to a 'TxOut', if there is one.
txOutScriptHash :: TxOut -> Maybe ScriptHash
txOutScriptHash = toScriptHash . txOutAddress

-- | Whether the output is a pay-to-pubkey output.
isPubKeyOut :: TxOut -> Bool
isPubKeyOut = isJust . txOutPubKey

-- | Whether the output is a pay-to-script output.
isPayToScriptOut :: TxOut -> Bool
isPayToScriptOut = isJust . txOutScriptHash

-- | Create an implicitly backed output locked by a public key, supplying its
-- total value and known minimum at creation.
pubKeyHashTxOut :: Value -> Lovelace -> PubKeyHash -> TxOut
pubKeyHashTxOut v minimumAtCreation pkh =
  TxOut (pubKeyHashAddress pkh) v NoOutputDatum Nothing (Implicit minimumAtCreation)

----------------------------------------------------------------------------------------------------
-- TH Splices --------------------------------------------------------------------------------------

$(PlutusTx.makeLift ''TxOut)
