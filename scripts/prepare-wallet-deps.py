#!/usr/bin/env python3
"""Prepare cached sources for the historical, focused wallet selection probe.

This performs no network operations and builds neither the wallet nor the full
balancer. The probe deliberately uses unmodified baseline balancing sources;
future production changes require updating its fixtures and validation first.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile

PINS = {
    "cardano-coin-selection": {
        "revision": "176611048d5b9f33df19d106cd925d63a7858bb2",
        "url": "https://codeload.github.com/cardano-foundation/cardano-coin-selection/tar.gz/176611048d5b9f33df19d106cd925d63a7858bb2",
        "archiveSha256": "24f3a9986a5fdb46ea1c69de97bb7ee2ca9817192386e32b124132526d5adc86",
    },
    "cardano-ledger-read": {
        "revision": "ad4a0d5df468769b30e54e1ab215a9146333721a",
        "url": "https://codeload.github.com/cardano-foundation/cardano-ledger-read/tar.gz/ad4a0d5df468769b30e54e1ab215a9146333721a",
        "archiveSha256": "2c8fbf3eb9485e511625e68af2252ac6a7f21efd352024e9d48a7fabc5158cb2",
    },
    "cardano-balance-transaction": {
        "revision": "6ec3c4d2b3185827e9bd6d1c30e666e1c6056da8",
        "url": "https://codeload.github.com/cardano-foundation/cardano-balance-transaction/tar.gz/6ec3c4d2b3185827e9bd6d1c30e666e1c6056da8",
        "archiveSha256": "230ba796eebff7983c56816a80c351191db57062d2e3797ac749d3b807f4730c",
    },
}
ORIGINALS = {
    Path('/home/will/git/cardano-wallet-v2-minutxo'),
    Path('/home/will/git/cardano-api'),
    Path('/home/will/git/cardano-cli'),
    Path('/home/will/git/cardano-ledger-specs'),
}


def require_new_workspace(workspace):
    wallet = workspace / 'cardano-wallet'
    balance = workspace / 'cardano-balance-transaction'
    for directory in (wallet, balance):
        resolved = directory.resolve()
        if not directory.is_dir() or resolved.parent != workspace:
            raise SystemExit(f'Expected an actual sibling module directory: {directory}')
        if any(resolved == old or old in resolved.parents for old in ORIGINALS):
            raise SystemExit(f'Refusing to modify an original checkout: {directory}')
    deps = wallet / '.inspection-deps'
    if deps.is_symlink():
        raise SystemExit(f'Refusing dependency-directory symlink: {deps}')
    return wallet, balance, deps


def contents(archive_path, name, pin):
    data = archive_path.read_bytes()
    if hashlib.sha256(data).hexdigest() != pin['archiveSha256']:
        raise SystemExit(f'Archive checksum mismatch: {archive_path}')
    files = {}
    prefix = name + '-' + pin['revision']
    with tarfile.open(archive_path) as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != prefix:
                raise SystemExit(f'Unexpected archive path: {member.name}')
            if member.isdir():
                continue
            if not member.isfile() or len(path.parts) < 2:
                raise SystemExit(f'Unsupported archive member: {member.name}')
            rel = Path(*path.parts[1:])
            if rel in files:
                raise SystemExit(f'Duplicate archive member: {member.name}')
            files[rel] = (archive.extractfile(member).read(), member.mode & 0o777)
    return files


def verify_tree(target, files):
    if target.is_symlink() or not target.is_dir():
        raise SystemExit(f'Expected a real source directory: {target}')
    for rel, (data, _) in files.items():
        path = target / rel
        if path.is_symlink() or not path.is_file() or path.read_bytes() != data:
            raise SystemExit(
                f'Historical baseline source differs: {path}\n'
                'Nothing will overwrite it. The focused probe requires pristine pinned sources; '
                'adapt the probe separately when implementing production migrations.'
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--archive-cache', type=Path,
                        help='Read-only directory containing the three pinned .tar.gz archives')
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    wallet, balance, deps = require_new_workspace(workspace)
    archives = {}
    trees = {}
    # Validate all supplied material before creating or copying anything.
    for name, pin in PINS.items():
        destination = deps / (name + '.tar.gz')
        source = destination if destination.is_file() else (
            args.archive_cache / destination.name if args.archive_cache else destination)
        if not source.is_file() or destination.is_symlink():
            raise SystemExit(f'Missing cached archive: {source}\n'
                             'Provide --archive-cache with the three recorded archives. '
                             'This script does not download sources.')
        trees[name] = contents(source, name, pin)
        archives[name] = source
    verify_tree(balance, trees['cardano-balance-transaction'])
    link = deps / 'cardano-balance-transaction'
    if link.is_symlink():
        if link.resolve() != balance:
            raise SystemExit(f'Refusing to replace existing dependency symlink: {link}')
    elif link.exists():
        raise SystemExit(f'Refusing to overwrite existing dependency directory: {link}')
    for name in ('cardano-coin-selection', 'cardano-ledger-read'):
        target = deps / name
        if target.exists() or target.is_symlink():
            verify_tree(target, trees[name])
    provenance = deps / 'provenance.json'
    if provenance.exists():
        if provenance.is_symlink() or json.loads(provenance.read_text()) != PINS:
            raise SystemExit(f'Refusing to replace different provenance: {provenance}')
    deps.mkdir(exist_ok=True)
    for name, source in archives.items():
        destination = deps / (name + '.tar.gz')
        if not destination.exists():
            with destination.open('xb') as output, source.open('rb') as input_file:
                shutil.copyfileobj(input_file, output)
    for name in ('cardano-coin-selection', 'cardano-ledger-read'):
        target = deps / name
        if not target.exists():
            with tempfile.TemporaryDirectory(prefix='prepare-', dir=deps) as staging:
                prepared = Path(staging) / name
                prepared.mkdir()
                for rel, (data, mode) in trees[name].items():
                    path = prepared / rel
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                    path.chmod(mode)
                prepared.rename(target)
    if not link.is_symlink():
        link.symlink_to(os.path.relpath(balance, deps), target_is_directory=True)
    if not provenance.exists():
        with provenance.open('x') as output:
            output.write(json.dumps(PINS, indent=2) + '\n')
    print(f'Historical focused wallet probe dependencies verified: {deps}')
    print('Baseline selection probe only; no full wallet/balancer build or migration claimed.')


if __name__ == '__main__':
    main()
