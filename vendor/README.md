# Plutus ledger API source

`plutus-ledger-api/` starts from the published CHaP source distribution of
`plutus-ledger-api-1.71.0.0`, matching the integration project's pinned
dependency plan. It is included locally so the work-in-progress Plutus V4
interface can be changed together with its ledger translation.

- Source: <https://chap.intersectmbo.org/package/plutus-ledger-api-1.71.0.0.tar.gz>
- SHA-256: `51a1fd2433d7a39a82cb8f7dda32bb10ecb890b9a76612d57566264e53285a16`
- License and notices: `plutus-ledger-api/LICENSE` and `plutus-ledger-api/NOTICE`.

The initial import contains all 117 files from that archive, unchanged. To
reproduce the import into an empty directory:

```sh
mkdir -p vendor/plutus-ledger-api
tar -xzf plutus-ledger-api-1.71.0.0.tar.gz \
  --strip-components=1 -C vendor/plutus-ledger-api
```

The package continues to use the published `plutus-core` and `plutus-tx`
dependencies selected by the integration project. No external local checkout
is required.

## Local work-in-progress V4 interface patch

The normal and data-backed V4 interfaces now expose the same output semantics:

- `txOutValue` is the total output value, including any separately recorded
  backing ADA. Existing value helpers therefore operate on total value.
- The fifth and final `TxOut` field is `txOutBacking :: MinUTxOBacking`, with
  constructors `Implicit` and `Explicit Lovelace`. `Implicit` identifies an
  output whose backing is included in its original value. `Explicit amount`
  reports the actual separate allocation, including zero; it is not a minimum
  recalculated using current protocol parameters.
- `valueWithoutExplicitBacking` leaves implicit outputs unchanged and subtracts
  only the reported explicit backing from total value. Native-token quantities
  are unchanged. The default `pubKeyHashTxOut` constructor uses `Implicit`.

This intentionally changes the work-in-progress V4 Plutus Data encoding of
`TxOut` from a four-element list to a five-element list. The appended backing
field encodes as `Constr 0 []` for `Implicit` or `Constr 1 [I amount]` for
`Explicit amount`, in both representations. In particular, explicit zero
remains distinguishable from implicit backing. V1, V2 and V3 output interfaces
and encodings are unchanged.

The patch updates the two V4 `Tx` modules, their public facade exports, and
existing V4 test fixtures for the added field. The ledger translation supplies
the total value and allocation metadata; the package does not query or infer
allocations itself.
