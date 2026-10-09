# minUTxO writer integration workspace

This repository groups five projects as pinned Git submodules. The ledger stays
on `v2-minutxo`; the downstream projects are checked out on their locally cached
upstream `main` or `master` branches. The integration changes remain committed
on separate branches in each local fork.

| Directory | Checked-out branch | Preserved work |
| --- | --- | --- |
| `cardano-ledger-specs` | `v2-minutxo` | Implicit/store-backed output implementation remains active. |
| `cardano-api` | `master` | Output-model, conversion and minimum-ADA migration on `v2-minutxo`; RPC fix on `v2-minutxo-rpc`. |
| `cardano-cli` | `main` | Compatibility changes and inspection checks on `v2-minutxo`. |
| `cardano-wallet` | `master` | Focused baseline inspection sources/configuration on `v2-minutxo`. |
| `cardano-balance-transaction` | `main` | Original inspected source pin on `v2-minutxo`; no production migration was made. |

These are locally cached branch tips, with no GitHub fetch during setup. The
CLI's cached `main` is dated 2024-07-18. `components.json` records the current
pins, imported source provenance and preserved migration branch commits.

## Root Nix shell

Enter the shell directly from the repository root:

```sh
cd /home/will/git/cardano-minutxo-integration
nix develop
```

To check its compiler without starting an interactive session:

```sh
nix develop --command ghc --numeric-version
```

The root flake uses the pinned sibling ledger's GHC 9.6.7 shell and adds LMDB,
Snappy and Linux liburing. It works independently of which API branch is checked
out. The ledger input uses a relative local Git URL, so the workspace can move
and the root flake works with Nix 2.18's Git submodule handling.

The shell supplies tools and native libraries. It does not establish that the
downstream baseline sources compile against the ledger branch or that all five
projects build together.

```sh
./scripts/workspace status
./scripts/workspace shell
```

## Preserved integration branches

To restore the API inspection changes in this workspace:

```sh
git -C cardano-api switch v2-minutxo
./scripts/workspace build-api
./scripts/workspace test-api-focused
```

For the CLI integration attempt, also restore its preserved branch:

```sh
git -C cardano-cli switch v2-minutxo
./scripts/workspace build-cli
```

The RPC fix is an optional API branch based on its writer migration. To review:

```sh
git -C cardano-api diff v2-minutxo..v2-minutxo-rpc
```

Wallet inspection files can be restored with
`git -C cardano-wallet switch v2-minutxo`. The wallet and balancer production
migrations remain outstanding. Switching submodule branches changes the
working-tree pins; commit the parent gitlinks when you want to record that set.

Original repositories, their branches, stashes and staged RPC fix remain
untouched. Exact source/index backups are stored locally in
`.git/import-backups/`. Generated dependency caches were preserved under the
ignored `.workspace/cache/cardano-api/.inspection-deps/` and
`.workspace/cache/cardano-wallet/.inspection-deps/`; they are inactive while
the downstream baselines are checked out.

## Inspection commands and recorded results

The migration build/check commands require the preserved API branch; they
explain which branch to select if their files are absent on an upstream baseline.
Preparation can download checksum-verified package archives when uncached.

The API commands retain the dependency closure from the latest inspection:
API 11.8 and adapted consensus 5.1. The focused selection previously passed
27 tests in the original inspection checkout. The collateral probe constructed
50 cases: 34 ledger checks passed and 16 failed in the unfinished store-backed
collateral rule. Those results have not been rerun in baseline mode.

The CLI entrypoint attempts a build against the API's current inspection
closure. The previous successful CLI inspection used an older closure, so
further compatibility changes may be needed. A build would not implement the
outstanding CLI option for choosing store-backed outputs.

The historical wallet selection probe requires pristine inspected balancer
sources; restore the wallet and balancer `v2-minutxo` branches before using it.
After restoring those branches, its checksum-pinned archives can be prepared
without downloading:

```sh
python3 scripts/prepare-wallet-deps.py \
  --archive-cache .workspace/cache/cardano-wallet/.inspection-deps
```

This is a focused baseline probe, not a full wallet/balancer build. Its fixtures
must be updated when implementing the balancer migration.

## Local fork repositories

`.gitmodules` points at sibling bare repositories in
`../cardano-minutxo-forks/`. The user will create the GitHub forks and publish
the desired branches, then the parent can record their confirmed URLs. No
GitHub repository creation or publication has been performed.

A temporary recursive clone verifies the local source pins:

```sh
git -c protocol.file.allow=always clone --recurse-submodules \
  /home/will/git/cardano-minutxo-integration /tmp/cardano-minutxo-clone
```

The working repository remains under `/home/will/git`; `/tmp` is only the test
clone destination.
