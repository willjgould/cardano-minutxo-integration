{-# LANGUAGE OverloadedStrings #-}

module MinUTxO.Validator.OnChain (validator) where

import qualified PlutusLedgerApi.V4 as PV4
import qualified PlutusLedgerApi.V4.Contexts as Contexts
import qualified PlutusTx.Builtins as Builtins
import qualified PlutusTx.Prelude as P

-- Preserve the assets carried by this state output. Explicit backing can
-- change with the continuing datum's size; the helper excludes only that
-- backing and preserves the entire ADA value of ordinary outputs. The redeemer
-- independently states the total ADA and backing expected on both sides.
{-# INLINEABLE validator #-}
validator :: P.BuiltinByteString -> P.BuiltinByteString -> P.BuiltinData -> P.BuiltinUnit
validator policyBytes assetNameBytes rawContext =
  P.check $
    case Contexts.findOwnInput context of
      Nothing -> False
      Just ownInput ->
        case (PV4.scriptContextScriptInfo context, Contexts.getContinuingOutputs context) of
          (PV4.SpendingScript _ (Just (PV4.Datum oldDatum)), [continuing]) ->
            let ownOutput = PV4.txInInfoResolved ownInput
                ownValue = PV4.valueWithoutExplicitBacking ownOutput
             in P.traceIfFalse "input-total"
                  (PV4.valueOf (PV4.txOutValue ownOutput) PV4.adaSymbol PV4.adaToken P.== expectedInputTotal)
                  P.&& P.traceIfFalse "input-backing" (PV4.txOutBacking ownOutput P.== expectedInputBacking)
                  P.&& P.traceIfFalse "output-total"
                    (PV4.valueOf (PV4.txOutValue continuing) PV4.adaSymbol PV4.adaToken P.== expectedOutputTotal)
                  P.&& P.traceIfFalse "output-backing" (PV4.txOutBacking continuing P.== expectedOutputBacking)
                  P.&& PV4.valueOf ownValue (PV4.CurrencySymbol policyBytes) (PV4.TokenName assetNameBytes)
                  P.== 7
                  P.&& (PV4.valueWithoutExplicitBacking continuing P.== ownValue)
                  P.&& case PV4.txOutDatum continuing of
                    PV4.OutputDatum (PV4.Datum newDatum) ->
                      Builtins.unsafeDataAsI newDatum P.== (Builtins.unsafeDataAsI oldDatum P.+ 1)
                    _ -> False
          _ -> False
 where
  context = P.unsafeFromBuiltinData rawContext
  PV4.Redeemer expectedData = PV4.scriptContextRedeemer context
  (expectedInputTotal, expectedInputBacking, expectedOutputTotal, expectedOutputBacking) =
    P.unsafeFromBuiltinData expectedData :: (Integer, PV4.MinUTxOBacking, Integer, PV4.MinUTxOBacking)
