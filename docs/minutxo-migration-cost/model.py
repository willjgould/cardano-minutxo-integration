#!/usr/bin/env python3
"""Reproduce the report's arithmetic; throughput scenarios are not benchmarks."""

import json
from pathlib import Path


def calculate(data):
    n = sum(row["utxo_count"] for row in data["utxo_distribution"])
    snapshot = data["mithril_snapshot"]
    history = snapshot["total_db_size_uncompressed"] - snapshot["ancillary"]["size_uncompressed"]
    runs = data["memory_runs"]
    modes = {}
    for row in runs:
        modes.setdefault(row["mode"], {})[row["n"]] = row["retained_delta_bytes"]
    slopes = {
        mode: (counts[2_000_000] - counts[1_000_000]) / 1_000_000
        for mode, counts in modes.items()
    }
    memory = {
        "existing_constructor_extra_word": slopes["map-inline-word64"] - slopes["map-base-value"],
        "wrapper_preserving_existing_output": slopes["map-wrapper-word64"] - slopes["map-base-value"],
        "separate_map_shared_keys": slopes["map-shared-keys-integer"],
        "separate_map_independent_keys": slopes["map-integer"],
    }
    assert all(v >= 0 for v in memory.values())
    prices = data["historical_parameters"]
    assert [r["epoch_no"] for r in prices] == list(range(208, 665))
    regimes = []
    for row in prices:
        key = [row["era"], row["min_utxo_value"], row["coins_per_utxo_size"]]
        if not regimes or regimes[-1]["key"] != key:
            regimes.append({"key": key, "first_epoch": row["epoch_no"], "last_epoch": row["epoch_no"]})
        else:
            regimes[-1]["last_epoch"] = row["epoch_no"]
    rates = [5, 10, 25, 50, 100, 250]
    return {
        "utxos": n,
        "utxo_snapshot_dates": sorted({r["computed_at"] for r in data["utxo_distribution"]}),
        "history_volume_proxy_bytes": history,
        "history_volume_note": "Database minus ancillary; includes immutable indexes. Not exact bytes a scanner must read.",
        "assumed_scan_rate_scenarios": [
            {"effective_MB_per_second": q, "seconds": history / (q * 1_000_000),
             "hours": history / (q * 1_000_000 * 3600)}
            for q in rates
        ],
        "measured_layout_extrapolations": {
            mode: {"additional_bytes_per_output": b,
                   "additional_bytes": int(n * b),
                   "additional_MiB": n * b / 2**20,
                   "additional_GB": n * b / 1_000_000_000}
            for mode, b in memory.items()
        },
        "illustrative_uncompressed_encoding": {
            "inline_32bit_cbor_amount_bytes": 5 * n,
            "separate_cbor_map_small_output_index_bytes": 41 * n + 5,
            "note": "Five-byte unsigned integer assumes amounts from 65,536 through 4,294,967,295; smaller amounts encode in fewer bytes. Standalone key is [32-byte TxId, index<24]. No wrapper, version, compression or database overhead included. This is a model, not a measured encoding."
        },
        "historical_parameter_regimes": regimes,
        "scan_component": data["scan_summary"],
    }


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    print(json.dumps(calculate(json.loads((here / "measurements.json").read_text())), indent=2))
