#!/usr/bin/env python3
"""Attribute count-formula slack and compare more informative size bounds.

N excludes ADA; P counts policies; L sums name lengths per asset entry (not
globally deduplicated names); A includes the encoded address field/key.
Uses original byte spans. This is an analysis, not a ledger implementation.
"""

import argparse
import hashlib
import json
from pathlib import Path

from compare_formula import assess, payload, percentiles
from extract import extract_chunk


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, default=Path(__file__).with_name("results.json"))
    parser.add_argument("--result", type=Path, required=True)
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text())
    price = baseline["coins_per_utxo_byte"]
    rows, holdout, chunks = [], [], []
    for original in baseline["chunks"]:
        path = args.source / Path(original["path"]).name
        metadata, chunk_rows = extract_chunk(path)
        for key in ("sha256", "bytes", "blocks", "transactions", "transaction_body_bytes",
                    "body_size_xor_checksum", "body_hash_xor_checksum", "created_outputs"):
            if metadata[key] != original[key]:
                raise ValueError(f"Baseline mismatch for {path.name}: {key}")
        for row in chunk_rows:
            if row["coin_encoding_bytes"] > 9 or row["asset_quantity_encoding_bytes"] > 9 * row["num_assets"]:
                raise ValueError("Unexpected integer width")
        rows.extend(chunk_rows)
        if int(path.stem) >= baseline["holdout_first_chunk"]:
            holdout.extend(chunk_rows)
        chunks.append(metadata)
        print(f"{path.name}: {len(chunk_rows)} outputs", flush=True)

    variants = {
        "asset_count": ("250+74*N+D+R", lambda r: 250 + 74*r["num_assets"] + payload(r)),
        "policy_count": ("250+44*N+30*P+D+R", lambda r: 250 + 44*r["num_assets"] + 30*r["num_policies"] + payload(r)),
        "name_lengths": ("250+12*N+30*P+L+D+R", lambda r: 250 + 12*r["num_assets"] + 30*r["num_policies"] + r["asset_name_bytes"] + payload(r)),
        "address_size": ("175+A+12*N+30*P+L+D+R", lambda r: 175 + r["address_contribution_bytes"] + 12*r["num_assets"] + 30*r["num_policies"] + r["asset_name_bytes"] + payload(r)),
        "structural_fixed_integers": ("160+outputBytes-coinBytes-quantityBytes+9*(N+1)", lambda r: 160 + r["output_bytes"] - r["coin_encoding_bytes"] - r["asset_quantity_encoding_bytes"] + 9*(r["num_assets"]+1)),
        "structural_fixed_coin": ("160+outputBytes-coinBytes+9", lambda r: 160 + r["output_bytes"] - r["coin_encoding_bytes"] + 9),
    }
    populations = {
        "all": rows,
        "no_native_assets": [r for r in rows if r["num_assets"] == 0],
        "native_assets": [r for r in rows if r["num_assets"] > 0],
        "six_or_more_native_assets": [r for r in rows if r["num_assets"] >= 6],
        "bootstrap": [r for r in rows if r["address_type"] == "bootstrap"],
        "base_enterprise": [r for r in rows if r["address_type"] in ("base", "enterprise")],
    }
    report = {
        "scope": "Same historical output-creation sample. Coarse bounds assume conventional encodings; empirical coverage is not universal proof.",
        "definitions": {"N": "distinct non-ADA asset pairs", "P": "distinct policies", "L": "sum of raw name lengths per asset entry",
                        "A": "original encoded address field contribution including map key", "D_R": "full encoded field contributions"},
        "price": price, "chunks": chunks,
        "baseline_sha256": hashlib.sha256(args.baseline.read_bytes()).hexdigest(),
        "script_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in
                          (Path(__file__), Path(__file__).with_name("extract.py"), Path(__file__).with_name("compare_formula.py"))},
        "variants": {}, "slack_attribution": {},
    }
    for name, (description, in_bytes) in variants.items():
        formula = lambda row: price * in_bytes(row)
        report["variants"][name] = {"formula": "p*("+description+")",
                                    "groups": {label: assess(pop, formula, price) for label, pop in populations.items()},
                                    "holdout": assess(holdout, formula, price)}
        delta = lambda row: in_bytes(row) - 160 - row["output_bytes"]
        report["variants"][name]["minimum_delta_witness"] = min(rows, key=delta)
        report["variants"][name]["maximum_delta_witness"] = max(rows, key=delta)

    savings = {
        "avoid_repeating_policy": lambda r: 30*(r["num_assets"]-r["num_policies"]),
        "actual_name_lengths": lambda r: 32*r["num_assets"]-r["asset_name_bytes"],
        "replace_fixed_base_with_address": lambda r: 75-r["address_contribution_bytes"],
        "use_actual_token_quantity_widths": lambda r: 9*r["num_assets"]-r["asset_quantity_encoding_bytes"],
        "maximum_coin_width_margin": lambda r: 9-r["coin_encoding_bytes"],
    }
    for name, saving in savings.items():
        report["slack_attribution"][name] = {}
        for label in ("all", "native_assets", "six_or_more_native_assets"):
            values = [saving(r) for r in populations[label]]
            report["slack_attribution"][name][label] = {
                "mean_bytes": sum(values)/len(values), "bytes": percentiles(values),
                "mean_lovelace": price*sum(values)/len(values)}
    args.result.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Wrote {args.result}: {len(rows)} outputs", flush=True)


if __name__ == "__main__":
    main()
