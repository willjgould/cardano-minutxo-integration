# Full historical backtest of the CIP formula and its alternatives

Analysis completed 12 November 2026, over the same authenticated history as the
[6 November backtest](history-comparison.md). Datum and reference-script terms
now count payload bytes only, as the CIP specifies. Two controls repeat the
6 November whole-field measurements and reproduce that result exactly.

## Findings

- **Dropping the wrappers barely changes the CIP formula.** Underestimates rise
  from 13,283 to 13,312 of 363,308,474 outputs (0.00366% either way). The median
  excess falls from 13.29% to 12.65%; the p95 is unchanged at 63.11–63.12%.
- **Alternative 1 depends on the wrappers.** With payload sizes it underestimates
  994,993 outputs (0.274%), including 3.65% of inline-datum outputs, against
  16,194 with whole fields. Its 175 base was calibrated with whole-field datum and
  script sizes and leaves no slack for their wrappers.
- **Alternative 2 underestimates reference-script outputs.** It is below the
  previous minimum for 96.6% of them (median −94.25%), by up to 69.33 ADA.
- **Alternative 3 never underestimates**, as expected: an ADA amount never
  encodes to more than 9 bytes. Its median excess is 1.63% and its p95 2.03%.
- **The CIP formula has no underestimates among Conway outputs.** All 13,312
  are in Byron, Mary, Alonzo and Babbage outputs (see the era table).

## Formulas and measurements

All formulas are compared with `coinsPerUTxOByte * (160 + originalOutputBytes)`
at 4,310 lovelace per byte, using the same population, eras and percentile method
as the 6 November backtest. Before Babbage this is a counterfactual benchmark.

| Name | Formula |
| --- | --- |
| CIP | `250 + 74 * numberOfNativeAssets + serializedDatumBytes + serializedReferenceScriptBytes` |
| Alt 1 | `175 + serializedAddressFieldBytes + 12 * numberOfNativeAssets + 30 * numberOfMintingPolicies + totalAssetNameBytes + serializedDatumBytes + serializedReferenceScriptBytes` |
| Alt 2 | `250 + 74 * numberOfNativeAssets + serializedDatumBytes` |
| Alt 3 | `160 + serializedOutputBytes - serializedAdaAmountBytes + 9` |
| Controls | CIP and Alt 1 with whole-field datum and script sizes, as on 6 November |

- `serializedDatumBytes`: 32 for a datum hash; for an inline datum, the encoded
  Plutus data inside tag 24, which is its datum-hash input.
- `serializedReferenceScriptBytes`: the script-hash input without its one-byte
  language prefix: a native script's CBOR, or a Plutus script's byte-string
  contents.
- Neither includes the output's keys, tags or headers. Alt 1's address term
  still counts the whole address field, as its name says.

## Results

Outputs: 363,308,474 (363,293,969 transaction-created, 14,505 genesis); 232.921 GB; 23.27 minutes with 24 workers. Old byte benchmark mean: 1.432446 ADA.

### Every historical output

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| CIP: `250 + 74N + D + R` | 13,312 (0.00366%) | 12.65% | 63.11% | 5.45% | 2.145522 | 97.026720 |
| Alt 1: policy, address and name sizes | 994,993 (0.27387%) | 4.00% | 13.53% | 82.51% | 1.575913 | 18.300260 |
| Alt 2: datum only, `250 + 74N + D` | 27,569 (0.00759%) | 12.65% | 63.11% | 5.45% | 2.144630 | 97.026720 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 1.63% | 2.03% | 100.00% | 1.447650 | 0.000000 |
| Control: CIP, whole fields | 13,283 (0.00366%) | 13.29% | 63.12% | 5.21% | 2.148553 | 97.026720 |
| Control: Alt 1, whole fields | 16,194 (0.00446%) | 4.00% | 13.54% | 78.58% | 1.578943 | 18.300260 |

### Babbage and Conway only

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| CIP: `250 + 74N + D + R` | 6,756 (0.00294%) | 13.73% | 61.64% | 2.78% | 2.214510 | 2.361880 |
| Alt 1: policy, address and name sizes | 988,221 (0.43062%) | 4.00% | 12.80% | 83.19% | 1.634256 | 2.995450 |
| Alt 2: datum only, `250 + 74N + D` | 21,013 (0.00916%) | 13.73% | 61.64% | 2.78% | 2.213097 | 69.330660 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 1.54% | 2.03% | 100.00% | 1.507211 | 0.000000 |
| Control: CIP, whole fields | 6,727 (0.00293%) | 14.48% | 61.64% | 2.39% | 2.219003 | 2.361880 |
| Control: Alt 1, whole fields | 9,422 (0.00411%) | 4.00% | 12.82% | 78.44% | 1.638749 | 2.995450 |

### Outputs in group `payload/inline_datum`

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| CIP: `250 + 74N + D + R` | 869 (0.00332%) | 16.09% | 37.79% | 12.98% | 2.188675 | 0.969750 |
| Alt 1: policy, address and name sizes | 956,561 (3.65064%) | 1.22% | 3.64% | 94.52% | 1.919683 | 1.034400 |
| Alt 2: datum only, `250 + 74N + D` | 8,122 (0.03100%) | 16.09% | 37.79% | 12.96% | 2.182472 | 68.783290 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 0.82% | 1.43% | 100.00% | 1.905717 | 0.000000 |
| Control: CIP, whole fields | 866 (0.00331%) | 17.68% | 39.79% | 9.54% | 2.218787 | 0.943890 |
| Control: Alt 1, whole fields | 1,058 (0.00404%) | 2.90% | 6.07% | 79.13% | 1.949795 | 1.008540 |

### Outputs in group `payload/hash_datum`

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| CIP: `250 + 74N + D + R` | 266 (0.00086%) | 19.49% | 31.25% | 0.02% | 1.645856 | 0.193950 |
| Alt 1: policy, address and name sizes | 21,650 (0.06963%) | 3.86% | 5.52% | 88.70% | 1.417267 | 0.293080 |
| Alt 2: datum only, `250 + 74N + D` | 4,509 (0.01450%) | 19.49% | 31.25% | 0.00% | 1.642457 | 66.205910 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 1.32% | 1.73% | 100.00% | 1.376194 | 0.000000 |
| Control: CIP, whole fields | 240 (0.00077%) | 20.33% | 31.77% | 0.01% | 1.655891 | 0.185330 |
| Control: Alt 1, whole fields | 934 (0.00300%) | 4.66% | 6.00% | 55.66% | 1.427302 | 0.284460 |

### Outputs in group `payload/reference_script`

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| CIP: `250 + 74N + D + R` | 0 (0.00000%) | 0.62% | 6.97% | 88.19% | 23.702357 | 0.000000 |
| Alt 1: policy, address and name sizes | 13,931 (94.34512%) | -0.07% | 0.04% | 5.55% | 23.519455 | 0.051720 |
| Alt 2: datum only, `250 + 74N + D` | 14,257 (96.55289%) | -94.25% | -59.55% | 3.24% | 1.747399 | 69.330660 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 0.06% | 0.55% | 100.00% | 23.555011 | 0.000000 |
| Control: CIP, whole fields | 0 (0.00000%) | 0.87% | 9.01% | 87.59% | 23.769290 | 0.000000 |
| Control: Alt 1, whole fields | 0 (0.00000%) | 0.21% | 1.80% | 99.67% | 23.586387 | 0.000000 |

### CIP formula by creation era

| Era | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Genesis | 0 (0.00000%) | 17.37% | 17.37% | 0.00% | 1.077500 | 0.000000 |
| Byron | 152 (0.00257%) | 1.62% | 19.61% | 84.06% | 1.077500 | 97.026720 |
| Shelley | 0 (0.00000%) | 11.11% | 18.48% | 24.22% | 1.077500 | 0.000000 |
| Allegra | 0 (0.00000%) | 11.11% | 18.48% | 29.48% | 1.077500 | 0.000000 |
| Mary | 705 (0.00373%) | 11.11% | 26.90% | 19.09% | 1.528403 | 0.181020 |
| Alonzo | 5,699 (0.00549%) | 17.81% | 78.58% | 3.27% | 2.220027 | 18.110620 |
| Babbage | 6,756 (0.00470%) | 16.27% | 79.31% | 1.80% | 2.394171 | 2.361880 |
| Conway | 0 (0.00000%) | 11.11% | 37.29% | 4.42% | 1.912922 | 0.000000 |

Percentage quantiles are rounded down to 0.01 percentage points; counts, byte
sums and 5% membership are exact. The largest shortfall is the largest amount by
which a formula falls below the previous minimum.

## Verification

- **Controls:** both whole-field controls match the 6 November result in all 25
  groups, ignoring only witness rows, which now carry the payload fields.
- `control_cip_whole_fields` vs earlier `original_winner`: 25 groups, group sets identical: True, groups differing: 0
- `control_policy_address_whole_fields` vs earlier `new_winner`: 25 groups, group sets identical: True, groups differing: 0
- **Per-chunk pre-flight:** before the full run, seven chunks from Byron to Conway
  matched their 6 November checkpoints exactly for both controls.
- **Plutus script layer:** in sampled reference-script outputs, each counted Plutus
  payload is exactly one CBOR byte string (the flat program) with no trailing
  bytes, which is the layer the ledger hashes.

## Reproduction

Requires Python 3.11 or later. Set `IMMUTABLE_DB` to the `immutable` directory of the
[Mithril-certified mainnet snapshot](mainnet-source.json) (chunks `00000`–`09335`).
Download the [mainnet Byron genesis file](https://book.play.dev.cardano.org/environments/mainnet/byron-genesis.json)
as `mainnet-byron-genesis.json`; the genesis step checks its hash.
When running from a worktree without checked-out submodules, set
`MINUTXO_INTEGRATION_ROOT` to a checkout that has them; the genesis step reads
ledger fixtures from there.

```sh
python3 docs/minutxo-calibration/backtest_history.py \
  --source "$IMMUTABLE_DB" \
  --genesis mainnet-byron-genesis.json \
  --work-dir .workspace/minutxo-calibration-history/payload-full \
  --result docs/minutxo-calibration/history-formulas.json \
  --workers 24
python3 docs/minutxo-calibration/report_history.py docs/minutxo-calibration/history-formulas.json \
  --control docs/minutxo-calibration/history-comparison.json
```

The run's manifest hash is
`db2740b97855fac1e6a70f5a6926e4f3a7651dc8b9756c5869476d7d104ff25a`. That run read
the expected genesis hash from the `cardano-node` mainnet configuration;
`extract_genesis.py` now holds the same hash as a constant and produces identical
genesis outputs.
