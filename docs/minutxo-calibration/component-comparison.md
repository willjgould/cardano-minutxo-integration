# Where the excess comes from, and useful additional inputs

Analysis dated 5 November 2026, using the same 488,149 mainnet output
creations as the [formula comparison](formula-comparison.md). The byte price
is 4,310 lovelace. These are measurements on authenticated historical output
creations, not a live UTxO census or ledger conformance test.

The uniform per-asset coefficient compresses several different costs into one
number. Keeping a little more information substantially improves closeness.
The most useful candidate measured here is:

```text
p * (175 + A + 12*N + 30*P + L + D + R)
```

It had zero observed misses, median excess 4.00%, and 95th-percentile excess
6.10%. 91.01% of outputs were within 5% above the old minimum; 97.80% were
within 10%. The held-out 166,645 outputs also had zero misses.

Definitions:

- `N`: distinct non-ADA `(policy ID, asset name)` pairs, independent of quantities.
- `P`: distinct policy IDs in the output.
- `L`: sum of raw asset-name byte lengths across those pairs. Equal names under
  different policies count separately, because CBOR repeats them.
- `A`: complete encoded address field, including its output-map key if present.
- `D`, `R`: complete encoded datum/script fields, including keys and wrappers.
- `p`: `coinsPerUTxOByte`.

## Sources of the differences

**Fixed base allowance.** The old rule charges 160 bytes of UTxO-entry overhead
plus the whole encoded output. Addresses, ADA amounts and container headers
are additional. The earlier 250-byte base reserves 90 bytes for this material,
enough for the largest observed zero-token bootstrap output. Enterprise and
ordinary base addresses are shorter. Counting ADA once in the user's formula
adds a fixed 72-byte allowance; it never means charging by ADA quantity.

**Repeated policy allowance.** A 74-byte asset allowance assumes each asset has
its own 30-byte encoded policy ID. A bundle with N assets and P policies pays
that cost only P times. Replacing `74*N` with `44*N + 30*P` saves exactly
`30*(N-P)` bytes. Ten assets under one policy save 270 bytes, or 1.1637 ADA at
the comparison price, relative to the original bound.

**Maximum asset-name allowance.** The count-only formula reserves 32 payload
bytes for every name. Replacing those allowances with their actual summed
length L saves `32*N-L` bytes. A two-byte name rather than a 32-byte name
reduces the bound by 30 bytes, or 0.1293 ADA, per asset.

**Maximum integer widths.** Coin and token quantities use one, two, three,
five or nine CBOR bytes. Reserving nine removes amount-dependent size changes
from the formula, but a token quantity of one needs only one byte. The excess
can be eight bytes, or 0.03448 ADA, per token quantity. This explains much of
the remaining excess in large bundles even after measuring policies/names.

**Container headers and wrappers.** Datum hashes, inline data and reference
scripts have different wrappers. Their sizes must include those wrappers or
charge them separately. Value and policy-map headers also change at CBOR
thresholds. Bounding each policy's inner map header by its asset count is
simple but loose when many assets share a policy.

The coefficient difference between 72 and 74 is comparatively small: two
bytes, or 0.00862 ADA per asset. 72 bounds the compact in-memory asset payload;
74 bounds a worst-case CBOR asset entry. Neither coefficient alone supplies
the omitted base-output bytes.

## Measured refinements

All first four expressions below are multiplied by p and include full D/R
fields. All six rows had zero observed underestimates in the sample and holdout.

| Information used | Formula or size treatment | Median excess | 95th-percentile excess | Mean requirement |
| --- | --- | ---: | ---: | ---: |
| Asset count | `250 + 74*N + D + R` | 11.11% | 36.61% | 1.88067 ADA |
| Add policy count | `250 + 44*N + 30*P + D + R` | 11.11% | 36.59% | 1.79481 ADA |
| Add name lengths | `250 + 12*N + 30*P + L + D + R` | 11.11% | 26.90% | 1.62826 ADA |
| Measure address | `175 + A + 12*N + 30*P + L + D + R` | **4.00%** | **6.10%** | 1.53183 ADA |
| Exact other structure; reserve nine bytes for every amount | See below | 1.78% | 4.58% | 1.50521 ADA |
| Exact other structure and token quantities; reserve nine bytes for ADA | See below | 1.49% | 2.03% | 1.46221 ADA |

The old mean is 1.44802 ADA. Across all sampled output creations, the sequential
mean savings are 0.08586 ADA from policy sharing, 0.16655 ADA from name lengths,
and 0.09643 ADA from replacing the fixed base allowance with the address field.
These savings are additive steps in this comparison, not independent estimates.

The unchanged medians in the first three rows reflect the majority of outputs
having no native assets. Policy counting matters more in the tail: among
outputs with six or more native assets, the 95th-percentile excess falls from
213.34% to 115.61% by adding P, and to 40.12% by then adding L. Measuring the
address lowers it further to 39.06%. Maximum quantity widths and loose inner
map-header allowances remain material for these bundles.

## Why the improved expression is a bound within its encoding scope

For minimal-width encoding, each policy ID needs 30 bytes. Each asset has a
name of length l with at most two header bytes, and a quantity of at most nine
bytes. A nonempty inner-map header occupies at most as many bytes as the map
has entries. Thus:

```text
asset material <= 30*P + L + 2*N + 9*N + N
               = 30*P + L + 12*N
```

The 175 base consists of the old 160 overhead plus up to 15 bytes for the output
header, value map key, value-pair header, nine-byte ADA amount and three-byte
outer policy-map header. The ledger's compact-value limits keep that policy
count within the three-byte header range. Address and data/script fields are
paid separately through their actual encoded contributions.

This covers variable address lengths, including bootstrap addresses, without
using the largest observed address as a constant. The bound assumes minimal
Value/container/name encoding; received nonminimal encodings can still be
larger. Measuring A/D/R does not account for inflation inside Value. A universal
comparison against the old accepted-byte rule must handle that explicitly.

## Further tightening and tradeoffs

Instead of bounding container headers, calculate their small integer widths
from the map counts. If h(k) is the CBOR header width, inner-policy headers
cost `sum(h(assetsUnderPolicy))`; name headers cost `sum(h(nameLength))`.
No complete output serialization is needed to calculate these standard sizes.
This adds a few threshold calculations, rather than more governance parameters.

The last two measured rows retain the actual received structure and replace
integer widths with their maxima:

```text
fixed all amounts = p * (160 + outputBytes - coinBytes - quantityBytes
                        + 9*(N+1))
fixed ADA only   = p * (160 + outputBytes - coinBytes + 9)
```

These are precision references. A structural-size implementation could compute
the noninteger contributions directly; the experiment obtains them by
subtracting the recorded integer spans. The first remains independent of ADA
and token quantities. The second retains token-quantity width dependence and
removes only ADA/minimum feedback. In this sample the ADA-only version's
excess was 0–17,240 lovelace; across arbitrary valid uint64 amounts its width
margin is at most 34,480 lovelace at the comparison price. Retaining actual
received noninteger spans also retains their nonminimal encoding overhead.

For a compact formula, start with P, L and A while retaining maximum quantity
widths. If the goal is only to avoid iterating over the ADA amount, the final
variant is more precise. These choices concern per-output measurements;
the byte price p can remain the sole adjustable pricing parameter.

## Reproduction

Set `IMMUTABLE_DB` to the `immutable` directory of the
[Mithril-certified mainnet snapshot](mainnet-source.json) (chunks `00000`–`09335`).

```sh
python3 docs/minutxo-calibration/compare_components.py \
  --source "$IMMUTABLE_DB" \
  --result docs/minutxo-calibration/component-comparison.json
```

The [script](compare_components.py) checks chunk hashes/counts/checksums against
the prior sample. The [results](component-comparison.json) contain subgroup and
holdout statistics, script hashes and extreme-output witnesses. The baseline
row matches the previous comparison exactly. No ledger formula was modified.
