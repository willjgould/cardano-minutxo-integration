module MinUTxO.Validator.OnChain (validator) where

import qualified PlutusLedgerApi.V4 as PV4
import qualified PlutusLedgerApi.V4.Contexts as Contexts
import qualified PlutusTx.Builtins as Builtins
import qualified PlutusTx.Prelude as P

-- The same rule preserves an ordinary input's ADA and a token-only input's
-- zero ADA, without inspecting or calculating its UTxO backing.
{-# INLINEABLE validator #-}
validator :: P.BuiltinByteString -> P.BuiltinByteString -> P.BuiltinData -> P.BuiltinUnit
validator policyBytes assetNameBytes rawContext =
  P.check $
    case Contexts.findOwnInput context of
      Nothing -> False
      Just ownInput ->
        case (PV4.scriptContextScriptInfo context, Contexts.getContinuingOutputs context) of
          (PV4.SpendingScript _ (Just (PV4.Datum oldDatum)), [continuing]) ->
            let ownValue = PV4.txOutValue $ PV4.txInInfoResolved ownInput
             in PV4.valueOf ownValue (PV4.CurrencySymbol policyBytes) (PV4.TokenName assetNameBytes)
                  P.== 7
                  P.&& (PV4.txOutValue continuing P.== ownValue)
                  P.&& case PV4.txOutDatum continuing of
                    PV4.OutputDatum (PV4.Datum newDatum) ->
                      Builtins.unsafeDataAsI newDatum P.== (Builtins.unsafeDataAsI oldDatum P.+ 1)
                    _ -> False
          _ -> False
 where
  context = P.unsafeFromBuiltinData rawContext
