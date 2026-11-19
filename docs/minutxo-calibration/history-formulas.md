# Historical backtest of a minimum-ADA formula

This backtest compares a proposed minimum-ADA formula, an alternative to it and
other candidate formulas with the current formula, for every output created on
Cardano mainnet up to 28 October 2026. Each output is measured from its
original bytes, as they appear in the block that created it, and priced at
4,310 lovelace per byte.

## Findings

For the 229,486,615 outputs created since the Babbage hard fork, when the
current formula took effect:

- **The proposed formula** requires less than the current formula for 8,034
  outputs (0.004%), by at most 2.36 ADA. None of them were created in the
  Conway era. Across every output, 14,519 of its 14,668 underestimates are
  outputs with zero-quantity asset entries, which the ledger discards. Its
  median excess is 11.1%, and its mean requirement is 2.19 ADA, against
  1.49 ADA for the current formula.
- **Its upper tail comes from outputs with native assets.** Its p95 excess is
  61.6%, because 74 bytes per asset assumes that each asset has its own policy
  and a 32-byte name. Across every output, the p95 excess is 12.7% for outputs
  without native assets and 255.0% for outputs with six or more.
- **The alternative** charges only bootstrap addresses for their size, and
  keeps a 250-byte base for every other output. Bootstrap-address outputs get
  the same requirement as under the proposed formula. Outputs with addresses
  shorter than 57 bytes, such as enterprise addresses, pay as if their address
  were 57 bytes. It requires less than the current formula for 6,755 outputs
  (0.003%). Its median excess is 12.9%, and its mean requirement is 2.22 ADA.
- **Without an address term**, the formula charges every address at its
  250-byte base, whatever the address's size. It requires less than the current
  formula for 6,756 outputs (0.003%). Its median excess is 13.7%, and its mean
  requirement is 2.21 ADA.
- **Large bootstrap addresses have occurred on mainnet.** Before Shelley limited
  bootstrap address attributes to 64 bytes, Byron-era outputs carried addresses
  of up to 22,600 bytes. Across every output, they cause the largest shortfall
  of the formula without an address term, 97.03 ADA. Each address term reduces
  the largest shortfall to about 18 ADA.
- **Alt 1** has a median excess of 4.0%, and requires less than the current
  formula for 9,422 outputs (0.004%).
- **Alt 2** has neither an address term nor a reference-script term. It
  requires less than the current formula for 96.6% of outputs with a reference
  script, by up to 69.33 ADA.
- **Alt 3** never requires less than the current formula, because an ADA amount
  never encodes to more than 9 bytes. Its median excess is 1.5%.
- **CBOR wrappers barely matter without an address term.** If that formula
  counted whole datum and script fields instead of their payloads, its
  underestimates would change from 6,756 to 6,727. Alt 1 depends on them: with
  payload bytes only, 988,221 outputs (0.43%) fall below the current formula,
  because its 175-byte base was fitted to whole fields.
- **Other address terms.** Adding every address to the 250-byte base raises the
  median excess to 36.4% and the mean requirement to 2.44 ADA, with 234
  underestimates. Adding bootstrap addresses in full to the 250-byte base gives
  6,737 underestimates, but raises the median excess of bootstrap-address
  outputs from 10.2% to 33.6%. Charging address bytes above 57 gives 6,755
  underestimates and a mean requirement of 2.22 ADA.

## Data

- **Chain data:** immutable chunks `00000`–`09335` of a Mithril-certified
  mainnet snapshot from epoch 664, ending with block 14,128,638 at slot
  201,657,572 on 28 October 2026. [mainnet-source.json](mainnet-source.json)
  records the snapshot, its certificate and how it was verified.
- **Genesis:** the 14,505 initial Byron allocations, built from the mainnet
  Byron genesis file. No transaction created them, so their sizes are minimal
  encodings, not original bytes.
- **Population:** every output created by an accepted transaction, plus the
  collateral returns of transactions that failed phase-2 validation. The other
  outputs of those transactions were never created. Spent outputs are included,
  so this is not a census of the current UTxO set.
- **Comparison:** the current formula applies from the Babbage hard fork on
  22 September 2022. For earlier outputs, the comparison is counterfactual.

## Formulas

Each formula is multiplied by `coinsPerUTxOByte`. The result key names the
formula in [history-formulas.json](history-formulas.json).

| Name | Formula | Result key |
| --- | --- | --- |
| Current | `160 + serializedOutputBytes` | – |
| Proposed | `193 + 74 * numberOfNativeAssets + serializedAddressBytes + serializedDatumBytes + serializedReferenceScriptBytes` | `address_all_rebased` |
| Alternative | `(193 + serializedAddressBytes if bootstrap address, else 250) + 74 * numberOfNativeAssets + serializedDatumBytes + serializedReferenceScriptBytes` | `address_bootstrap_rebased` |
| No address term | `250 + 74 * numberOfNativeAssets + serializedDatumBytes + serializedReferenceScriptBytes` | `cip` |
| Alt 1 | `175 + serializedAddressFieldBytes + 12 * numberOfNativeAssets + 30 * numberOfMintingPolicies + totalAssetNameBytes + serializedDatumFieldBytes + serializedReferenceScriptFieldBytes` | `control_policy_address_whole_fields` |
| Alt 2 | `250 + 74 * numberOfNativeAssets + serializedDatumBytes` | `alternative_datum_only` |
| Alt 3 | `160 + serializedOutputBytes - serializedAdaAmountBytes + 9` | `alternative_fixed_ada_width` |

The base of 193 is 250 less the 57 bytes of a base address, the largest common
Shelley address. The formula without an address term has the result key `cip`
because it was the CIP's first proposal.

Two more result keys test sensitivity to CBOR wrappers:
`control_cip_whole_fields` is the formula without an address term, counting
whole fields, and `alternative_policy_address` is Alt 1 with payload bytes.

Three more result keys test other address terms. In this table, `A` is
`serializedAddressBytes`.

| Name | Formula | Result key |
| --- | --- | --- |
| Every address, 250 base | `250 + 74 * numberOfNativeAssets + A + serializedDatumBytes + serializedReferenceScriptBytes` | `address_all` |
| Bootstrap only, 250 base | `250 + 74 * numberOfNativeAssets + (A if bootstrap address, else 0) + serializedDatumBytes + serializedReferenceScriptBytes` | `address_bootstrap_only` |
| Above 57 bytes | `250 + 74 * numberOfNativeAssets + max(0, A - 57) + serializedDatumBytes + serializedReferenceScriptBytes` | `address_above_57` |

The measurements, all taken from the output's original bytes:

- `numberOfNativeAssets`: distinct pairs of policy ID and asset name, excluding
  ADA. Entries with zero quantity, which the ledger discards, are not counted.
- `numberOfMintingPolicies`: distinct policy IDs among those pairs.
- `totalAssetNameBytes`: the sum of the asset-name lengths of those pairs.
- `serializedDatumBytes`: 32 for a datum hash. For an inline datum, the encoded
  Plutus data inside tag 24, which is what its hash is computed over.
- `serializedReferenceScriptBytes`: what the script hash is computed over,
  without its one-byte language prefix. This is a native script's CBOR, or the
  contents of a Plutus script's byte string.
- `serializedAddressBytes`: the address as written in the output, without its
  byte-string header. This is a Shelley address's bytes, or a bootstrap
  address's CBOR, including its CRC.
- `serializedAddressFieldBytes`, `serializedDatumFieldBytes` and
  `serializedReferenceScriptFieldBytes`: everything the field adds to the
  output's encoding, including its map key and CBOR wrappers.
- `serializedOutputBytes` and `serializedAdaAmountBytes`: the encoded size of
  the whole output and of its ADA amount.

The metrics:

- **Underestimates:** outputs for which the formula requires less than the
  current formula.
- **Median and p95 excess:** how far the formula is above the current formula,
  as a percentage, by nearest rank and rounded down to 0.01 percentage points.
  A negative value is a shortfall.
- **Within 5% above:** outputs for which the formula requires at least the
  current amount and at most 5% more.
- **Mean requirement:** the formula's mean requirement over the outputs.
- **Largest shortfall:** the largest amount by which the formula requires less
  than the current formula.

## Results

363,308,474 outputs (363,293,969 created by transactions, 14,505 in genesis); 232.921 GB of chunks.

### Outputs created since the Babbage hard fork

229,486,615 outputs.

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current: `160 + serializedOutputBytes` | – | – | – | – | 1.492008 | – |
| Proposed: `193 + 74N + A + D + R` | 8,034 (0.00350%) | 11.11% | 61.64% | 2.10% | 2.189871 | 2.361880 |
| Alternative: `(193 + A if bootstrap, else 250) + 74N + D + R` | 6,755 (0.00294%) | 12.89% | 61.64% | 1.49% | 2.215423 | 2.361880 |
| No address term: `250 + 74N + D + R` | 6,756 (0.00294%) | 13.73% | 61.64% | 2.78% | 2.214510 | 2.361880 |
| Alt 1: address, policy and name sizes | 9,422 (0.00411%) | 4.00% | 12.82% | 78.44% | 1.638749 | 2.995450 |
| Alt 2: no reference-script term | 21,013 (0.00916%) | 13.73% | 61.64% | 2.78% | 2.213097 | 69.330660 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 1.54% | 2.03% | 100.00% | 1.507211 | 0.000000 |

### Conway outputs

85,672,524 outputs.

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current: `160 + serializedOutputBytes` | – | – | – | – | 1.432822 | – |
| Proposed: `193 + 74N + A + D + R` | 0 (0.00000%) | 11.11% | 30.82% | 4.22% | 1.888803 | 0.000000 |
| Alternative: `(193 + A if bootstrap, else 250) + 74N + D + R` | 0 (0.00000%) | 11.11% | 37.29% | 3.19% | 1.913745 | 0.000000 |
| No address term: `250 + 74N + D + R` | 0 (0.00000%) | 11.11% | 37.29% | 4.42% | 1.912922 | 0.000000 |
| Alt 1: address, policy and name sizes | 0 (0.00000%) | 4.00% | 6.79% | 87.51% | 1.532831 | 0.000000 |
| Alt 2: no reference-script term | 5,253 (0.00613%) | 11.11% | 37.29% | 4.42% | 1.911737 | 69.235840 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 1.50% | 2.03% | 100.00% | 1.447485 | 0.000000 |

### Every output

363,308,474 outputs.

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current: `160 + serializedOutputBytes` | – | – | – | – | 1.432446 | – |
| Proposed: `193 + 74N + A + D + R` | 14,668 (0.00404%) | 11.11% | 62.98% | 1.33% | 2.122073 | 18.231300 |
| Alternative: `(193 + A if bootstrap, else 250) + 74N + D + R` | 13,159 (0.00362%) | 11.15% | 63.13% | 0.94% | 2.148319 | 18.110620 |
| No address term: `250 + 74N + D + R` | 13,312 (0.00366%) | 12.65% | 63.11% | 5.45% | 2.145522 | 97.026720 |
| Alt 1: address, policy and name sizes | 16,194 (0.00446%) | 4.00% | 13.54% | 78.58% | 1.578943 | 18.300260 |
| Alt 2: no reference-script term | 27,569 (0.00759%) | 12.65% | 63.11% | 5.45% | 2.144630 | 97.026720 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 1.63% | 2.03% | 100.00% | 1.447650 | 0.000000 |

### Outputs with an inline datum

26,202,590 outputs.

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current: `160 + serializedOutputBytes` | – | – | – | – | 1.892346 | – |
| Proposed: `193 + 74N + A + D + R` | 1,014 (0.00387%) | 11.91% | 28.42% | 18.40% | 2.134777 | 0.969750 |
| Alternative: `(193 + A if bootstrap, else 250) + 74N + D + R` | 869 (0.00332%) | 16.09% | 37.79% | 12.98% | 2.188675 | 0.969750 |
| No address term: `250 + 74N + D + R` | 869 (0.00332%) | 16.09% | 37.79% | 12.98% | 2.188675 | 0.969750 |
| Alt 1: address, policy and name sizes | 1,058 (0.00404%) | 2.90% | 6.07% | 79.13% | 1.949795 | 1.008540 |
| Alt 2: no reference-script term | 8,122 (0.03100%) | 16.09% | 37.79% | 12.96% | 2.182472 | 68.783290 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 0.82% | 1.43% | 100.00% | 1.905717 | 0.000000 |

### Outputs with a datum hash

31,090,720 outputs.

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current: `160 + serializedOutputBytes` | – | – | – | – | 1.362344 | – |
| Proposed: `193 + 74N + A + D + R` | 919 (0.00296%) | 16.33% | 25.73% | 0.01% | 1.595084 | 0.193950 |
| Alternative: `(193 + A if bootstrap, else 250) + 74N + D + R` | 265 (0.00085%) | 19.49% | 31.25% | 0.02% | 1.645856 | 0.193950 |
| No address term: `250 + 74N + D + R` | 266 (0.00086%) | 19.49% | 31.25% | 0.02% | 1.645856 | 0.193950 |
| Alt 1: address, policy and name sizes | 934 (0.00300%) | 4.66% | 6.00% | 55.66% | 1.427302 | 0.284460 |
| Alt 2: no reference-script term | 4,509 (0.01450%) | 19.49% | 31.25% | 0.00% | 1.642457 | 66.205910 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 1.32% | 1.73% | 100.00% | 1.376194 | 0.000000 |

### Outputs with a reference script

14,766 outputs.

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current: `160 + serializedOutputBytes` | – | – | – | – | 23.537771 | – |
| Proposed: `193 + 74N + A + D + R` | 0 (0.00000%) | 0.21% | 4.12% | 96.18% | 23.613870 | 0.000000 |
| Alternative: `(193 + A if bootstrap, else 250) + 74N + D + R` | 0 (0.00000%) | 0.62% | 6.97% | 88.19% | 23.702357 | 0.000000 |
| No address term: `250 + 74N + D + R` | 0 (0.00000%) | 0.62% | 6.97% | 88.19% | 23.702357 | 0.000000 |
| Alt 1: address, policy and name sizes | 0 (0.00000%) | 0.21% | 1.80% | 99.67% | 23.586387 | 0.000000 |
| Alt 2: no reference-script term | 14,257 (96.55289%) | -94.25% | -59.55% | 3.24% | 1.747399 | 69.330660 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 0.06% | 0.55% | 100.00% | 23.555011 | 0.000000 |

### Outputs with six or more native assets, created since the Babbage hard fork

15,013,067 outputs.

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current: `160 + serializedOutputBytes` | – | – | – | – | 6.130877 | – |
| Proposed: `193 + 74N + A + D + R` | 0 (0.00000%) | 91.56% | 248.54% | 0.00% | 14.380178 | 0.000000 |
| Alternative: `(193 + A if bootstrap, else 250) + 74N + D + R` | 0 (0.00000%) | 91.58% | 248.76% | 0.00% | 14.382168 | 0.000000 |
| No address term: `250 + 74N + D + R` | 0 (0.00000%) | 91.58% | 248.76% | 0.00% | 14.380353 | 0.000000 |
| Alt 1: address, policy and name sizes | 17 (0.00011%) | 19.48% | 43.29% | 0.79% | 7.701045 | 2.995450 |
| Alt 2: no reference-script term | 0 (0.00000%) | 91.58% | 248.76% | 0.00% | 14.380353 | 0.000000 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 0.46% | 0.88% | 100.00% | 6.147557 | 0.000000 |

### Conway outputs with six or more native assets

3,210,361 outputs.

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current: `160 + serializedOutputBytes` | – | – | – | – | 6.489228 | – |
| Proposed: `193 + 74N + A + D + R` | 0 (0.00000%) | 80.71% | 245.87% | 0.00% | 14.454884 | 0.000000 |
| Alternative: `(193 + A if bootstrap, else 250) + 74N + D + R` | 0 (0.00000%) | 80.72% | 245.93% | 0.00% | 14.459201 | 0.000000 |
| No address term: `250 + 74N + D + R` | 0 (0.00000%) | 80.70% | 245.93% | 0.00% | 14.454975 | 0.000000 |
| Alt 1: address, policy and name sizes | 0 (0.00000%) | 17.14% | 42.33% | 1.01% | 8.012047 | 0.000000 |
| Alt 2: no reference-script term | 0 (0.00000%) | 80.70% | 245.93% | 0.00% | 14.454975 | 0.000000 |
| Alt 3: fixed ADA width | 0 (0.00000%) | 0.39% | 0.85% | 100.00% | 6.505258 | 0.000000 |

### Proposed formula by native assets, every output

| Native assets | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| None (217,834,833 outputs) | 14,297 (0.00656%) | 11.11% | 12.69% | 1.77% | 1.085952 | 18.231300 |
| One or more (145,473,641 outputs) | 371 (0.00026%) | 20.44% | 134.48% | 0.67% | 3.673579 | 0.435310 |
| Six or more (23,911,793 outputs) | 0 (0.00000%) | 94.45% | 254.97% | 0.00% | 14.097338 | 0.000000 |

### Proposed formula by creation era

| Era | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Genesis (14,505 outputs) | 0 (0.00000%) | 10.79% | 10.79% | 0.00% | 1.017159 | 0.000000 |
| Byron (5,918,937 outputs) | 0 (0.00000%) | 9.34% | 12.91% | 0.00% | 1.136996 | 0.000000 |
| Shelley (1,621,975 outputs) | 0 (0.00000%) | 9.76% | 11.84% | 0.00% | 1.084874 | 0.000000 |
| Allegra (3,592,375 outputs) | 0 (0.00000%) | 10.24% | 11.84% | 0.00% | 1.090324 | 0.000000 |
| Mary (18,891,199 outputs) | 732 (0.00387%) | 11.11% | 20.44% | 0.00% | 1.520883 | 0.181020 |
| Alonzo (103,782,868 outputs) | 5,902 (0.00569%) | 12.69% | 78.52% | 0.00% | 2.189846 | 18.231300 |
| Babbage (143,814,091 outputs) | 8,034 (0.00559%) | 11.55% | 79.31% | 0.84% | 2.369223 | 2.361880 |
| Conway (85,672,524 outputs) | 0 (0.00000%) | 11.11% | 30.82% | 4.22% | 1.888803 | 0.000000 |

### Sensitivity to CBOR wrappers, outputs created since the Babbage hard fork

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| No address term, payload bytes (as specified) | 6,756 (0.00294%) | 13.73% | 61.64% | 2.78% | 2.214510 | 2.361880 |
| No address term, whole fields | 6,727 (0.00293%) | 14.48% | 61.64% | 2.39% | 2.219003 | 2.361880 |
| Alt 1, whole fields (as specified) | 9,422 (0.00411%) | 4.00% | 12.82% | 78.44% | 1.638749 | 2.995450 |
| Alt 1, payload bytes | 988,221 (0.43062%) | 4.00% | 12.80% | 83.19% | 1.634256 | 2.995450 |

### Address terms, outputs created since the Babbage hard fork

229,486,615 outputs.

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current: `160 + serializedOutputBytes` | – | – | – | – | 1.492008 | – |
| No address term: `250 + 74N + D + R` | 6,756 (0.00294%) | 13.73% | 61.64% | 2.78% | 2.214510 | 2.361880 |
| Every address: `250 + 74N + A + D + R` | 234 (0.00010%) | 36.44% | 69.83% | 0.01% | 2.435541 | 2.116210 |
| Every address, rebased (proposed): `193 + 74N + A + D + R` | 8,034 (0.00350%) | 11.11% | 61.64% | 2.10% | 2.189871 | 2.361880 |
| Bootstrap only: `250 + 74N + (A if bootstrap) + D + R` | 6,737 (0.00294%) | 15.43% | 61.68% | 1.49% | 2.220894 | 2.361880 |
| Above 57 bytes: `250 + 74N + max(0, A − 57) + D + R` | 6,755 (0.00294%) | 14.04% | 61.64% | 1.49% | 2.215809 | 2.361880 |
| Bootstrap only, rebased (alternative): `(193 + A if bootstrap, else 250) + 74N + D + R` | 6,755 (0.00294%) | 12.89% | 61.64% | 1.49% | 2.215423 | 2.361880 |

### Address terms, Conway outputs

85,672,524 outputs.

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current: `160 + serializedOutputBytes` | – | – | – | – | 1.432822 | – |
| No address term: `250 + 74N + D + R` | 0 (0.00000%) | 11.11% | 37.29% | 4.42% | 1.912922 | 0.000000 |
| Every address: `250 + 74N + A + D + R` | 0 (0.00000%) | 36.44% | 48.46% | 0.01% | 2.134473 | 0.000000 |
| Every address, rebased (proposed): `193 + 74N + A + D + R` | 0 (0.00000%) | 11.11% | 30.82% | 4.22% | 1.888803 | 0.000000 |
| Bootstrap only: `250 + 74N + (A if bootstrap) + D + R` | 0 (0.00000%) | 11.11% | 38.86% | 3.19% | 1.919600 | 0.000000 |
| Above 57 bytes: `250 + 74N + max(0, A − 57) + D + R` | 0 (0.00000%) | 11.11% | 37.29% | 3.19% | 1.914224 | 0.000000 |
| Bootstrap only, rebased (alternative): `(193 + A if bootstrap, else 250) + 74N + D + R` | 0 (0.00000%) | 11.11% | 37.29% | 3.19% | 1.913745 | 0.000000 |

### Address terms, bootstrap-address outputs created since the Babbage hard fork

5,110,390 outputs.

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current: `160 + serializedOutputBytes` | – | – | – | – | 1.838323 | – |
| No address term: `250 + 74N + D + R` | 20 (0.00039%) | 2.45% | 76.99% | 58.16% | 2.759820 | 0.689600 |
| Every address: `250 + 74N + A + D + R` | 1 (0.00002%) | 33.60% | 79.17% | 0.00% | 3.046494 | 0.362040 |
| Every address, rebased (proposed): `193 + 74N + A + D + R` | 19 (0.00037%) | 10.24% | 77.53% | 0.00% | 2.800824 | 0.607710 |
| Bootstrap only: `250 + 74N + (A if bootstrap) + D + R` | 1 (0.00002%) | 33.60% | 79.17% | 0.00% | 3.046494 | 0.362040 |
| Above 57 bytes: `250 + 74N + max(0, A − 57) + D + R` | 19 (0.00037%) | 10.24% | 77.53% | 0.00% | 2.818170 | 0.607710 |
| Bootstrap only, rebased (alternative): `(193 + A if bootstrap, else 250) + 74N + D + R` | 19 (0.00037%) | 10.24% | 77.53% | 0.00% | 2.800824 | 0.607710 |

### Address terms, every output

363,308,474 outputs.

| Formula | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current: `160 + serializedOutputBytes` | – | – | – | – | 1.432446 | – |
| No address term: `250 + 74N + D + R` | 13,312 (0.00366%) | 12.65% | 63.11% | 5.45% | 2.145522 | 97.026720 |
| Every address: `250 + 74N + A + D + R` | 311 (0.00009%) | 36.44% | 72.01% | 0.01% | 2.367743 | 17.985630 |
| Every address, rebased (proposed): `193 + 74N + A + D + R` | 14,668 (0.00404%) | 11.11% | 62.98% | 1.33% | 2.122073 | 18.231300 |
| Bootstrap only: `250 + 74N + (A if bootstrap) + D + R` | 13,109 (0.00361%) | 17.49% | 63.19% | 0.94% | 2.164474 | 18.110620 |
| Above 57 bytes: `250 + 74N + max(0, A − 57) + D + R` | 13,158 (0.00362%) | 12.82% | 63.13% | 0.94% | 2.149418 | 18.110620 |
| Bootstrap only, rebased (alternative): `(193 + A if bootstrap, else 250) + 74N + D + R` | 13,159 (0.00362%) | 11.15% | 63.13% | 0.94% | 2.148319 | 18.110620 |

## Verification

- **Source:** `mithril-client` verified the snapshot's certificate chain and
  the Merkle proof of its immutable files, as recorded in `mainnet-source.json`.
- **Complete parsing:** every chunk is read to its last byte, and the extractor
  stops on any block or output it does not recognise.
- **Independent scanner:** for chunk `09335`, the block count, transaction
  count, transaction-body bytes and both body checksums in the result match an
  independent Haskell scanner, [ScanBench.hs](ScanBench.hs). Its measurements
  are in [scanner-measurements.json](scanner-measurements.json).
- **Genesis:** the genesis file must hash to mainnet's `ByronGenesisHash`. The
  rebuilt addresses match a ledger golden fixture, and the output count and
  total balance are checked.
- **Rerun:** a rerun from a fresh clone on 12 November 2026 gave identical
  statistics for every formula and group.
- **Address terms:** the runs of 17 November 2026, which added the address
  terms, reproduced every statistic of the earlier formulas in every group,
  including the recorded outputs.
- **Six-or-more groups:** the run of 19 November 2026, which added the groups
  of outputs with six or more native assets created since the Babbage hard
  fork and in the Conway era, reproduced every statistic of the earlier groups,
  including the recorded outputs.

## Reproduction

You need Python 3.11 or later, with no other packages, and about 233 GB of
chain data. With 30 workers, the run takes about 35 minutes.

1. Clone this repository, check out the commit you are reading, and fetch the
   ledger submodule, whose test fixtures the genesis step reads:

   ```sh
   git clone https://github.com/willjgould/cardano-minutxo-integration.git
   cd cardano-minutxo-integration
   git checkout <commit>
   git submodule update --init cardano-ledger-specs
   ```

2. Get chunks `00000`–`09335` of the mainnet immutable database, either by
   downloading the snapshot recorded in `mainnet-source.json` with
   [`mithril-client`](https://mithril.network/doc/manual/developer-docs/nodes/mithril-client/),
   or from a synced mainnet node. Compare each chunk's SHA-256 with
   `chunks[].sha256` in `history-formulas.json`, and set `IMMUTABLE_DB` to the
   directory that holds the chunks.
3. Download the
   [mainnet Byron genesis file](https://book.play.dev.cardano.org/environments/mainnet/byron-genesis.json)
   as `mainnet-byron-genesis.json`. The genesis step checks its hash.
4. Run the backtest, then print its tables:

   ```sh
   python3 docs/minutxo-calibration/backtest_history.py \
     --source "$IMMUTABLE_DB" --last-chunk 9335 \
     --genesis mainnet-byron-genesis.json \
     --work-dir backtest-work --result backtest-result.json --workers 30
   python3 docs/minutxo-calibration/report_history.py backtest-result.json
   ```

The printed tables should match the results above. Timings and file paths in
the result file will differ.
