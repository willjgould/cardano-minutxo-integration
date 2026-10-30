**Historical minUTxO migration: node cost analysis**

29 October 2026. Scope: populate the original, creation-time minimum ADA amount for surviving legacy outputs, so a new Plutus interface can expose it. This is metadata: it does not move ADA, add money to the deposit store, or require owners to spend their outputs. The new size-independent formula is a separate change.

**Assessment.** This is a feasible historical-data migration, with a potentially significant one-time scan and a persistent storage cost that depends heavily on representation. A full ledger replay is a correctness reference and fallback, not an unavoidable implementation. The cheapest credible general approach is a targeted scan of locally stored, already-validated history against the live UTxO set. On the observed mainnet data volume, a scanner sustaining 25–50 MB/s end to end would spend approximately **1.3–2.6 hours scanning**, before final writing/verification and catch-up. Those rates are explicit assumptions, not a measured migration forecast. An eight-byte-per-output estimate is only realistic for a carefully integrated layout: measured separate-map layouts extrapolate to **0.70–1.39 GB of additional live heap**, versus **87 MB** for an inline word or **261 MB** for a wrapper preserving the existing output object.

No full mainnet ChainDB was available in this workspace. I measured memory layouts at one and two million entries and a decoder/hash component on a real mainnet chunk. I did not run a full migration, cold-disk scan, live-node contention test, or full historical replay. The raw observations, benchmark sources and reproducible arithmetic are in [the accompanying directory](minutxo-migration-cost/measurements.json). Existing ledger and node implementation files were not changed.

**Data volume and historical scope.**

| Input | Observation | Use in this analysis |
|---|---:|---|
| Live UTxOs | 10,886,508 | Sum of the CardanoScope distribution snapshot dated 23 October 2026; an external observation, not a locally validated UTxO snapshot. |
| Mainnet database, uncompressed | 237,045,302,990 bytes | Official Mithril snapshot dated 29 October 2026, 09:58 UTC, node 11.1.3. |
| Ancillary files | 2,542,843,171 bytes | Subtracted from the total to form a history-volume proxy. |
| History-volume proxy | 234,502,459,819 bytes, or 234.50 GB | Includes immutable indexes; a specialised scanner need not read every one of these bytes. |
| Observed chain height | 14,131,629 | Koios tip later on 29 October; not exactly the Mithril snapshot point. |

Sources: [UTxO distribution](https://cardanoscope.com/api/onchain/utxo-distribution), [specific Mithril snapshot](https://aggregator.release-mainnet.api.mithril.network/aggregator/artifact/cardano-database/9f765025d358c8ed18d4b2dd0e8ae94c1f37d5f1b1eb773f481a8d57d6312948), [Mithril API definitions](https://mithril.network/doc/aggregator-api/current/). Snapshot dates differ by six days. These observations are adequate for a scale model, but are not a cryptographically verified migration input; I did not verify the Mithril certificate chain.

I queried all 457 Shelley-to-current epoch parameter records, epochs 208–664, and found the following regimes. The price parameter did not change within any of these eras in that response:

| Epochs | Era | Relevant parameter |
|---|---|---|
| 208–235 | Shelley | `minUTxOValue = 1,000,000` lovelace |
| 236–250 | Allegra | `minUTxOValue = 1,000,000` lovelace |
| 251–289 | Mary | `minUTxOValue = 1,000,000` lovelace, with the Mary token-bundle formula |
| 290–364 | Alonzo | `coinsPerUTxOWord = 34,482` lovelace |
| 365–506 | Babbage | `coinsPerUTxOByte = 4,310` lovelace |
| 507–664 | Conway | `coinsPerUTxOByte = 4,310` lovelace |

Source: [Koios epoch parameter query](https://api.koios.rest/api/v1/epoch_params?select=epoch_no,era,min_utxo_value,coins_per_utxo_size&order=epoch_no.asc&limit=1000); the complete response is retained in `measurements.json`. The formulas and unit changes are documented in [CIP-55](https://cips.cardano.org/cip/CIP-0055).

This is useful: the historical parameter table is tiny. A mainnet-specific, independently checked table could be part of the migration specification, avoiding replay of parameter-update governance on every node. A production migration cannot simply trust the research API response. A general solution for other networks or future parameter changes would need its own verified timeline. Finding which historical output is being priced, and recovering its accepted encoding where necessary, remains the large task.

The earlier estimate of roughly 3.1 million surviving pre-Babbage outputs is not the complete migration workload. Babbage/Conway outputs can require their original accepted byte length even though the byte-price parameter stayed constant. Decoding and re-encoding can change the length. Nor are current storage-era tags universally creation-era tags: snapshot decoding and table upgrades can retag old outputs. An era-only fast path must prove both provenance and sufficient original sizing information. See [original size handling](../cardano-ledger-specs/libs/cardano-ledger-binary/src/Cardano/Ledger/Binary/Decoding/Sized.hs), [snapshot decoding](../ouroboros-consensus/ouroboros-consensus-cardano/src/ouroboros-consensus-cardano/Ouroboros/Consensus/Cardano/Ledger.hs), and [table upgrading](../ouroboros-consensus/ouroboros-consensus/src/ouroboros-consensus/Ouroboros/Consensus/HardFork/Combinator/Ledger.hs).

**What a migration would actually do.**

| Approach | Work | Trade-off |
|---|---|---|
| Full ledger replay with minimum tracking | Reapply accepted blocks and maintain the new metadata alongside normal historical state. | Reuses the ledger's handling of protocol changes, invalid transactions and collateral. Also repeats state work for outputs long since spent. |
| Targeted historical scan | Freeze the live output-reference set at a stable point; scan original transaction bodies, identify matches and price only relevant outputs. | Avoids reconstructing every past UTxO state. Requires a verified parameter timeline and a careful scanner. This is the preferred candidate to prototype. |
| Use an existing historical index | Locate original transactions directly and calculate the live outputs' minima. | Potentially less scanning, but ordinary node state does not guarantee such an index. Building it from scratch is another migration task. |

For the targeted scan:

1. Take the live UTxO set at a stable, validated chain point, and group references by transaction ID.
2. Stream local history. Hash original transaction bodies and check membership in the target set. Avoid materialising full witnesses and non-target ledger outputs where possible.
3. For matching outputs, use the block's actual era, the verified parameter regime and the original output data/byte length. Retain results only for the live targets.
4. Bind the result to the chosen chain point, then process later creations/spends and any permitted rollbacks until activation.
5. Persist metadata in the supported ledger snapshot/database formats and verify its coverage before enabling the new script-context semantics.

For history bytes B, historical transactions T and live outputs U, this is approximately O(B + T log U + target asset work) with a balanced lookup tree, or expected O(B + T + target asset work) with a suitable hash index. Result storage is O(U), not O(every output ever created). The target index and result may share keys or use compact ordinals; holding two independent full maps unnecessarily increases peak memory.

A backwards scan can stop when every target is found. Old survivors may still require almost the full relevant history. If Byron/genesis cases are assigned a defined value by the specification, they might be handled separately and some early history skipped. The 234.50 GB model intentionally does not assume this optimisation.

Existing consensus replay distinguishes reapplication of already-validated blocks from fresh validation; the former skips signature and Plutus checks. A local migration therefore does not inherently require a fresh network download or rerunning historical scripts. See the `ValidateNone` policy in [the consensus replay interface](../ouroboros-consensus/ouroboros-consensus/src/ouroboros-consensus/Ouroboros/Consensus/Ledger/Abstract.hs) and [replay documentation](https://ouroboros-consensus.cardano.intersectmbo.org/docs/tutorials/preflight_guide/#reusing-ledger-snapshots).

**Measured scanner component, not measured migration throughput.**

I downloaded one small recent immutable archive from the official Mithril location. Its chunk contains 8,524,491 bytes, 1,062 Conway blocks and 8,267 transaction bodies. The standalone benchmark consumed every byte, identified original transaction-body spans and optionally hashed them using Blake2b-256. Seven warm repetitions on one thread of a Ryzen 9 9950X3D, with GHC 9.6.7, gave:

| Measured operation | Median throughput | Range |
|---|---:|---:|
| CBOR structural traversal | 368.5 MB/s | 362.2–383.4 MB/s |
| Traversal plus transaction-body hashing | 256.8 MB/s | 255.1–259.7 MB/s |

Peak process RSS was about 23 MB. These measurements exclude cold disk reads, a full live-UTxO lookup structure, ledger-value decoding, minimum calculation, output-creation validity handling, metadata writes and catch-up. The recent chunk is small enough to benefit from CPU caches and is not a representative sample of every era. The benchmark is a structural parser, not the ledger's decoder or a valid migration implementation. Its rate must not be presented as the achievable full-chain migration rate.

**Elapsed-time sensitivity.**

Let q be sustained end-to-end history-processing throughput, including reading, decoding, body hashing, target lookup and pricing. Using the observed volume proxy:

`migration time ≈ 234,502,459,819 / q + final output/verification + catch-up`

The final terms are added only to the extent they were not already included in a measured q. If execution is staged rather than pipelined, separately measured stage durations should be added; raw SSD bandwidth alone is insufficient.

| Assumed effective processing rate | History-processing time |
|---|---:|
| 5 MB/s | 13.03 hours |
| 10 MB/s | 6.51 hours |
| 25 MB/s | 2.61 hours |
| 50 MB/s | 1.30 hours |
| 100 MB/s | 39.1 minutes |
| 250 MB/s | 15.6 minutes |

This is a sensitivity table, not a confidence interval. I would use the 25–50 MB/s rows as explicit planning scenarios to test, and include a throttled 5–10 MB/s case for preparation alongside a running node. I have not established that representative operators will achieve any particular row. Node hardware, cache behaviour, lookup representation, competing load and database backend can change the result materially.

There is a real but dated comparison: the [Consensus Team's January 2023 replay benchmark](https://updates.cardano.intersectmbo.org/2023-01-11-consensus/) plotted roughly eight million blocks replayed in about 1.8 hours for its baseline, 2.8 hours for its in-memory UTxO-HD prototype and 3.3 hours for LMDB. Those durations are approximate readings of the published graph; hardware was not specified. They establish that hours-scale replay has been observed, not a 2026 forecast. Scaling them by today's block count would ignore changes in ledger size, transaction mix and implementation.

**Measured persistent-memory choices.**

I constructed synthetic Haskell structures at one and two million entries, forced them, kept them live across a major GC and measured retained bytes. The key layout follows the checkout: a 32-byte packed hash plus output index. The principal map modes use a small `Integer`, as `Coin` does; inline and wrapper amounts use an unpacked `Word64`. The same per-entry slopes appeared at both scales.

| Representation | Measured additional live bytes/output | Extrapolated additional live heap at 10,886,508 outputs |
|---|---:|---:|
| Add an unpacked amount to an existing allocated constructor | 8 | 87.1 MB / 83.1 MiB |
| Wrap the existing output object with an unpacked amount | 24 | 261.3 MB / 249.2 MiB |
| Additional map sharing complete keys with an existing map | 64 | 696.7 MB / 664.5 MiB |
| Separate map with separately allocated keys | 128 | 1,393.5 MB / 1,328.9 MiB |

These are measured layout slopes multiplied by the observed UTxO count, not measured real-node RAM. Actual transaction hashes can be shared among multiple output keys; GC, rollback versions, snapshots, node baseline memory and database caches are not included. Shared keys must remain shared after loading snapshots to retain that saving. A boxed `Word64` in `Map` had the same footprint as the small `Integer`; changing the numeric type alone did not achieve eight bytes per entry.

The eight-byte result requires extending an existing allocation. A wrapper is a more realistic alternative when retaining the existing output object. A packed vector also measured eight bytes per amount but has no output-identifier index, so it is not a complete solution by itself. Any internal wrapper or metadata table must preserve transaction/output wire encodings; altering signed historical output encodings is not the migration being analysed.

Temporary memory matters. At two million entries, the independently allocated map retained about 256 MB but the process peaked at about 535 MB RSS. The shared-key experiment's process peaked around 729 MB including its baseline map. These demonstrate temporary/GC overhead, not a multiplier to apply blindly to a production node. An online backfill should avoid duplicating the entire decoded UTxO and should measure peak memory while both old and new state are present.

**Persistent disk and ongoing cost.**

For amounts from 65,536 through 4,294,967,295 lovelace, the encoded unsigned CBOR integer is five bytes: about 54.4 MB across the observed UTxO count if each amount falls in that range. Smaller amounts use fewer bytes. A standalone CBOR map with keys `[32-byte TxId, small output index]` and a five-byte amount is approximately 41 bytes per entry, or 446.3 MB, before database/version overhead or compression. These are encoding illustrations, not a chosen implementation or measured snapshot format. Multiple retained snapshots and LSM compaction/write amplification can increase disk use. The 2.54 GB Mithril ancillary total is not a precise measure of the UTxO snapshot itself.

An in-place read of existing history does not require another 234 GB copy. Extra disk is principally the result, checkpoints and temporary indexing/sorting data; the peak depends on the chosen algorithm. A node without retained history would need an additional recovery/distribution route, which is outside the local-full-node timing model.

After migration, context construction reads one recorded amount for each relevant spending/reference input. Newly created outputs already undergo minimum validation; recording its result adds state maintenance. Consumed legacy entries can be removed. If only explicit outputs are created after activation, the legacy metadata population shrinks as old outputs are spent. If new implicit outputs remain permitted, they must also receive metadata to preserve the same interface promise. Additional script-context size/evaluation cost needs a separate benchmark once the interface encoding is fixed.

**Preparation and consensus constraints.**

Release software that can prepare the metadata before activation. It should checkpoint progress, run with controllable resource use, catch up with the chain, and validate its coverage against the live UTxO at a stable point. Activation should consume already-prepared data rather than synchronously scan years of history. This moves work ahead of the boundary; it does not remove CPU/I/O contention or the requirement for late/upgrading nodes to obtain correct metadata.

Three details are necessary for correctness and must appear in the migration benchmark: phase-two-invalid transactions do not create their ordinary outputs; collateral-return outputs have special indexing; and genesis/Byron cases need explicitly defined semantics where no Shelley-style minimum was imposed. Contexts must not invent a historical amount when reconstruction cannot establish one. This metadata must never be added to the monetary deposit-store balance.

The metadata must be deterministically derived from accepted history or obtained through a specified, verifiable state-distribution mechanism. It cannot be optional explorer data that influences script evaluation. Its state format, chain-point binding, rollback behaviour and snapshots are part of the implementation work. A historical index or external snapshot does not erase that obligation.

There is precedent for added historical accounting: [node 8.0.0](https://github.com/IntersectMBO/cardano-node/releases/tag/8.0.0) shipped individual stake/pool deposit tracking. The [Q1 2023 ledger report](https://updates.cardano.intersectmbo.org/quarterly/2023-04-03-ledger/) says retroactive application was possible because those deposit parameters had never changed; the [January implementation report](https://updates.cardano.intersectmbo.org/2023-01-05-ledger/) measured eight extra bytes per stake credential. This supports feasibility of new tracking, but is not a benchmark or exact precedent for recovering heterogeneous minUTxO history.

**What remains to turn the model into a deployment estimate.**

The next useful measurement is one candidate scanner over a real local mainnet ChainDB and a live UTxO snapshot, with independently verified parameter regimes. Measure end-to-end bytes/second, peak incremental RSS, metadata size, checkpoint/restart time, and the effect on block processing. Run both an in-memory and disk-backed case on representative operator hardware. Compare all records against a reference replay, or build a correctness argument plus targeted cross-era checks before claiming exact reconstruction. Include cold-cache runs, asset-heavy historical regions, invalid transactions, collateral returns, snapshot reload and rollback/catch-up. This is necessary validation of the migration itself; none of the component benchmarks here establishes those properties.

The current evidence supports planning a one-time scan whose duration is sensitive to implementation and hardware, and choosing storage deliberately before committing to a per-output map. It does not support treating the task as either a negligible field addition or an unavoidable multi-day full resynchronisation.

**Reproducing the calculations and component measurements.**

`python3 docs/minutxo-migration-cost/model.py` prints [the calculated tables](minutxo-migration-cost/model-results.json) from [recorded observations](minutxo-migration-cost/measurements.json). Redirect its output to `docs/minutxo-migration-cost/model-results.json` to regenerate that file. The assertions check the parameter-record coverage and basic model consistency; this is not a ledger test suite.

The [memory benchmark](minutxo-migration-cost/MemoryBench.hs) uses only `base`, `containers`, `vector` and related standard dependencies already available in the declared environment. Compile in a temporary directory with GHC 9.6.7 using `-O2 -threaded -rtsopts`; run each mode at 1,000,000 and 2,000,000 entries with `+RTS -T -s -N1`. Modes are `map-unit`, `map-integer`, `map-word64`, `map-base-value`, `map-inline-word64`, `map-wrapper-word64`, `map-shared-keys-integer` and `vector-word64`. Measurements include one run per configuration; timing is observational, without CPU pinning or a controlled otherwise-idle host.

The [scanner component](minutxo-migration-cost/ScanBench.hs) uses `cborg`, `crypton` and byte-string packages. Compile with `-O2 -fno-full-laziness -fno-cse -rtsopts`; run against the extracted `09335.chunk` with argument `7` for seven repetitions. The [source archive](https://storage.googleapis.com/cdn.aggregator.release-mainnet.api.mithril.network/cardano-database/immutable/09335.tar.zst) is about 3 MB compressed. The chunk SHA-256 is `fd1f5a92ff78f17cae851c591973a73d4a1ce51ff8439e5da3f472cf9f0bd81c`. The benchmark only supports Conway framing and deliberately fails for other era tags. Source revisions, compiler/runtime settings, raw runs and RTS logs are retained in the measurement bundle.
