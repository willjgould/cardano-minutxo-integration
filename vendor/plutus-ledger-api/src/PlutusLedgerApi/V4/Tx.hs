{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# OPTIONS_GHC -fno-specialise #-}

module PlutusLedgerApi.V4.Tx
  ( -- * Transactions
    TxId (..)

    -- * Transaction outputs
  , TxOutRef (TxOutRef, txOutRefId, txOutRefIdx)
  , OutputDatum (..)
  , MinUTxOBacking (..)
  , TxOut (..)
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
import PlutusLedgerApi.V1.Scripts (ScriptHash)
import PlutusLedgerApi.V1.Value (Lovelace, Value, lovelaceValue)
import PlutusLedgerApi.V2.Tx (OutputDatum (..))
import PlutusLedgerApi.V3.Tx (TxId (..))
import PlutusLedgerApi.V3.Tx qualified as V3
import PlutusLedgerApi.V4.Address
  ( Address
  , pubKeyHashAddress
  , toPubKeyHash
  , toScriptHash
  )
import PlutusLedgerApi.V4.Internal (ListEncoded (..))
import PlutusTx qualified
import PlutusTx.Blueprint (definitionRef)
import PlutusTx.Blueprint.Class (HasBlueprintSchema (..))
import PlutusTx.Blueprint.Definition (HasBlueprintDefinition (..), UnrollAll)
import PlutusTx.Prelude qualified as PlutusTx
import Prettyprinter (Pretty (pretty), hang, vsep, (<+>))

newtype TxOutRef = TxOutRefValue V3.TxOutRef
  deriving stock (Generic)
  deriving newtype (Show, Eq, Ord, NFData, Pretty, PlutusTx.Eq)
  deriving
    (PlutusTx.ToData, PlutusTx.FromData, PlutusTx.UnsafeFromData)
    via ListEncoded V3.TxOutRef

pattern TxOutRef :: TxId -> Integer -> TxOutRef
pattern TxOutRef {txOutRefId, txOutRefIdx} =
  TxOutRefValue (V3.TxOutRef txOutRefId txOutRefIdx)
{-# COMPLETE TxOutRef #-}

instance HasBlueprintDefinition TxOutRef where
  type Unroll TxOutRef = TxOutRef ': UnrollAll '[TxId, Integer]

instance HasBlueprintSchema V3.TxOutRef referencedTypes => HasBlueprintSchema TxOutRef referencedTypes where
  schema = schema @(ListEncoded V3.TxOutRef) @referencedTypes

PlutusTx.makeLift ''TxOutRef

-- | How an output satisfies its minimum ADA requirement. 'Implicit' means
-- that the requirement is met by ADA inside the output. 'Explicit' records
-- the separate backing allocation, which is included in 'txOutValue'.
-- This amount is the actual allocation, not a minimum recalculated using
-- current protocol parameters. An explicit zero allocation is distinct
-- from an implicit output.
data MinUTxOBacking
  = Implicit
  | Explicit Lovelace
  deriving stock (Show, Eq, Generic)
  deriving anyclass (HasBlueprintDefinition)

PlutusTx.deriveEq ''MinUTxOBacking
PlutusTx.makeIsDataSchemaIndexed ''MinUTxOBacking [('Implicit, 0), ('Explicit, 1)]
PlutusTx.makeLift ''MinUTxOBacking

instance Pretty MinUTxOBacking where
  pretty Implicit = "implicit"
  pretty (Explicit amount) = "explicit" <+> pretty amount

-- | Transaction output for Plutus V4.
data TxOut = TxOut
  { txOutAddress :: Address
  , txOutValue :: Value
  -- ^ Total value associated with the output, including any explicit backing.
  , txOutDatum :: OutputDatum
  , txOutReferenceScript :: Maybe ScriptHash
  , txOutBacking :: MinUTxOBacking
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (HasBlueprintDefinition)

PlutusTx.deriveEq ''TxOut

instance Pretty TxOut where
  pretty TxOut {txOutAddress, txOutValue, txOutDatum, txOutReferenceScript, txOutBacking} =
    hang 2 $
      vsep
        [ "-"
            <+> pretty txOutValue
            <+> "addressed to"
        , pretty txOutAddress
        , "with datum"
        , pretty txOutDatum
        , "with referenceScript"
        , pretty txOutReferenceScript
        , "with minUTxO backing"
        , pretty txOutBacking
        ]

-- | Value excluding only separately allocated backing. An implicit output's
-- entire value is preserved: its application/infrastructure split is not
-- recorded by the ledger and must not be inferred by subtracting a minimum.
valueWithoutExplicitBacking :: TxOut -> Value
valueWithoutExplicitBacking out = case txOutBacking out of
  Implicit -> txOutValue out
  Explicit amount -> txOutValue out PlutusTx.- lovelaceValue amount
{-# INLINEABLE valueWithoutExplicitBacking #-}

-- | The public key attached to a 'TxOut', if there is one.
txOutPubKey :: TxOut -> Maybe PubKeyHash
txOutPubKey TxOut {txOutAddress} = toPubKeyHash txOutAddress

-- | The validator hash attached to a 'TxOut', if there is one.
txOutScriptHash :: TxOut -> Maybe ScriptHash
txOutScriptHash TxOut {txOutAddress} = toScriptHash txOutAddress

-- | Whether the output is a pay-to-pubkey output.
isPubKeyOut :: TxOut -> Bool
isPubKeyOut = isJust . txOutPubKey

-- | Whether the output is a pay-to-script output.
isPayToScriptOut :: TxOut -> Bool
isPayToScriptOut = isJust . txOutScriptHash

-- | Create a transaction output locked by a public key.
pubKeyHashTxOut :: Value -> PubKeyHash -> TxOut
pubKeyHashTxOut v pkh = TxOut (pubKeyHashAddress pkh) v NoOutputDatum Nothing Implicit

----------------------------------------------------------------------------------------------------
-- TH Splices --------------------------------------------------------------------------------------

$(PlutusTx.makeIsDataSchemaAsList ''TxOut)
$(PlutusTx.makeLift ''TxOut)
