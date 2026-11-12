# Full historical backtest of the two minUTxO candidates

Analysis completed 6 November 2026. **Neither formula always overestimates the
previous byte-based requirement across the downloaded history.** The new
formula is substantially tighter, but discarded value-encoding entries expose
underestimates. Actual address-size accounting fixes large-address exceptions.

The scan covers every created output through the authenticated 29 October 2026
mainnet snapshot, including subsequently spent outputs: **363,308,474 outputs**,
comprising 363,293,969 transaction-created outputs and
14,505 genesis allocations. It consumed all 9,336 immutable chunks (232.921 GB),
14,128,814 blocks, and 126,739,842 transactions.
Phase-2-invalid transactions contribute only collateral returns when present;
their ordinary outputs were not created and are excluded.

The full scan took 18.46 minutes with 16 workers.
This excludes preparation and final verification. Source acquisition was already
complete; see the [authenticated source record](../minutxo-migration-cost/mainnet-2026-11-04/source.json).

## Formulas and interpretation

```text
coinsPerUTxOByte * (250 + 74 * numberOfNativeAssets + serializedDatumFieldBytes + serializedReferenceScriptFieldBytes)

coinsPerUTxOByte * (175 + serializedAddressFieldBytes + 12 * numberOfNativeAssets + 30 * numberOfMintingPolicies + totalAssetNameBytes + serializedDatumFieldBytes + serializedReferenceScriptFieldBytes)
```

Both are compared with `coinsPerUTxOByte * (160 + originalOutputBytes)` at a
fixed price of 4,310 lovelace/byte. Asset counts exclude ADA and count semantic
policy/name pairs after ledger decoding, including historical last-entry-wins
and zero-pruning rules. Quantities do not count as additional assets.

Address, datum and reference-script sizes include their entire original encoded
field contributions, including keys and wrappers. Re-encoding decoded fields
would be a different measurement, particularly where old decoders discarded
address bytes or redundant value entries.

**Before Babbage, this is a counterfactual common byte benchmark, not the minimum
enforced at creation.** Genesis has no received output encoding: its outputs
use explicitly constructed minimal Byron encodings and are reported separately.
The pinned Shelley genesis has no additional initial outputs.

## Every historical output

| Metric | Original winner | New winner |
|---|---:|---:|
| Underestimates | 13,283 (0.00366%) | 16,194 (0.00446%) |
| Median excess | 13.29% | 4.00% |
| 95th-percentile excess | 63.12% | 13.54% |
| Within 5% above benchmark | 5.21% | 78.58% |
| Mean requirement, ADA | 2.148553 | 1.578943 |
| Largest shortfall, ADA | 97.026720 | 18.300260 |

The old byte benchmark averages 1.432446 ADA.
Percentage quantiles are shown rounded down to 0.01 percentage points: each
exact quantile lies in `[shown, shown + 0.01)`. Counts, byte sums, byte deltas
and 5%/10% membership checks are exact; means use those sums and quantiles use
nearest ranks.

## Babbage and Conway only

This subset contains 229,486,615 created
outputs from the eras where the byte-based rule applied.

| Metric | Original winner | New winner |
|---|---:|---:|
| Underestimates | 6,727 (0.00293%) | 9,422 (0.00411%) |
| Median excess | 14.48% | 4.00% |
| 95th-percentile excess | 61.64% | 12.82% |
| Within 5% above benchmark | 2.39% | 78.44% |
| Mean requirement, ADA | 2.219003 | 1.638749 |
| Largest shortfall, ADA | 2.361880 | 2.995450 |

## By creation era

| Creation era | Outputs | Original misses | New misses | Original median / p95 | New median / p95 |
|---|---:|---:|---:|---:|---:|
| Genesis | 14,505 | 0 | 0 | 17.37% / 17.37% | 2.34% / 2.34% |
| Byron | 5,918,937 | 152 | 0 | 1.62% / 19.61% | 2.03% / 4.30% |
| Shelley | 1,621,975 | 0 | 0 | 11.11% / 18.48% | 2.32% / 4.26% |
| Allegra | 3,592,375 | 0 | 0 | 11.11% / 18.48% | 3.68% / 4.26% |
| Mary | 18,891,199 | 705 | 732 | 11.11% / 26.90% | 4.00% / 5.90% |
| Alonzo | 103,782,868 | 5,699 | 6,040 | 18.15% / 78.58% | 4.00% / 17.36% |
| Babbage | 143,814,091 | 6,727 | 9,422 | 16.61% / 79.31% | 4.00% / 16.97% |
| Conway | 85,672,524 | 0 | 0 | 11.11% / 38.57% | 4.00% / 6.79% |

## Asset-count subgroups

| Population | Outputs | Original median / p95 | New median / p95 |
|---|---:|---:|---:|
| No native assets | 217,834,833 | 11.11% / 26.90% | 4.00% / 4.56% |
| At least one native asset | 145,473,641 | 23.02% / 134.56% | 5.16% / 26.79% |
| Six or more native assets | 23,911,793 | 94.48% / 255.01% | 20.21% / 44.55% |

The six-or-more group is a subset of the native-asset group. The new formula
still has appreciable excess for larger bundles. It reserves maximum
token-quantity widths and conservative map/name-header allowances per asset.

## Why the misses occur

All 16,194 new-formula misses involve discarded value entries: 15,887 have
zero-quantity entries, 308 have empty policies, and one has both. The original
formula additionally misses 152 large Byron-address outputs and one Alonzo
output with trailing address bytes. Both formulas cover all 85,672,524 Conway
outputs in the downloaded history. These are empirical coverage results.

- Older decoders removed zero-quantity assets and empty policies. Those entries
  still occupied received bytes, but contribute nothing to semantic asset/policy
  counts. Both formulas can therefore undercharge the byte benchmark.
- Very large historical bootstrap addresses exceed the original fixed allowance.
  For example, a 22,602-byte Byron output contains a 22,600-byte address. The
  original formula is 22,512 bytes short; the new formula is 13 bytes above the
  common benchmark because it measures the address field.
- Some early address decoders also accepted trailing bytes. Measuring the
  complete received address field covers those bytes; a canonical re-encoding
  would not necessarily do so.

These observations are historical counterexamples to a universal claim, not
evidence that the chain accepted outputs below its then-current minimum.
Even a zero-miss subgroup would not prove a bound on every permitted encoding.

## Can the historical misses be recreated under current rules?

All 16,194 new-formula misses rely on zero-quantity assets or empty asset maps
under a policy. The value decoder rejects both from protocol version 9 onward,
so those encodings cannot appear in a newly accepted Conway or Dijkstra output.
Removing their redundant entries constructs a different, smaller encoding.

The original formula has surviving counterexamples. Auditing all 152 Byron
address exceptions against the modern bootstrap-attribute limit found 127
within the permitted 64 bytes and 25 above it. The 127 permitted addresses can
still be used in adequately funded modern outputs that the original fixed
allowance underestimates. The extra Alonzo address with trailing bytes is
rejected from Babbage onward.

For example, 125 of those cases use a 92-byte Byron address with a 44-byte HD
payload. A modern legacy-list output sending 2 ADA to that address occupies
100 bytes: its common byte allowance is 260, versus 250 from the original
formula and 269 from the new formula. At 4,310 lovelace per byte, the original
formula is 0.04310 ADA short. The output's 2 ADA is sufficient for the actual
minimum; the shortfall is in the proposed estimate.

Thus none of the observed new-formula misses can be recreated with those
encodings under current decoding rules, whereas some original-formula misses
remain constructible. See the [complete address audit](history-current-validity.json).
This does not prove the new formula covers every other
encoding permitted today. Existing historical outputs are not retrospectively
invalidated by stricter rules for creating new outputs.

## Verification and artifacts

- Every chunk was consumed fully. All 9,336 block counts match independent
  secondary-index entry counts. Source file sizes/timestamps and scanner hashes
  remain unchanged, and there are no failed chunk checkpoints.
- The previous 30-chunk sample reproduces all original metadata/checksums and
  both formulas' counts and mean charges for its 488,149 outputs.
- Genesis address construction matches an independent ledger golden fixture;
  its configured hash, 14,505-output count and total balance are checked.
- Statistical merging, percentile intervals, restart behavior and direct failures
  for malformed input or inconsistent checkpoints were checked separately.

See [full results and witnesses](history-comparison.json),
[verification evidence](history-verification.json), and the selected independent
[raw-byte audit](history-witness-audit.json).
This is structural analysis of authenticated chain data, not a ledger validation
test. Results weight output creations; they do not measure currently locked ADA
or the composition of the live UTxO set.

Reproduce from the repository root. Set `IMMUTABLE_DB` to the `immutable` directory of a mainnet node database.
Download the [mainnet Byron genesis file](https://book.play.dev.cardano.org/environments/mainnet/byron-genesis.json)
as `mainnet-byron-genesis.json`; the genesis step checks its hash.

```sh
python3 docs/minutxo-calibration/backtest_history.py \
  --source "$IMMUTABLE_DB" \
  --genesis mainnet-byron-genesis.json \
  --work-dir .workspace/minutxo-calibration-history/full \
  --result docs/minutxo-calibration/history-comparison.json \
  --workers 16
```

An identical rerun reuses only identity-matching checkpoints after rehashing
their source files. Changed code/configuration requires a new work directory.
