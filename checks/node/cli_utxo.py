"""Verify live CLI JSON and text reads after the token-funding prerequisite."""

import argparse
import json
from pathlib import Path
import shlex
import subprocess


def expect(actual, expected, description):
    if actual != expected:
        raise RuntimeError(f"{description}: expected {expected!r}, got {actual!r}")


def check_utxo(cli, directory, socket):
    funding = json.loads((directory / "token-funding-included.json").read_text())
    expect(funding["included"], True, "Funding must be included before CLI reads")
    tx_id = funding["txId"]
    policy = funding["policyId"]
    asset_name = b"offer".hex()
    token_owner = (directory / "token-owner-address.txt").read_text().strip()
    ada_owner = (directory / "address.txt").read_text().strip()
    absent_data = dict.fromkeys(
        ("datum", "datumhash", "inlineDatum", "inlineDatumRaw", "referenceScript")
    )
    token_utxo = {
        f"{tx_id}#{index}": {
            "address": token_owner,
            "applicationAssets": {policy: {asset_name: 7}},
            **absent_data,
        }
        for index in (0, 1)
    }
    # The expected shape deliberately has no `value` or lovelace entry.
    # Compare with the API's independently verified live query as well.
    expect(json.loads((directory / "token-owner-utxo.json").read_text()),
           token_utxo, "API token-owner baseline")
    change = funding["changeLovelace"]
    ada_utxo = {
        f"{tx_id}#2": {
            "address": ada_owner,
            "value": {"lovelace": change},
            **absent_data,
        }
    }

    def query(owner, name, output_format):
        command = [
            cli, "dijkstra", "query", "utxo", "--socket-path", str(socket),
            "--testnet-magic", "42", "--cardano-mode", "--epoch-slots", "50",
            "--address", owner, f"--output-{output_format}",
        ]
        print("$ " + shlex.join(command), flush=True)
        stem = directory / f"cli-{name}-utxo"
        suffix = "json" if output_format == "json" else "txt"
        Path(f"{stem}.{suffix}.command.json").write_text(json.dumps(command, indent=2) + "\n")
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        Path(f"{stem}.{suffix}").write_text(result.stdout)
        Path(f"{stem}.{suffix}.stderr").write_text(result.stderr)
        if result.returncode:
            raise RuntimeError(f"CLI {name} {output_format} query failed ({result.returncode}): {result.stderr}")
        return result.stdout

    for owner, name, expected_json, expected_rows in (
        (token_owner, "token-owner", token_utxo,
         [f"{tx_id} {index} 7 {policy}.{asset_name} (store-backed) + NoDatum" for index in (0, 1)]),
        (ada_owner, "ada-owner", ada_utxo,
         [f"{tx_id} 2 {change} lovelace + NoDatum"]),
    ):
        expect(json.loads(query(owner, name, "json")), expected_json,
               f"CLI {name} JSON must preserve exact references, address, output kind and assets")
        lines = query(owner, name, "text").strip().splitlines()
        expect(lines[0].split() if lines else [], ["TxHash", "TxIx", "Amount"], "CLI text header")
        expect(set(lines[1]) if len(lines) > 1 else set(), {"-"}, "CLI text separator")
        # Ignore column padding, but require every row and its entire amount.
        # Zero ADA is omitted by renderValue, so no lovelace term may appear
        # in the token rows; the store deposit must not become spendable ADA.
        expect([" ".join(line.split()) for line in lines[2:]], expected_rows,
               f"CLI {name} text rows")
        print(f"PASS: CLI {name} JSON and text preserve exact UTxOs, assets and deposit kind", flush=True)

    (directory / "cli-utxo-verified.json").write_text(json.dumps({
        "jsonAndTextVerified": True,
        "tokenOwnerOutputs": 2,
        "tokensPerOutput": 7,
        "tokenOutputLovelace": 0,
        "ordinaryChangeLovelace": change,
        "txId": tx_id,
    }, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli")
    parser.add_argument("directory", type=Path)
    parser.add_argument("socket", type=Path)
    args = parser.parse_args()
    check_utxo(args.cli, args.directory, args.socket)
