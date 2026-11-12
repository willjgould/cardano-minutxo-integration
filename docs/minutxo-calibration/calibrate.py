#!/usr/bin/env python3
"""Calibrate C + x * distinctAssets against received Conway output byte spans.

Analysis only: no ledger rule is changed and no universal guarantee is inferred
from sampled outputs. Integer amounts are lovelace. Uses extract.py from here.
"""

import argparse
from collections import Counter
from fractions import Fraction
import hashlib
import json
from pathlib import Path

from extract import extract_chunk


def quantiles(values):
    values = sorted(values)
    if not values:
        return None
    return {label: values[max(0, (len(values) * numerator + 99) // 100 - 1)]
            for label, numerator in (("p50", 50), ("p95", 95), ("p99", 99), ("max", 100))}


def ceiling_ratio(numerator, denominator):
    return -(-numerator // denominator)


def required_x(rows, constant, price):
    tokens = [r for r in rows if r["num_assets"]]
    witness = max(tokens, key=lambda r: Fraction(price * (160 + r["output_bytes"]) - constant,
                                               r["num_assets"]), default=None)
    x = max(0, ceiling_ratio(price * (160 + witness["output_bytes"]) - constant,
                             witness["num_assets"])) if witness else 0
    zeros = [r for r in rows if r["num_assets"] == 0]
    return {"constant_lovelace": constant, "required_x_lovelace": x,
            "zero_asset_failures": sum(price * (160 + r["output_bytes"]) > constant for r in zeros),
            "zero_asset_constant_required": max((price * (160 + r["output_bytes"]) for r in zeros), default=0),
            "binding_zero_asset_output": max(zeros, key=lambda r: r["output_bytes"], default=None),
            "binding_token_output": witness}


def assess(rows, constant, x, price):
    errors = [constant + x * r["num_assets"] - price * (160 + r["output_bytes"]) for r in rows]
    percentages = [100 * error / (price * (160 + r["output_bytes"])) for error, r in zip(errors, rows)]
    return {"outputs": len(rows), "underestimated": sum(e < 0 for e in errors),
            "covered_percent": 100 * sum(e >= 0 for e in errors) / len(rows) if rows else None,
            "within_5_percent_above": sum(0 <= p <= 5 for p in percentages),
            "within_10_percent_above": sum(0 <= p <= 10 for p in percentages),
            "signed_excess_lovelace": quantiles(errors),
            "signed_excess_percent": quantiles(percentages),
            "mean_signed_excess_lovelace": sum(errors) / len(rows) if rows else None}


def summarize(rows, price):
    return {"outputs": len(rows), "zero_asset_outputs": sum(r["num_assets"] == 0 for r in rows),
            "asset_count": quantiles([r["num_assets"] for r in rows]),
            "old_minimum_lovelace": quantiles([price * (160 + r["output_bytes"]) for r in rows]),
            "datum_types": dict(Counter(r["datum_type"] for r in rows)),
            "address_types": dict(Counter(r["address_type"] for r in rows)),
            "outputs_below_comparison_minimum": sum(r["coin"] < price * (160 + r["output_bytes"]) for r in rows),
            "reference_script_outputs": sum(r["has_reference_script"] for r in rows)}


def group_rows(rows):
    return {"all": rows,
            "plain": [r for r in rows if r["datum_type"] == "none" and not r["has_reference_script"]],
            "plain_base_enterprise": [r for r in rows if r["datum_type"] == "none"
                                      and not r["has_reference_script"]
                                      and r["address_type"] in ("base", "enterprise")],
            "payload": [r for r in rows if r["datum_type"] != "none" or r["has_reference_script"]]}


def uint(n, major=0):
    if n < 24:
        return bytes([major * 32 + n])
    for width, ai in ((1, 24), (2, 25), (4, 26), (8, 27)):
        if n < 2 ** (8 * width):
            return bytes([major * 32 + ai]) + n.to_bytes(width, "big")
    raise ValueError("outside uint64")


def byte_string(value):
    return uint(len(value), 2) + value


def synthetic_bound(price):
    # Standard ledger encoder: list output, base address, no datum or script.
    # Distinct policies each get one 32-byte name and a nine-byte quantity.
    # Use a nine-byte ADA amount; its precise value does not affect this size.
    address = byte_string(bytes([1]) + bytes(56))
    coin = uint(2 ** 32)
    cases = []
    for n in range(68):
        if n:
            assets = uint(n, 5) + b"".join(
                byte_string(i.to_bytes(28, "big")) + uint(1, 5)
                + byte_string(bytes(32)) + uint(2 ** 63 - 1)
                for i in range(n))
            value = uint(2, 4) + coin + assets
        else:
            value = coin
        output = uint(2, 4) + address + value
        assert len(value) <= 5000
        assert len(output) == (69 if n == 0 else 70 + len(uint(n, 5)) + 74 * n)
        cases.append({"num_assets": n, "output_bytes": len(output), "value_bytes": len(value)})
    frontier = [required_x(cases, c, price) for c in (1_000_000, 1_050_000, 1_100_000, 1_200_000)]
    map_cases = [dict(case, output_bytes=case["output_bytes"] + 2) for case in cases]
    map_frontier = [required_x(map_cases, c, price) for c in (1_000_000, 1_050_000, 1_100_000, 1_200_000)]
    # For n>=68 a valid Value is at most 5000 bytes, plus 60 address/list bytes.
    # Its per-token residual is maximized at n=68 for these positive numerators.
    for item in frontier:
        assert item["required_x_lovelace"] * 68 + item["constant_lovelace"] >= price * (160 + 5060)
    for item in map_frontier:
        assert item["required_x_lovelace"] * 68 + item["constant_lovelace"] >= price * (160 + 5062)
    return {"scope": "Standard ledger encoder, base/enterprise addresses, no datum/hash/script; maxValSize=5000. Not all accepted encodings.",
            "coins_per_utxo_byte": price, "max_value_size_assumed": 5000,
            "worst_token_entry_bytes": 74, "token_byte_rate_lovelace": 74 * price,
            "frontier": frontier, "minimal_width_map_frontier": map_frontier, "cases": cases}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--first", type=int, default=9306)
    parser.add_argument("--last", type=int, default=9335)
    parser.add_argument("--holdout-first", type=int, default=9326)
    parser.add_argument("--price", type=int, default=4310)
    parser.add_argument("--result", type=Path, required=True)
    args = parser.parse_args()
    if not (args.first < args.holdout_first <= args.last):
        parser.error("require first < holdout-first <= last")
    if args.price <= 0:
        parser.error("price must be positive")
    all_rows, train, holdout, chunks = [], [], [], []
    for chunk in range(args.first, args.last + 1):
        path = args.source / f"{chunk:05d}.chunk"
        metadata, rows = extract_chunk(path)
        chunks.append(metadata)
        all_rows.extend(rows)
        (train if chunk < args.holdout_first else holdout).extend(rows)
        print(f"{path.name}: {len(rows)} created outputs", flush=True)
    result = {"scope": "Historical mainnet output-creation sample, not the current live UTxO distribution or a proof for all valid outputs.",
              "ledger_branch": "minutxo-calculation", "ledger_commit": "a1631b518297bb9f8d5d2e4cda11ca0effe70ff8",
              "comparison": "coinsPerUTxOByte * (160 + original received output bytes)",
              "coins_per_utxo_byte": args.price,
              "price_policy": "Fixed comparison price for all rows; no historical min-ADA parameter recovery.",
              "source_provenance": "mainnet-source.json",
              "chunks": chunks, "holdout_first_chunk": args.holdout_first,
              "script_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in (Path(__file__), Path(__file__).with_name("extract.py"))},
              "synthetic_bound": synthetic_bound(args.price), "groups": {}}
    benchmark_path = Path(__file__).with_name("scanner-measurements.json")
    benchmark = json.loads(benchmark_path.read_text())["scan_summary"]
    observed = next((chunk for chunk in chunks if Path(chunk["path"]).name == benchmark["chunk"]), None)
    if observed:
        recorded = json.loads(benchmark_path.read_text())
        structural = next(run for run in recorded["scan_runs"] if run["kind"] == "structural")
        hashed = next(run for run in recorded["scan_runs"] if run["kind"] == "structural_plus_hash")
        expected = {"bytes": benchmark["chunk_bytes"], "sha256": benchmark["chunk_sha256"],
                    "blocks": benchmark["counts"]["blocks"],
                    "transactions": benchmark["counts"]["transaction_bodies"],
                    "transaction_body_bytes": benchmark["counts"]["transaction_body_bytes"],
                    "body_size_xor_checksum": structural["checksum"],
                    "body_hash_xor_checksum": hashed["checksum"]}
        for key, value in expected.items():
            if observed[key] != value:
                raise ValueError(f"Independent Haskell scanner mismatch: {key}")
        result["independent_scanner_comparison"] = {"chunk": benchmark["chunk"], "matched": expected,
                                                    "source": "scanner-measurements.json"}
    all_groups, train_groups, holdout_groups = map(group_rows, (all_rows, train, holdout))
    for name, rows in all_groups.items():
        candidates = []
        constants = {689600, 1_000_000, 1_050_000, 1_100_000, 1_200_000, 1_500_000, 2_000_000, 5_000_000, 10_000_000, 100_000_000}
        constants.add(max((args.price * (160 + r["output_bytes"]) for r in train_groups[name]
                          if r["num_assets"] == 0), default=0))
        for constant in sorted(constants):
            fitted = required_x(train_groups[name], constant, args.price)
            x = fitted["required_x_lovelace"]
            candidates.append({"fit": fitted, "train": assess(train_groups[name], constant, x, args.price),
                               "holdout": assess(holdout_groups[name], constant, x, args.price),
                               "all_required": required_x(rows, constant, args.price)})
        slopes = []
        for x in (0, 200_000, 250_000, 300_000, 318_940, 320_000, 350_000, 500_000, 1_000_000):
            constant = max((args.price * (160 + r["output_bytes"]) - x * r["num_assets"] for r in rows), default=0)
            constant = max(0, constant)
            slopes.append({"x_lovelace": x, "sample_safe_constant_lovelace": constant,
                           "all": assess(rows, constant, x, args.price)})
        result["groups"][name] = {"summary": summarize(rows, args.price),
                                  "constant_sweep": candidates, "slope_sweep": slopes,
                                  "one_ada_plus_032": assess(rows, 1_000_000, 320_000, args.price),
                                  "one_ada_plus_032_tokens_only": assess([r for r in rows if r["num_assets"]], 1_000_000, 320_000, args.price),
                                  "105_ada_plus_032": assess(rows, 1_050_000, 320_000, args.price)}
    args.result.parent.mkdir(parents=True, exist_ok=True)
    args.result.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Wrote {args.result}: {len(all_rows)} outputs", flush=True)


if __name__ == "__main__":
    main()
