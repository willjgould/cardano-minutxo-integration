#!/usr/bin/env python3
"""Stream the CIP formula and its alternatives over authenticated historical block chunks.

Datum and reference-script terms count payload bytes only (the hash inputs),
as the CIP specifies. Two controls keep the 6 November whole-field
measurements so this run can be checked against that earlier result.

No ledger rule is changed. The common benchmark is 160 plus each output's
original received byte length; before Babbage this is counterfactual, not the
minimum that was required when the output was created. Invalid transactions
and era-specific output extraction are handled by extract_history.scan_chunk.

Each chunk has an atomic, resumable checkpoint. All script/configuration and
source-inventory identities must match before resuming, and reused chunks are
rehash-checked. Failed extraction never produces a successful chunk checkpoint.
Percentile intervals for percentage excess have width 0.01 percentage points;
counts, integer-byte delta histograms, and percentile ranks are exact.
"""

import argparse
from collections import Counter
from concurrent.futures import FIRST_COMPLETED, ProcessPoolExecutor, wait
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import time
import traceback


SCHEMA_VERSION = 2
FORMULAS = {
    "cip": "coinsPerUTxOByte * (250 + 74 * numberOfNativeAssets + serializedDatumBytes + serializedReferenceScriptBytes)",
    "alternative_policy_address": "coinsPerUTxOByte * (175 + serializedAddressFieldBytes + 12 * numberOfNativeAssets + 30 * numberOfMintingPolicies + totalAssetNameBytes + serializedDatumBytes + serializedReferenceScriptBytes)",
    "alternative_datum_only": "coinsPerUTxOByte * (250 + 74 * numberOfNativeAssets + serializedDatumBytes)",
    "alternative_fixed_ada_width": "coinsPerUTxOByte * (160 + serializedOutputBytes - serializedAdaAmountBytes + 9)",
    "control_cip_whole_fields": "coinsPerUTxOByte * (250 + 74 * numberOfNativeAssets + serializedDatumFieldBytes + serializedReferenceScriptFieldBytes)",
    "control_policy_address_whole_fields": "coinsPerUTxOByte * (175 + serializedAddressFieldBytes + 12 * numberOfNativeAssets + 30 * numberOfMintingPolicies + totalAssetNameBytes + serializedDatumFieldBytes + serializedReferenceScriptFieldBytes)",
}
QUANTILES = (("p05", 5), ("p50", 50), ("p95", 95), ("p99", 99))
WITNESS_COUNT = 5


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(json_bytes(value))
    temporary.replace(path)


def file_sha256(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def inventory_entry(path):
    stat = path.stat()
    return {"name": path.name, "bytes": stat.st_size, "mtime_ns": stat.st_mtime_ns}


def witness_key(witness):
    row = witness["output"]
    return (witness["signed_delta_bytes"], witness["signed_delta_percent"],
            row["chunk"], row.get("txid") or row.get("raw_transaction_body_hash")
            or row.get("source_identifier", ""), row["output_index"])


class Statistics:
    def __init__(self, witnesses=False):
        self.witnesses = witnesses
        self.outputs = self.below = self.equal = self.above = 0
        self.within_5 = self.within_10 = self.within_5_either = 0
        self.old_sum = self.delta_sum = 0
        self.percent_sum = 0.0
        self.min_percent = self.max_percent = None
        self.delta_hist = Counter()
        self.percent_hist = Counter()
        self.under_witnesses = []
        self.over_witnesses = []
        self.minimum_witness = self.maximum_witness = None

    def add(self, baseline, delta, percent, percent_bin, row):
        self.outputs += 1
        self.below += delta < 0
        self.equal += delta == 0
        self.above += delta > 0
        # Integer comparisons keep the inclusive boundaries exact.
        self.within_5 += 0 <= 100 * delta <= 5 * baseline
        self.within_10 += 0 <= 100 * delta <= 10 * baseline
        self.within_5_either += -5 * baseline <= 100 * delta <= 5 * baseline
        self.old_sum += baseline
        self.delta_sum += delta
        self.percent_sum += percent
        self.min_percent = percent if self.min_percent is None else min(self.min_percent, percent)
        self.max_percent = percent if self.max_percent is None else max(self.max_percent, percent)
        self.delta_hist[delta] += 1
        self.percent_hist[percent_bin] += 1
        if not self.witnesses:
            return
        candidate_key = (delta, percent, row["chunk"], row.get("txid")
                         or row.get("raw_transaction_body_hash")
                         or row.get("source_identifier", ""), row["output_index"])
        is_minimum = self.minimum_witness is None or candidate_key < witness_key(self.minimum_witness)
        is_maximum = self.maximum_witness is None or candidate_key > witness_key(self.maximum_witness)
        is_under = delta < 0 and (len(self.under_witnesses) < WITNESS_COUNT or
                                 candidate_key < witness_key(self.under_witnesses[-1]))
        is_over = delta > 0 and (len(self.over_witnesses) < WITNESS_COUNT or
                                candidate_key > witness_key(self.over_witnesses[-1]))
        if not (is_minimum or is_maximum or is_under or is_over):
            return
        witness = {"old_bytes": baseline, "new_bytes": baseline + delta,
                   "signed_delta_bytes": delta, "signed_delta_percent": percent,
                   "output": row.copy()}
        if is_minimum:
            self.minimum_witness = witness
        if is_maximum:
            self.maximum_witness = witness
        if is_under:
            self.under_witnesses = sorted(self.under_witnesses + [witness], key=witness_key)[:WITNESS_COUNT]
        if is_over:
            self.over_witnesses = sorted(self.over_witnesses + [witness], key=witness_key, reverse=True)[:WITNESS_COUNT]

    def merge(self, other):
        for field in ("outputs", "below", "equal", "above", "within_5", "within_10",
                      "within_5_either", "old_sum", "delta_sum", "percent_sum"):
            setattr(self, field, getattr(self, field) + getattr(other, field))
        if other.outputs:
            self.min_percent = other.min_percent if self.min_percent is None else min(self.min_percent, other.min_percent)
            self.max_percent = other.max_percent if self.max_percent is None else max(self.max_percent, other.max_percent)
        self.delta_hist.update(other.delta_hist)
        self.percent_hist.update(other.percent_hist)
        if self.witnesses:
            self.under_witnesses = sorted(self.under_witnesses + other.under_witnesses, key=witness_key)[:WITNESS_COUNT]
            self.over_witnesses = sorted(self.over_witnesses + other.over_witnesses, key=witness_key, reverse=True)[:WITNESS_COUNT]
            minima = [w for w in (self.minimum_witness, other.minimum_witness) if w is not None]
            maxima = [w for w in (self.maximum_witness, other.maximum_witness) if w is not None]
            self.minimum_witness = min(minima, key=witness_key) if minima else None
            self.maximum_witness = max(maxima, key=witness_key) if maxima else None

    def dump(self):
        result = self.__dict__.copy()
        result["delta_hist"] = dict(self.delta_hist)
        result["percent_hist"] = dict(self.percent_hist)
        return result

    @classmethod
    def restore(cls, data):
        result = cls()
        result.__dict__.update(data)
        result.delta_hist = Counter({int(k): v for k, v in data["delta_hist"].items()})
        result.percent_hist = Counter({int(k): v for k, v in data["percent_hist"].items()})
        if sum(result.delta_hist.values()) != result.outputs or sum(result.percent_hist.values()) != result.outputs:
            raise ValueError("Corrupt histogram counts in chunk checkpoint")
        if result.below + result.equal + result.above != result.outputs:
            raise ValueError("Corrupt output counts in chunk checkpoint")
        return result

    def summary(self, price):
        if not self.outputs:
            return {"outputs": 0}
        delta_quantiles = histogram_quantiles(self.delta_hist, self.outputs)
        percent_quantiles = histogram_quantiles(self.percent_hist, self.outputs)
        result = {
            "outputs": self.outputs, "below_old": self.below, "equal_old": self.equal,
            "above_old": self.above, "below_old_percent": 100 * self.below / self.outputs,
            "within_5_percent_above": self.within_5,
            "within_10_percent_above": self.within_10,
            "within_5_percent_either_side": self.within_5_either,
            "within_5_percent_above_percent": 100 * self.within_5 / self.outputs,
            "within_10_percent_above_percent": 100 * self.within_10 / self.outputs,
            "sum_old_lovelace": price * self.old_sum,
            "sum_new_lovelace": price * (self.old_sum + self.delta_sum),
            "sum_signed_delta_lovelace": price * self.delta_sum,
            "mean_old_lovelace": price * self.old_sum / self.outputs,
            "mean_new_lovelace": price * (self.old_sum + self.delta_sum) / self.outputs,
            "mean_signed_delta_lovelace": price * self.delta_sum / self.outputs,
            "mean_signed_delta_percent": self.percent_sum / self.outputs,
            "aggregate_signed_change_percent": 100 * self.delta_sum / self.old_sum,
            "signed_delta_bytes": delta_quantiles,
            "signed_delta_lovelace": {k: price * v for k, v in delta_quantiles.items()},
            "signed_delta_percent": {
                "min": self.min_percent, "max": self.max_percent,
                **{key: {"lower_inclusive": value / 100,
                         "upper_exclusive": (value + 1) / 100}
                   for key, value in percent_quantiles.items() if key not in ("min", "max")}},
        }
        if self.witnesses:
            result.update({"minimum_delta_witness": self.minimum_witness,
                           "maximum_delta_witness": self.maximum_witness,
                           "most_underestimated_outputs": self.under_witnesses,
                           "most_overestimated_outputs": self.over_witnesses})
        return result


def histogram_quantiles(histogram, count):
    if count == 0 or sum(histogram.values()) != count:
        raise ValueError("Invalid histogram population")
    ordered = sorted(histogram.items())
    ranks = [(name, (count * percentile + 99) // 100) for name, percentile in QUANTILES]
    result = {"min": ordered[0][0], "max": ordered[-1][0]}
    cumulative = 0
    index = 0
    for value, frequency in ordered:
        cumulative += frequency
        while index < len(ranks) and cumulative >= ranks[index][1]:
            result[ranks[index][0]] = value
            index += 1
    if index != len(ranks):
        raise ValueError("Unresolved percentile rank")
    return result


def group_names(row):
    yield "era/" + row["era"]
    yield "address/" + row["address_type"]
    assets = row["num_assets"]
    yield "assets/none" if assets == 0 else "assets/native"
    if assets >= 6:
        yield "assets/six_or_more"
    if row["has_reference_script"]:
        yield "payload/reference_script"
    if row["datum_type"] != "none":
        yield "payload/" + row["datum_type"] + "_datum"
    elif not row["has_reference_script"]:
        yield "payload/plain"
    for diagnostic in ("discarded_asset_entries", "zero_quantity_entries", "empty_policy_entries"):
        if row.get(diagnostic, 0):
            yield "encoding/" + diagnostic
    if row.get("duplicate_policy_entries", 0) or row.get("duplicate_asset_entries", 0):
        yield "encoding/duplicate_entries"


class Aggregate:
    def __init__(self):
        self.groups = {}

    def consume(self, row):
        baseline = 160 + row["output_bytes"]
        assets = row["num_assets"]
        payloads = row["datum_payload_bytes"] + row["reference_script_payload_bytes"]
        whole_fields = row["datum_contribution_bytes"] + row["reference_script_contribution_bytes"]
        policy_address = (175 + row["address_contribution_bytes"] + 12 * assets
                          + 30 * row["num_policies"] + row["asset_name_bytes"])
        # Order matches FORMULAS.
        estimates = (250 + 74 * assets + payloads,
                     policy_address + payloads,
                     250 + 74 * assets + row["datum_payload_bytes"],
                     baseline - row["coin_encoding_bytes"] + 9,
                     250 + 74 * assets + whole_fields,
                     policy_address + whole_fields)
        values = [(estimate - baseline, 100 * (estimate - baseline) / baseline,
                   10000 * (estimate - baseline) // baseline) for estimate in estimates]
        for group in group_names(row):
            statistics = self.groups.get(group)
            if statistics is None:
                statistics = [Statistics(group.startswith(("era/", "encoding/"))) for _ in FORMULAS]
                self.groups[group] = statistics
            for statistic, (delta, percent, percent_bin) in zip(statistics, values):
                statistic.add(baseline, delta, percent, percent_bin, row)

    def dump(self):
        return {group: [statistic.dump() for statistic in statistics]
                for group, statistics in self.groups.items()}

    def merge_dump(self, data):
        for group, encoded in data.items():
            statistics = self.groups.setdefault(group, [Statistics(group.startswith(("era/", "encoding/"))) for _ in FORMULAS])
            if len(encoded) != len(FORMULAS):
                raise ValueError("Unexpected formula count in checkpoint")
            for statistic, raw in zip(statistics, encoded):
                statistic.merge(Statistics.restore(raw))

    def summary(self, price):
        all_statistics = [Statistics(True) for _ in FORMULAS]
        transaction_statistics = [Statistics(True) for _ in FORMULAS]
        byte_era_statistics = [Statistics(True) for _ in FORMULAS]
        for group, statistics in self.groups.items():
            if group.startswith("era/"):
                for total, statistic in zip(all_statistics, statistics):
                    total.merge(statistic)
                if group != "era/Genesis":
                    for total, statistic in zip(transaction_statistics, statistics):
                        total.merge(statistic)
                if group in ("era/Babbage", "era/Conway"):
                    for total, statistic in zip(byte_era_statistics, statistics):
                        total.merge(statistic)
        groups = {"all": all_statistics, "transaction_created": transaction_statistics,
                  "byte_rule_eras": byte_era_statistics, **self.groups}
        return {name: {"formula": FORMULAS[name],
                       "groups": {group: statistics[index].summary(price)
                                  for group, statistics in groups.items()}}
                for index, name in enumerate(FORMULAS)}


def process_chunk(task):
    from extract_history import scan_chunk

    source, work_directory, manifest_hash, expected = task
    path = Path(source) / expected["name"]
    checkpoint = Path(work_directory) / "chunks" / (path.stem + ".json")
    error_path = checkpoint.with_suffix(".error.json")
    started = time.perf_counter()
    try:
        if inventory_entry(path) != expected:
            raise ValueError(f"Source changed since inventory: {path.name}")
        if checkpoint.exists():
            result = json.loads(checkpoint.read_text())
            if result["manifest_sha256"] != manifest_hash or result["source_inventory"] != expected:
                raise ValueError(f"Checkpoint identity mismatch: {checkpoint}")
            if result["metadata"]["sha256"] != file_sha256(path):
                raise ValueError(f"Source hash changed: {path.name}")
            result["reused"] = True
            result["current_run_seconds"] = time.perf_counter() - started
            return result
        aggregate = Aggregate()
        metadata = scan_chunk(path, aggregate.consume)
        if inventory_entry(path) != expected or metadata["bytes"] != expected["bytes"]:
            raise ValueError(f"Source changed during scan: {path.name}")
        population = sum(statistics[0].outputs for name, statistics in aggregate.groups.items()
                         if name.startswith("era/"))
        if population != metadata["created_outputs"]:
            raise ValueError(f"Extractor/aggregator output count differs: {path.name}")
        result = {"schema_version": SCHEMA_VERSION, "manifest_sha256": manifest_hash,
                  "source_inventory": expected, "metadata": metadata,
                  "scan_seconds": time.perf_counter() - started,
                  "statistics": aggregate.dump()}
        atomic_json(checkpoint, result)
        if error_path.exists():
            error_path.unlink()
        result["reused"] = False
        result["current_run_seconds"] = time.perf_counter() - started
        return result
    except Exception as error:
        atomic_json(error_path, {"chunk": path.name, "manifest_sha256": manifest_hash,
                                "error": str(error), "traceback": traceback.format_exc()})
        raise


def make_manifest(source, entries, price, genesis=None):
    directory = Path(__file__).parent
    scripts = ["backtest_history.py", "extract_history.py", "extract.py"]
    if genesis is not None:
        scripts.append("extract_genesis.py")
    return {
        "schema_version": SCHEMA_VERSION,
        "source": str(source.resolve()), "inventory": entries,
        "coins_per_utxo_byte": price, "formulas": FORMULAS,
        "old_formula": "coinsPerUTxOByte * (160 + original_received_output_bytes)",
        "percent_histogram_width_percentage_points": 0.01,
        "script_sha256": {name: file_sha256(directory / name) for name in scripts},
        "genesis": None if genesis is None else {
            "path": str(genesis.resolve()), "sha256": file_sha256(genesis),
            "inventory": inventory_entry(genesis)},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--genesis", type=Path, help="Include initial Byron allocations using constructed minimal output encodings")
    parser.add_argument("--first-chunk", type=int)
    parser.add_argument("--last-chunk", type=int)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--coins-per-utxo-byte", type=int, default=4310)
    args = parser.parse_args()
    if args.workers < 1 or args.coins_per_utxo_byte < 1:
        parser.error("workers and coins-per-utxo-byte must be positive")
    available = sorted(args.source.glob("[0-9][0-9][0-9][0-9][0-9].chunk"))
    if not available:
        parser.error("no immutable chunks found")
    first = int(available[0].stem) if args.first_chunk is None else args.first_chunk
    last = int(available[-1].stem) if args.last_chunk is None else args.last_chunk
    if first < 0 or last < first:
        parser.error("invalid chunk range")
    selected = [args.source / f"{number:05}.chunk" for number in range(first, last + 1)]
    entries = [inventory_entry(path) for path in selected]
    manifest = make_manifest(args.source, entries, args.coins_per_utxo_byte, args.genesis)
    manifest_hash = hashlib.sha256(json_bytes(manifest)).hexdigest()
    args.work_dir.mkdir(parents=True, exist_ok=True)
    (args.work_dir / "chunks").mkdir(exist_ok=True)
    manifest_path = args.work_dir / "manifest.json"
    if manifest_path.exists():
        if json.loads(manifest_path.read_text()) != manifest:
            raise ValueError("Existing manifest differs in scripts, configuration, or source inventory; use a new work directory")
    else:
        if any((args.work_dir / "chunks").iterdir()):
            raise ValueError("Chunk checkpoints exist without a manifest")
        atomic_json(manifest_path, manifest)
    if args.result.exists():
        existing = json.loads(args.result.read_text())
        if existing.get("manifest_sha256") != manifest_hash:
            raise ValueError("Result path already belongs to another manifest")

    total_bytes = sum(entry["bytes"] for entry in entries)
    started_utc = datetime.now(timezone.utc).isoformat()
    started = time.perf_counter()
    aggregate = Aggregate()
    genesis_metadata = None
    genesis_outputs = 0
    if args.genesis is not None:
        from extract_genesis import scan_genesis
        genesis_metadata = scan_genesis(args.genesis, aggregate.consume)
        if file_sha256(args.genesis) != manifest["genesis"]["sha256"]:
            raise ValueError("Genesis file changed during scan")
        genesis_outputs = aggregate.groups["era/Genesis"][0].outputs
        print(f"Genesis: {genesis_outputs:,} constructed initial outputs", flush=True)
    chunks = []
    completed_bytes = completed_outputs = reused = 0
    iterator = iter(entries)
    futures = {}
    print(f"Scanning {len(entries)} chunks, {total_bytes / 1e9:.3f} GB, {args.workers} workers; manifest {manifest_hash}", flush=True)
    with ProcessPoolExecutor(max_workers=args.workers) as executor:
        def submit_next():
            entry = next(iterator, None)
            if entry is not None:
                task = (str(args.source), str(args.work_dir), manifest_hash, entry)
                futures[executor.submit(process_chunk, task)] = entry["name"]

        for _ in range(min(len(entries), 2 * args.workers)):
            submit_next()
        try:
            while futures:
                done, _ = wait(futures, return_when=FIRST_COMPLETED)
                for future in done:
                    name = futures.pop(future)
                    result = future.result()
                    aggregate.merge_dump(result["statistics"])
                    metadata = result["metadata"]
                    chunks.append(metadata | {"scan_seconds": result["scan_seconds"], "reused": result["reused"]})
                    completed_bytes += metadata["bytes"]
                    completed_outputs += metadata["created_outputs"]
                    reused += result["reused"]
                    elapsed = time.perf_counter() - started
                    remaining = elapsed * (total_bytes - completed_bytes) / completed_bytes
                    print(f"{name}: {len(chunks)}/{len(entries)} chunks, {completed_outputs:,} outputs, "
                          f"{completed_bytes / total_bytes:.1%} bytes, {elapsed:.1f}s elapsed, "
                          f"{remaining / 60:.1f}m ETA{' (reused)' if result['reused'] else ''}", flush=True)
                    submit_next()
        except BaseException:
            for future in futures:
                future.cancel()
            raise
    variants = aggregate.summary(args.coins_per_utxo_byte)
    for variant in variants.values():
        if variant["groups"]["all"]["outputs"] != completed_outputs + genesis_outputs:
            raise ValueError("Final aggregate population differs from chunk population")
        if variant["groups"]["transaction_created"]["outputs"] != completed_outputs:
            raise ValueError("Final transaction-created population differs from chunk population")
    report = {
        "schema_version": SCHEMA_VERSION, "status": "complete",
        "scope": "Outputs created by accepted historical blocks in the selected immutable chunks, including outputs later spent; initial genesis allocations are also included when supplied. Not a live UTxO census or ledger validation.",
        "baseline_interpretation": "Babbage and Conway use the previous byte-based minUTxO shape. Earlier eras are compared against the same counterfactual byte benchmark, not their historical creation-time minimum.",
        "genesis_scope": ("Initial allocations included using constructed minimal Byron output encodings, not received output byte spans. They are also reported separately as era/Genesis."
                          if args.genesis is not None else "Initial genesis allocations not supplied; only block-created outputs included."),
        "genesis_metadata": genesis_metadata,
        "coins_per_utxo_byte": args.coins_per_utxo_byte,
        "old_formula": manifest["old_formula"],
        "definitions": {
            "numberOfNativeAssets": "Distinct non-ADA policy/name pairs; quantities are not counted.",
            "numberOfMintingPolicies": "Distinct minting policies represented in the output.",
            "totalAssetNameBytes": "Sum of raw name lengths per asset pair, including repeated names under different policies.",
            "serializedDatumBytes": "32 for a datum hash; for an inline datum, the original encoded Plutus data inside tag 24 (its datum-hash input). Excludes keys, tags and headers.",
            "serializedReferenceScriptBytes": "The script-hash input without its one-byte language prefix: a native script's original CBOR or a Plutus script's byte-string contents. Excludes keys, tags, headers and the language identifier.",
            "serializedAdaAmountBytes": "Original encoded size of the output's ADA amount.",
            "serializedFieldBytes": "Original entire encoded field contribution, including a map key where present and encoding wrappers (address term, and the whole-field controls).",
        },
        "percentile_method": "Nearest rank ceil(n*q/100). Byte-delta percentiles are exact. Percentage-excess percentiles are intervals [lower,upper) of width 0.01 percentage points, obtained using integer floor(10000*delta_bytes/baseline_bytes). Counts at 5% and 10% are exact integer comparisons.",
        "manifest_sha256": manifest_hash, "manifest": manifest,
        "first_chunk": first, "last_chunk": last, "chunks": sorted(chunks, key=lambda chunk: chunk["path"]),
        "bytes": completed_bytes, "outputs": completed_outputs + genesis_outputs,
        "transaction_created_outputs": completed_outputs, "genesis_outputs": genesis_outputs,
        "started_utc": started_utc, "finished_utc": datetime.now(timezone.utc).isoformat(),
        "elapsed_seconds": time.perf_counter() - started, "workers": args.workers,
        "reused_chunks": reused, "variants": variants,
    }
    args.result.parent.mkdir(parents=True, exist_ok=True)
    atomic_json(args.result, report)
    print(f"Wrote {args.result}: {report['outputs']:,} outputs in {report['elapsed_seconds']:.1f}s", flush=True)


if __name__ == "__main__":
    main()
