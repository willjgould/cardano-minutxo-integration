#!/usr/bin/env python3
"""Print the Markdown result tables of history-formulas.md from a
backtest_history.py result.

With --control, also check that the whole-field formulas reproduce an earlier
two-formula result (history-comparison.json) in every group, ignoring only
witness rows, which now carry the added payload measurements.
"""

import argparse
import json
from pathlib import Path

# Result keys, as named in backtest_history.FORMULAS, with their report labels.
# Alternative 1 is specified with whole datum and script fields, so its result
# key is control_policy_address_whole_fields.
MAIN = [("cip", "Proposed: `250 + 74N + D + R`"),
        ("control_policy_address_whole_fields", "Alt 1: address, policy and name sizes"),
        ("alternative_datum_only", "Alt 2: no reference-script term"),
        ("alternative_fixed_ada_width", "Alt 3: fixed ADA width")]
SENSITIVITY = [("cip", "Proposed, payload bytes (as specified)"),
               ("control_cip_whole_fields", "Proposed, whole fields"),
               ("control_policy_address_whole_fields", "Alt 1, whole fields (as specified)"),
               ("alternative_policy_address", "Alt 1, payload bytes")]
ADDRESS = [("cip", "Proposed: `250 + 74N + D + R`"),
           ("address_all", "Every address: `250 + 74N + A + D + R`"),
           ("address_all_rebased", "Every address, rebased: `193 + 74N + A + D + R`"),
           ("address_bootstrap_only", "Bootstrap only: `250 + 74N + (A if bootstrap) + D + R`"),
           ("address_above_57", "Above 57 bytes: `250 + 74N + max(0, A − 57) + D + R`"),
           ("address_bootstrap_rebased", "Bootstrap only, rebased: `(193 + A if bootstrap, else 250) + 74N + D + R`")]
ERAS =["Genesis", "Byron", "Shelley", "Allegra", "Mary", "Alonzo", "Babbage", "Conway"]
HEADER = ("| {} | Underestimates | Median excess | p95 excess | Within 5% above | Mean requirement, ADA | Largest shortfall, ADA |\n"
          "| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
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


def row(label, cells):
    return f"| {label} | " + " | ".join(cells) + " |"


def table(variants, group, rows, current=True):
    """One row per (result key, label), optionally after the current formula's mean."""
    lines = [HEADER.format("Formula")]
    if current:
        mean = variants[rows[0][0]]["groups"][group]["mean_old_lovelace"] / 1e6
        lines.append(row("Current: `160 + serializedOutputBytes`", ["–"] * 4 + [f"{mean:.6f}", "–"]))
    lines += [row(label, metrics(variants[name]["groups"][group])) for name, label in rows]
    return "\n".join(lines)


def section(title, variants, group, rows=MAIN):
    if group not in variants[rows[0][0]]["groups"]:
        return f"### {title}\n\nNo outputs.\n"
    outputs = variants[rows[0][0]]["groups"][group]["outputs"]
    return f"### {title}\n\n{outputs:,} outputs.\n\n{table(variants, group, rows)}\n"


def group_table(first, groups, labelled):
    """One row per (group, label) of a single formula's groups."""
    lines = [HEADER.format(first)]
    lines += [row(f"{label} ({groups[group]['outputs']:,} outputs)", metrics(groups[group]))
              for group, label in labelled if group in groups]
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
    print(f"{report['outputs']:,} outputs ({report['transaction_created_outputs']:,} created by transactions, "
          f"{report['genesis_outputs']:,} in genesis); {report['bytes'] / 1e9:.3f} GB of chunks.\n")
    print(section("Outputs created since the Babbage hard fork", variants, "byte_rule_eras"))
    print(section("Every output", variants, "all"))
    for group, title in (("payload/inline_datum", "Outputs with an inline datum"),
                         ("payload/hash_datum", "Outputs with a datum hash"),
                         ("payload/reference_script", "Outputs with a reference script")):
        print(section(title, variants, group))
    groups = variants["cip"]["groups"]
    print("### Proposed formula by native assets, every output\n")
    print(group_table("Native assets", groups, [("assets/none", "None"), ("assets/native", "One or more"),
                                                ("assets/six_or_more", "Six or more")]) + "\n")
    print("### Proposed formula by creation era\n")
    print(group_table("Era", groups, [("era/" + era, era) for era in ERAS]) + "\n")
    print("### Sensitivity to CBOR wrappers, outputs created since the Babbage hard fork\n")
    print(table(variants, "byte_rule_eras", SENSITIVITY, current=False) + "\n")
    for group, title in (("byte_rule_eras", "outputs created since the Babbage hard fork"),
                         ("era/Conway", "Conway outputs"),
                         ("byte_rule_address/bootstrap", "bootstrap-address outputs created since the Babbage hard fork"),
                         ("all", "every output")):
        print(section(f"Address terms, {title}", variants, group, ADDRESS))
    if args.control:
        old = json.loads(args.control.read_text())["variants"]
        print("### Control reproduction\n")
        for new_name, old_name in CONTROLS.items():
            new_groups, old_groups = variants[new_name]["groups"], old[old_name]["groups"]
            # Later runs add groups (byte_rule_address/*); every earlier group must still be present.
            same_groups = set(old_groups) <= set(new_groups)
            differing = [g for g in old_groups
                         if not same(without_witnesses(new_groups.get(g, {})), without_witnesses(old_groups[g]))]
            print(f"- `{new_name}` vs earlier `{old_name}`: {len(old_groups)} groups, "
                  f"all earlier groups present: {same_groups}, groups differing: {len(differing)}"
                  + (f" ({', '.join(differing[:5])})" if differing else ""))


if __name__ == "__main__":
    main()
