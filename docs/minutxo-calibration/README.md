# Calibrating a constant plus a charge per distinct asset

Analysis dated 5 November 2026, against `minutxo-calculation` and its ledger pin
`a1631b518297bb9f8d5d2e4cda11ca0effe70ff8`.

The follow-up [comparison of `160 + 72*numAssets + datumSize + refScriptSize`](formula-comparison.md)
measures both ADA-count interpretations and encoded-field versus payload sizes.
The [component comparison](component-comparison.md) explains the remaining
excess and measures policy-count, name-length and address-size refinements.

**About 0.32 ADA per distinct asset is a defensible token surcharge at 4,310
lovelace per byte. It does not make a token-count-only formula a universal,
close upper bound on the previous whole-output minimum.** Datum/script bytes
and address/encoding differences still matter.

The measured comparison is:

```text
oldMinimum = 4310 * (160 + original encoded output bytes)
prediction = C + x * number of distinct (policy ID, asset name) pairs
```

Token quantities do not count as additional assets. The byte price is held
fixed for comparison; this analysis does not reconstruct historical parameters
or execute ledger validation.

## Actual mainnet sample

The extractor read 30 authenticated immutable chunks, `09306` through `09335`,
from the [previously verified snapshot](../minutxo-migration-cost/mainnet-2026-11-04/source.json)
already in this checkout. This covers slots 201009603 through 201657572,
approximately 7.5 days, containing 32,012 blocks, 195,524 transactions and
488,149 created outputs. These are output creations, including subsequently
spent outputs, rather than a census of the live UTxO set. Repeated application
activity can dominate this distribution.

The first 20 chunks were used for fitting and the last 10 for a chronological
holdout. The complete sample has 367,375 outputs with no datum, datum hash or
reference script; 359,472 of those use base or enterprise addresses. There are
110,126 inline-datum outputs, 10,620 datum-hash outputs and 32 reference-script
outputs; these categories can overlap with reference scripts.

For each constant, the least nonnegative integer slope covering all positive
asset counts in the fitting sample is calculated exactly:

```text
x = max(0, max over N > 0 of ceil((oldMinimum - C) / N))
```

Zero-asset outputs are checked separately because no slope can repair them.

| Constant, ADA | Measured required x, ADA/asset, plain outputs | Plain zero-asset outputs still below old minimum, full sample |
| ---: | ---: | ---: |
| 1.000000 | 0.314550 | 3,598 |
| 1.050000 | 0.289317 | 3,598 |
| 1.077500 | 0.280150 | 0 |
| 1.100000 | 0.272650 | 0 |
| 1.200000 | 0.248619 | 0 |

For these constants, the fitting-sample maximum slope also covers all
positive-asset outputs in the holdout. At 1.0775 ADA and above, no plain
outputs in the holdout are underestimated. These are sample results, not
universal coefficients. The zero-asset exceptions below 1.0775 ADA use
bootstrap addresses; the largest is a 90-byte output.

`1 ADA + 0.32 ADA * N` covers every one of the 359,472 sampled plain outputs
with base/enterprise addresses. Its excess is:

| Population | Median excess | 95th-percentile excess | 99th-percentile excess |
| --- | ---: | ---: | ---: |
| All sampled plain base/enterprise outputs | 3.12% | 37.66% | 116.68% |
| Those containing native assets | 13.85% | 83.80% | 201.92% |

Only 3,104 of the 110,970 asset-bearing outputs are within 5% above the old
minimum. The good overall median largely reflects ADA-only outputs. This is
not evidence that the formula is barely above the minimum for most token
bundles. Shared policies and shorter names create substantial slack.

## Worst-case token coefficient

For the standard encoder, one distinct asset can require up to:

| Contribution | Bytes |
| --- | ---: |
| A separate policy ID, including byte-string header | 30 |
| Singleton inner map header | 1 |
| 32-byte asset name, including header | 34 |
| Quantity | 9 |
| Total | 74 |

Thus the token-entry rate is `74 * 4310 = 318940` lovelace per asset, before
assigning the small outer framing costs between the constant and slope.
The encoder model in [calibrate.py](calibrate.py) constructs the extremal
plain list outputs and includes the two additional bytes of the minimal-width
map form.

With a 5,000-byte maximum encoded `Value`, these are the rounded-up slopes:

| Constant, ADA | Standard ledger list form | Minimal-width map form |
| ---: | ---: | ---: |
| 1.00 | 0.318939 | 0.323170 |
| 1.05 | 0.318193 | 0.318322 |
| 1.10 | 0.317447 | 0.317575 |
| 1.20 | 0.315954 | 0.316083 |

The 5,000-byte value limit is an explicit assumption of this table. At 1 ADA
the map form binds at one asset; the other rows bind at 67 assets, each with a
separate policy, maximum name and nine-byte quantity. The corresponding value
is 4,970 bytes. For 68 or more assets, the whole-value limit bounds the output
more tightly than the token-entry bound.

If fixing `x = 0.32 ADA`, `C = 1.003170 ADA` suffices for both minimal-width
plain output forms with base/enterprise addresses. The one-asset map output
binds: its old minimum is 1.323170 ADA. The 74-byte-per-asset rate is below
the rounded 0.32 ADA rate, with enough margin to cover subsequent map-header
transitions under the ledger's compact-value limits. A round constant of
1.05 ADA therefore covers this restricted domain without needing the
5,000-byte value-limit assumption.

These bounds exclude bootstrap/pointer addresses, datums, reference scripts,
and alternative nonminimal encodings. In particular, the observed success of
`1 + 0.32*N` is not proof: the allowed minimal-width map example above already
needs 3,170 lovelace more.

## Why the full proposed formula still fails

At a 1 ADA constant, covering every positive-asset output in the full sample
requires **7.844120 ADA per asset**, driven by a one-asset inline-datum output.
Even that leaves **25,897 zero-asset outputs** below the old minimum.

The largest zero-asset output has a reference script and requires
**46.582480 ADA**. That forces `C >= 46.582480 ADA` regardless of `x`.
It is also the largest old minimum anywhere in this sample, so a flat
46.582480 ADA already covers everything observed. Its median excess is
approximately **4,620%**. This illustrates why fitting a globally safe line
does not achieve the desired closeness.

Both decisive witnesses, their original byte offsets and transaction IDs are
retained in [results.json](results.json). The script witness is transaction
`74cb088fe83b3c2f8118f0235b3cbb358f7b8bfa269332f22a6e3536cd12d257`, output 0,
in chunk `09314`. Its output is 10,648 bytes, of which the script field accounts
for 10,581 bytes including its key and wrappers.

For an actual universal bound, received encodings also matter. The previous
ledger calculation prices `Sized` byte spans, not just standard re-encoding.
The pinned binary decoder explicitly permits noncanonical encodings;
version 12 byte strings accept indefinite sequences, including empty chunks.
Consequently even the encoding of a zero-asset plain output can grow up to
the enclosing transaction limit. This is a source-inspected limitation, not
an executed adversarial ledger test.

The useful design candidate is therefore a token surcharge around 0.32 ADA,
with address/framing coverage and explicit datum/script byte charges. A
policy-count or name-length term would further reduce the observed excess for
bundles. The full two-parameter formula has not met the requested properties.

## Reproduction and verification

Set `IMMUTABLE_DB` to the `immutable` directory of a mainnet node database.

```sh
python3 docs/minutxo-calibration/calibrate.py \
  --source "$IMMUTABLE_DB" \
  --result docs/minutxo-calibration/results.json
```

The script uses Python's standard library, reads source chunks without
changing them, and records each source SHA256 plus the analysis-script hashes.
It consumes every input byte and fails directly on unsupported block/output
shapes. Ordinary outputs of phase-two-invalid transactions are excluded;
their collateral return is included when present. The sample contains 33
such transactions and two collateral returns. Every extracted output carries
at least the old minimum at the comparison price.

For chunk `09335`, all seven recorded independent Haskell scanner measurements
match: chunk size/hash, block count, transaction count, body-byte total,
body-size checksum and transaction-body hash checksum. That comparison is
enforced by the calibration script when the chunk is included. A separate
hand-encoded fixture also checked valid/invalid transaction output selection,
collateral indexing and original output spans; truncated and unsupported
input failed directly.

This verifies the analysis against existing independent measurements. It is
not a ledger conformance run or a new red/green transaction test. No pricing
implementation has changed.

Relevant pinned sources are `Babbage/TxOut.hs` (`babbageMinUTxOValue` and output
encoding), `Mary/Value.hs` (asset/quantity limits and encoding),
`Alonzo/Rules/Utxo.hs` (`validateOutputTooBigUTxO`), and
`Binary/Decoding/Sized.hs` (preservation of accepted byte spans).
