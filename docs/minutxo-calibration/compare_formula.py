#!/usr/bin/env python3
"""Compare the proposed 160 + 72*N + D + R against original output sizes.

Reuses the authenticated mainnet sample and structural reader. No ledger rule
is changed. Sizes are bytes; native-asset counts exclude ADA unless labelled.
"""

import argparse
import hashlib
import json
from pathlib import Path

from extract import Reader, extract_chunk, integer_map


def add_payload_sizes(rows, path):
    data = path.read_bytes()
    for row in rows:
        datum_size = script_size = 0
        if row["datum_type"] != "none" or row["has_reference_script"]:
            reader = Reader(data[row["offset"]:row["end_offset"]])
            output = reader.read()
            if reader.pos != len(reader.data):
                raise ValueError("Output span was not consumed exactly")
            fields = integer_map(output, "output")[0] if output.major == 5 else dict(enumerate(output.value))
            if row["datum_type"] == "hash":
                datum_size = 32
            elif row["datum_type"] == "inline":
                # Datum option [1, tag24(bytes(serialized Plutus Data))].
                datum_size = len(fields[2].value[1].value[1].value)
            if row["has_reference_script"]:
                # Script field tag24(bytes(serialized [language, script])).
                # Includes the inner language/script encoding, not outer wrappers.
                script_size = len(fields[3].value[1].value)
        row["datum_payload_bytes"] = datum_size
        row["reference_script_payload_bytes"] = script_size
        if datum_size > row["datum_contribution_bytes"] or script_size > row["reference_script_contribution_bytes"]:
            raise ValueError("Payload larger than its encoded field")


def payload(row, full_fields=True):
    if full_fields:
        return row["datum_contribution_bytes"] + row["reference_script_contribution_bytes"]
    return row["datum_payload_bytes"] + row["reference_script_payload_bytes"]


def percentiles(values):
    ordered = sorted(values)
    if not ordered:
        return None
    return {name: ordered[max(0, (len(ordered) * q + 99) // 100 - 1)]
            for name, q in (("p05", 5), ("p50", 50), ("p95", 95), ("p99", 99))} | {
                "min": ordered[0], "max": ordered[-1]}


def assess(rows, formula, price):
    if not rows:
        return {"outputs": 0}
    old = [price * (160 + r["output_bytes"]) for r in rows]
    new = [formula(r) for r in rows]
    delta = [a - b for a, b in zip(new, old)]
    pct = [100 * d / b for d, b in zip(delta, old)]
    return {"outputs": len(rows), "below_old": sum(d < 0 for d in delta),
            "equal_old": sum(d == 0 for d in delta), "above_old": sum(d > 0 for d in delta),
            "below_old_percent": 100 * sum(d < 0 for d in delta) / len(rows),
            "within_5_percent_above": sum(0 <= p <= 5 for p in pct),
            "within_10_percent_above": sum(0 <= p <= 10 for p in pct),
            "within_5_percent_either_side": sum(-5 <= p <= 5 for p in pct),
            "signed_delta_lovelace": percentiles(delta), "signed_delta_percent": percentiles(pct),
            "mean_old_lovelace": sum(old) / len(rows), "mean_new_lovelace": sum(new) / len(rows),
            "mean_signed_delta_lovelace": sum(delta) / len(rows),
            "aggregate_signed_change_percent": 100 * (sum(new) - sum(old)) / sum(old)}


def groups(rows):
    return {"all": rows,
            "no_native_assets": [r for r in rows if not r["num_assets"]],
            "one_native_asset": [r for r in rows if r["num_assets"] == 1],
            "two_to_five_native_assets": [r for r in rows if 2 <= r["num_assets"] <= 5],
            "six_or_more_native_assets": [r for r in rows if r["num_assets"] >= 6],
            "plain": [r for r in rows if r["datum_type"] == "none" and not r["has_reference_script"]],
            "inline_datum": [r for r in rows if r["datum_type"] == "inline"],
            "datum_hash": [r for r in rows if r["datum_type"] == "hash"],
            "reference_script": [r for r in rows if r["has_reference_script"]]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, default=Path(__file__).with_name("results.json"))
    parser.add_argument("--result", type=Path, required=True)
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text())
    price = baseline["coins_per_utxo_byte"]
    rows, train, holdout, chunks = [], [], [], []
    for original in baseline["chunks"]:
        path = args.source / Path(original["path"]).name
        metadata, chunk_rows = extract_chunk(path)
        for key in ("sha256", "bytes", "blocks", "transactions", "transaction_body_bytes",
                    "body_size_xor_checksum", "body_hash_xor_checksum", "created_outputs"):
            if metadata[key] != original[key]:
                raise ValueError(f"Baseline mismatch for {path.name}: {key}")
        add_payload_sizes(chunk_rows, path)
        rows.extend(chunk_rows)
        (train if int(path.stem) < baseline["holdout_first_chunk"] else holdout).extend(chunk_rows)
        chunks.append(metadata)
        print(f"{path.name}: {len(chunk_rows)} outputs", flush=True)

    def sized(base, per_asset, full=True):
        return lambda row: price * (base + per_asset * row["num_assets"] + payload(row, full))

    variants = {
        "proposed_full_fields": ("p*(160+72*N+D_field+R_field); N excludes ADA", sized(160, 72)),
        "proposed_payload_only": ("p*(160+72*N+D_payload+R_payload); hash contributes32; N excludes ADA", sized(160, 72, False)),
        "proposed_count_ada_full_fields": ("p*(160+72*(N+1)+D_field+R_field)", sized(232, 72)),
        "proposed_count_ada_payload_only": ("p*(160+72*(N+1)+D_payload+R_payload)", sized(232, 72, False)),
        "corrected_235_74_full_fields": ("p*(235+74*N+D_field+R_field)", sized(235, 74)),
        "corrected_368_72_full_fields": ("p*(368+72*N+D_field+R_field)", sized(368, 72)),
        "previous_linear": ("1000000+320000*N (lovelace); no payload term", lambda row: 1_000_000 + 320_000 * row["num_assets"]),
        "flat_15_ada": ("1500000 lovelace allowance", lambda row: 1_500_000),
        "flat_2_ada": ("2000000 lovelace allowance", lambda row: 2_000_000),
    }
    report = {"scope": "Same historical mainnet output-creation sample; not live UTxO census, ledger test, or universal bound.",
              "price": price, "old_formula": "p*(160+original_received_output_bytes)",
              "num_assets": "Distinct non-ADA (policy ID, asset name) pairs; include-ADA variants explicitly add one.",
              "field_sizes": "Actual entire encoded field contribution, including output-map key, option/tag/bytestring wrappers; list datum hash includes its byte-string header.",
              "payload_sizes": "Inline datum's inner serialized Plutus Data; script's inner serialized [language,script]; hash32, absent0. Does not include outer field wrappers.",
              "chunks": chunks, "baseline_sha256": hashlib.sha256(args.baseline.read_bytes()).hexdigest(),
              "script_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in (Path(__file__), Path(__file__).with_name("extract.py"))},
              "independent_scanner_comparison": baseline["independent_scanner_comparison"],
              "variants": {}, "fit_base_bytes": {}}
    populations = groups(rows)
    for label, (description, formula) in variants.items():
        report["variants"][label] = {"formula": description,
                                      "groups": {name: assess(pop, formula, price) for name, pop in populations.items()},
                                      "holdout": assess(holdout, formula, price)}
        key = lambda r: formula(r) - price * (160 + r["output_bytes"])
        report["variants"][label]["most_underestimated_output"] = min(rows, key=key)
        report["variants"][label]["most_overestimated_output"] = max(rows, key=key)
    for full in (True, False):
        for coefficient in (72, 74):
            residual = lambda r: 160 + r["output_bytes"] - coefficient * r["num_assets"] - payload(r, full)
            base = max(map(residual, train))
            label = f"{coefficient}_{'fields' if full else 'payload'}"
            report["fit_base_bytes"][label] = {
                "coefficient": coefficient, "train_required_base": base,
                "whole_sample_required_base": max(map(residual, rows)),
                "binding_output": max(rows, key=residual),
                "train": assess(train, sized(base, coefficient, full), price),
                "holdout": assess(holdout, sized(base, coefficient, full), price),
                "all": assess(rows, sized(base, coefficient, full), price)}
    args.result.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Wrote {args.result}: {len(rows)} outputs", flush=True)


if __name__ == "__main__":
    main()
