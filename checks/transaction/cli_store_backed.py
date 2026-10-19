"""Check CLI construction and decoding of a store-backed output, without a node."""

import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
CLI_TARGET = "cardano-cli:exe:cardano-cli"
INPUT = "00" * 32 + "#0"
POLICY = "22" * 28
ASSET_NAME = b"offer".hex()
FEE = 200000
# Address from the declared CLI's Test/Golden/Conway/Transaction/BuildRaw.hs.
ADDRESS = "addr_test1vpqgspvmh6m2m5pwangvdg499srfzre2dd96qq57nlnw6yctpasy4"
ASSETS = {f"policy {POLICY}": {f"asset {ASSET_NAME} (offer)": 7}}


class CommandFailed(RuntimeError):
    def __init__(self, name, returncode):
        super().__init__(f"{name} exited with {returncode}; subsequent assertions did not run")
        self.returncode = returncode


def run(directory, name, command, stdout_suffix="stdout"):
    print("$ " + shlex.join(command), flush=True)
    (directory / f"{name}.command.json").write_text(json.dumps(command, indent=2) + "\n")
    stdout_path = directory / f"{name}.{stdout_suffix}"
    stderr_path = directory / f"{name}.stderr"
    with stdout_path.open("w") as stdout, stderr_path.open("w") as stderr:
        result = subprocess.run(command, cwd=ROOT, stdout=stdout, stderr=stderr)
    output = stdout_path.read_text()
    print(output, end="", flush=True)
    print(stderr_path.read_text(), end="", file=sys.stderr, flush=True)
    if result.returncode:
        raise CommandFailed(name, result.returncode)
    return output


def expect(actual, expected, description):
    if actual != expected:
        raise RuntimeError(f"{description}: expected {expected!r}, got {actual!r}")


def check_output(directory, cli, name, flag, value_field, absent_field):
    body = directory / f"{name}.body.json"
    run(directory, f"{name}-build", [
        cli, "dijkstra", "transaction", "build-raw", "--tx-in", INPUT,
        flag, f"{ADDRESS}+0+7 {POLICY}.{ASSET_NAME}",
        "--fee", str(FEE), "--out-file", str(body),
    ])
    view = json.loads(run(directory, f"{name}-view", [
        cli, "debug", "transaction", "view", "--tx-file", str(body), "--output-json",
    ], stdout_suffix="json"))
    expect(view["era"], "Dijkstra", f"{name}: era")
    expect(view["inputs"], [INPUT], f"{name}: synthetic input")
    expect(view["fee"], f"{FEE} Lovelace", f"{name}: fee")
    expect(len(view["outputs"]), 1, f"{name}: output count")
    output = view["outputs"][0]
    expect(output["address"], ADDRESS, f"{name}: output address")
    expect(absent_field in output, False, f"{name}: unexpected {absent_field!r} field")
    expect(output[value_field], ASSETS, f"{name}: exact seven-token, zero-ADA assets")
    expect(output["datum"], None, f"{name}: datum")
    expect(output["reference script"], None, f"{name}: reference script")
    print(f"PASS: CLI {name} construction preserves output kind, address, assets, input and fee",
          flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    options = ["--project-file=cabal.project.minutxo-cli",
               "--builddir=.workspace/minutxo-incremental/build"]
    if args.offline:
        options.append("--offline")
    try:
        run(directory, "cli-build", ["cabal", "build", *options, CLI_TARGET])
        cli = run(directory, "cli-list-bin", ["cabal", "list-bin", *options, CLI_TARGET]).strip()
        check_output(directory, cli, "implicit", "--tx-out", "amount", "application assets")
        check_output(directory, cli, "store-backed", "--tx-out-store-backed",
                     "application assets", "amount")
    except CommandFailed as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return error.returncode if error.returncode > 0 else 128 - error.returncode
    except (OSError, RuntimeError, ValueError, KeyError, TypeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
