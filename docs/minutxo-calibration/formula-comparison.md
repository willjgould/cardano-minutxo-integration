# Comparing 160 + 72 assets + datum bytes + script bytes

Comparison dated 5 November 2026. This uses the same 488,149 mainnet output
creations, slots 201009603–201657572, as the [earlier calibration](README.md).
It compares against `4310 * (160 + original received output bytes)`.

**Including ADA as one asset makes a large difference.** With that
interpretation and complete encoded datum/script fields, the proposal covers
99.26% of this sample, with a median excess of 6.26%. Excluding ADA leaves
89.65% of outputs below the previous minimum.

## Definitions and the two asset counts

Let `N` be the number of distinct **non-ADA** `(policy ID, asset name)` pairs.
The comparison includes both readings of the proposed `numAssets`:

```text
Excluding ADA: p * (160 + 72*N       + D + R)
Including ADA: p * (160 + 72*(N + 1) + D + R)
              = p * (232 + 72*N + D + R)
```

At `p = 4310`, these have base amounts of 0.689600 and 0.999920 ADA
respectively, and both charge 0.310320 ADA per native asset.

The main comparison defines `D` and `R` as the complete original encoded field
contributions: payload, output-map key, tags, byte-string headers and datum
option wrapper. A legacy list-form datum hash includes its byte-string
header. Absent fields contribute zero. This interpretation gives the proposed
formula the larger of the two allowances considered here.

The sensitivity comparison uses the inner serialized Plutus Data for inline
datums, 32 bytes for datum hashes, and the inner serialized `[language, script]`
for reference scripts. The latter is not just the executable program length.
It excludes the outer field wrappers. Sizes are original bytes, not a fresh
canonical re-encoding.

## Whole-sample results

Negative changes mean the formula is below the previous requirement.

| Interpretation | Outputs below old minimum | Median change | 95th-percentile change | Mean new requirement |
| --- | ---: | ---: | ---: | ---: |
| Exclude ADA; full fields | 437,613 (89.65%) | −18.78% | +9.27% | 1.47634 ADA |
| Exclude ADA; inner payloads | 438,042 (89.74%) | −18.78% | +7.69% | 1.46908 ADA |
| Include ADA; full fields | 3,600 (0.74%) | +6.26% | +29.94% | 1.78666 ADA |
| Include ADA; inner payloads | 20,085 (4.11%) | +4.91% | +28.62% | 1.77940 ADA |

The old mean is 1.44802 ADA. The first formula increases the sum of requirements
over sampled creations by 1.96%, despite underestimating most individual
outputs: the excess for larger bundles outweighs many small deficits. This is
not a measurement of the change to current live-UTxO locked ADA.

Of the 3,600 misses when ADA is included with full fields, 3,598 are
zero-token bootstrap-address outputs. The other two miss by just one byte
(4,310 lovelace): a one-token output with maximum-width coin/quantity, and a
zero-token inline-datum output whose Value uses `[coin, {}]`. The latter is
a Conway encoding rejected by the stricter Dijkstra version-12 decoder.

The full-field versions by native-asset count are:

| Native assets | Outputs | Below old, exclude ADA | Median change, exclude ADA | Below old, include ADA | Median change, include ADA |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0 | 278,105 | 100% | −28.89% | 1.29% | +3.11% |
| 1 | 135,581 | 99.999% | −13.11% | 0.00074% | +12.18% |
| 2–5 | 55,732 | 42.93% | +2.58% | 0% | +17.40% |
| 6 or more | 18,731 | 0% | +44.01% | 0% | +51.59% |

Large bundles can share policies and have shorter names, so a uniform
72-byte charge per asset still overestimates those bundles substantially.
The 95th-percentile excess in the 6-or-more group is 197.40% excluding ADA,
or 204.15% including it.

The added payload terms are effective for large data/script outputs. Across
the 32 reference-script outputs, excluding ADA is below the old minimum in
every case, but only by a median 0.81%; including ADA covers every case with
median excess 0.46%. For inline-datum outputs, the respective below-minimum
rates are 75.22% and 0.00091%.

## What is missing, and why 72 is not a CBOR bound

The old `160` is UTxO-entry overhead. The old formula also charges the
address, ADA amount and output/value container framing. For example, an
ADA-only base-address output with a five-byte coin is 65 bytes:

```text
Old:           4310 * (160 + 65) = 0.969750 ADA
Exclude ADA:   4310 * 160        = 0.689600 ADA
Include ADA:   4310 * (160 + 72) = 0.999920 ADA
```

Counting ADA effectively supplies the missing base allowance.

The ledger compact-memory representation has an asset payload bound of
`12*N + 28*numPolicies + sum(distinctNameLengths) <= 72*N`. CBOR uses different
overheads: an independent policy ID needs 30 encoded bytes, its singleton map
one byte, a maximal asset name 34 bytes, and a maximal quantity nine bytes.
That sums to **74 bytes per asset**, before outer framing. Thus 72 is not a
universal encoded-size upper bound, even with full payload-field charges.

## Small adjustments and their limits

Keeping `N` exclusive of ADA, these variants have full-field D/R charges:

| Formula inside `p*(...)` | Outputs below old minimum | Median excess | 95th-percentile excess |
| --- | ---: | ---: | ---: |
| `232 + 72*N + D + R` (original, counting ADA) | 3,600 | 6.26% | 29.94% |
| `235 + 74*N + D + R` | 3,598 | 7.13% | 32.39% |
| `250 + 72*N + D + R` | 0 | 11.11% | 35.77% |
| `250 + 74*N + D + R` | 0 | 11.11% | 36.61% |
| `368 + 72*N + D + R` | 0 | 63.56% | 86.80% |

The empirical minimum base is **250 bytes** for either coefficient. It was
fitted on the first 20 chunks and covers all 166,645 outputs in the last
10 chunks without adjustment. This is 90 bytes above the proposed base when
ADA is excluded, but only **18 bytes (0.077580 ADA)** above the proposal when
ADA is included. The binding output is a zero-token bootstrap-address output
with 90 received bytes; its old minimum is 1.077500 ADA.

The `235 + 74*N` expression has an analytical upper-bound argument for
base/enterprise addresses and minimal-width CBOR, when D/R cover complete
fields. Bootstrap addresses and arbitrary received encodings remain outside
that guarantee. The `368 + 72*N` expression can bound those same conventional
address/encoding shapes if a 5,000-byte maximum encoded Value is assumed,
but its base charge is substantially higher. The binding construction has
67 assets with separate policies, maximal names and nine-byte quantities:
its map-form output is 5,032 bytes, so `160 + 5032 - 72*67 = 368`.

Consequently, `250 + 74*N + D + R` is a useful candidate from this comparison:
it covered every observed creation and uses the appropriate worst-case token
entry coefficient. The constant remains a sample-derived allowance, not a
proof for every bootstrap address or accepted nonminimal encoding. If the
requirement is universal coverage of the old rule, those cases need explicit
bounds or separately measured contributions.

## Comparison with the previous simple allowances

For context only, applying these allowances uniformly to the same general
sample gives:

| Allowance | Below old minimum | Median change |
| --- | ---: | ---: |
| `1 ADA + 0.32 ADA*N`, without payload terms | 21.84% | +3.12% |
| Flat 1.5 ADA | 24.41% | +51.98% |
| Flat 2 ADA | 19.01% | +102.64% |

This is a hypothetical application to the full sample. The SDKs using fixed
allowances target particular output shapes; these percentages do not measure
their actual transaction failure rates.

## Reproduction and checks

Set `IMMUTABLE_DB` to the `immutable` directory of the
[Mithril-certified mainnet snapshot](mainnet-source.json) (chunks `00000`–`09335`).

```sh
python3 docs/minutxo-calibration/compare_formula.py \
  --source "$IMMUTABLE_DB" \
  --result docs/minutxo-calibration/formula-comparison.json
```

The [script](compare_formula.py) retains both asset-count and size definitions.
The [results](formula-comparison.json) retain source hashes, categories,
holdout outcomes and extreme-output witnesses. Every chunk's size/hash,
block/transaction/output counts and body checksums matched the earlier
calibration, whose independent Haskell scanner comparison is retained.

Independent review checked hand-encoded inline datum, reference-script and
datum-hash fields, and checked the byte-decomposition identity on all 18,926
outputs of chunk 09314. Below/equal/above counts agree with population sizes.
No ledger implementation or transaction checks were changed or run.
