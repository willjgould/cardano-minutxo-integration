#!/usr/bin/env python3
"""Print Markdown tables for a backtest_history.py result.

With --control, also check that the whole-field control formulas reproduce an
earlier two-formula result (history-comparison.json) in every group, ignoring
only witness rows, which now carry the added payload measurements.
"""

import argparse
import json
from pathlib import Path

LABELS = {
    "cip": "CIP: `250 + 74N + D + R`",
    "alternative_policy_address": "Alt 1: policy, address and name sizes",
    "alternative_datum_only": "Alt 2: datum only, `250 + 74N + D`",
    "alternative_fixed_ada_width": "Alt 3: fixed ADA width",
    "control_cip_whole_fields": "Control: CIP, whole fields",
    "control_policy_address_whole_fields": "Control: Alt 1, whole fields",
}
CONTROLS = {"control_cip_whole_fields": "original_winner",
            "control_policy_address_whole_fields": "new_winner"}
WITNESS_KEYS = {"minimum_delta_witness", "maximum_delta_witness",
                "most_underestimated_outputs", "most_overestimated_outputs"}


def metrics(summary):
    shortfall = -summary["signed_delta_lovelace"]["min"]
    percent = summary["signed_delta_percent"]
    return (f"{summary['below_old']:,} ({summary['below_old_percent']:.5f}%)",
            f"{percent['p50']['lower_inclusive']:.2f}%",
            f"{percent['p95']['lower_inclusive']:.2f}%",
            f"{summary['within_5_percent_above_percent']:.2f}%",
            f"{summary['mean_new_lovelace'] / 1e6:.6f}",
            f"{max(shortfall, 0) / 1e6:.6f}")


def table(variants, group, names, first="Formula"):
    lines = [f"| {first} | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for name in names:
        summary = variants[name]["groups"].get(group, {"outputs": 0})
        if summary["outputs"]:
            lines.append(f"| {LABELS.get(name, name)} | " + " | ".join(metrics(summary)) + " |")
    return "\n".join(lines)


def same(a, b):
    """Exact for integers and strings. Floats come from sums whose order depends
    on chunk completion order, so they may differ in the last bits."""
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    if isinstance(a, float) or isinstance(b, float):
        return abs(a - b) <= 1e-9 * max(1.0, abs(a), abs(b))
    return a == b


def without_witnesses(value):
    return {key: item for key, item in value.items() if key not in WITNESS_KEYS}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", type=Path)
    parser.add_argument("--control", type=Path, help="earlier two-formula result to reproduce")
    args = parser.parse_args()
    report = json.loads(args.result.read_text())
    variants = report["variants"]
    # The result JSON sorts its keys; present formulas in a fixed order instead.
    names = [name for name in LABELS if name in variants] + [name for name in variants if name not in LABELS]
    old_baseline = variants[names[0]]["groups"]["all"]["mean_old_lovelace"] / 1e6
    print(f"Outputs: {report['outputs']:,} ({report['transaction_created_outputs']:,} transaction-created, "
          f"{report['genesis_outputs']:,} genesis); {report['bytes'] / 1e9:.3f} GB; "
          f"{report['elapsed_seconds'] / 60:.2f} minutes with {report['workers']} workers. "
          f"Old byte benchmark mean: {old_baseline:.6f} ADA.\n")
    print("## Every historical output\n")
    print(table(variants, "all", names) + "\n")
    print("## Babbage and Conway only\n")
    print(table(variants, "byte_rule_eras", names) + "\n")
    for group in ("payload/inline_datum", "payload/hash_datum", "payload/reference_script"):
        print(f"## Outputs in group `{group}`\n")
        print(table(variants, group, names) + "\n")
    print("## CIP formula by creation era\n")
    eras = sorted((g for g in variants["cip"]["groups"] if g.startswith("era/")),
                  key=lambda g: ["Genesis", "Byron", "Shelley", "Allegra", "Mary", "Alonzo", "Babbage", "Conway"].index(g[4:]))
    print(table({f"{g[4:]}": {"groups": {"x": variants["cip"]["groups"][g]}} for g in eras}, "x",
                [g[4:] for g in eras], first="Era") + "\n")
    if args.control:
        old = json.loads(args.control.read_text())["variants"]
        print("## Control reproduction\n")
        for new_name, old_name in CONTROLS.items():
            new_groups, old_groups = variants[new_name]["groups"], old[old_name]["groups"]
            same_groups = set(new_groups) == set(old_groups)
            differing = [g for g in old_groups
                         if not same(without_witnesses(new_groups.get(g, {})), without_witnesses(old_groups[g]))]
            print(f"- `{new_name}` vs earlier `{old_name}`: {len(old_groups)} groups, "
                  f"group sets identical: {same_groups}, groups differing: {len(differing)}"
                  + (f" ({', '.join(differing[:5])})" if differing else ""))


if __name__ == "__main__":
    main()
