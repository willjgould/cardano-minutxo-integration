# minUTxO writer integration workspace

This repository pins the ledger and transaction-writing projects as Git submodules:

| Directory | Purpose and current scope |
| --- | --- |
| `cardano-ledger-specs` | The implicit/store-backed output implementation. |
| `cardano-api` | Local output-model, conversion and minimum-ADA migration, with focused checks. |
| `cardano-cli` | Existing compatibility changes; direct store-backed output selection remains outstanding. |
| `cardano-wallet` | Sources for the identified wallet migration; a full migration/build is outstanding. |
| `cardano-balance-transaction` | Sources for output-kind preservation and minimum-ADA validation changes; a full migration/build is outstanding. |

The submodule commits record the source versions. They do not establish that all five projects build together. The API entrypoint retains the dependency closure used by the most recent API checks. The CLI entrypoint attempts to combine the CLI with that closure. Wallet/balancer integration remains separate work.

## Local commands

Run these commands from the repository root after initializing the submodules. Python 3, Git and Nix with `nix-command`/`flakes` enabled are required. Builds use the ledger's pinned compiler and native dependencies. Dependency preparation may download checksum-verified package archives when they are not already cached.

```sh
./scripts/workspace status
./scripts/workspace shell
./scripts/workspace shell -- --command ghc --numeric-version
./scripts/workspace prepare
./scripts/workspace build-api
./scripts/workspace test-api-focused
```

Build/check commands enter the pinned shell automatically and prepare their dependencies. Additional Cabal options follow `--`; for example:

```sh
./scripts/workspace --jobs 6 build-api -- --offline
./scripts/workspace --dry-run build-cli
```

`test-api-focused` uses the same selection previously recorded as 27 passing API tests:

```text
--pattern=/OutputVariants/||/MixedOutputInspection/||/DepositStoreInspection/||/Collateral/
```

Those were results from the prior inspection checkout. Run the command here to validate the pinned workspace in its new location.

## Additional checks

```sh
./scripts/workspace check-collateral
./scripts/workspace build-cli
```

The collateral check exercises API construction and full ledger validation. Its recorded outcome was 50 constructed cases, 34 successful ledger checks and 16 failures in the unfinished store-backed collateral rule. It preserves the failing exit code and saves detailed results in `cardano-api/dist-newstyle/v2-minutxo-collateral-check/`; it does not silently accept known failures.

`build-cli` generates `.workspace/cabal.project.cli`, imports the API's `cabal.project.collateral`, and adds the CLI package with explicit dependency-bound relaxations. It uses `--project-dir=cardano-api` because imported Cabal package paths resolve against the project directory. This configuration is relocatable. The prior successful CLI inspection used an older API/dependency closure; further compatibility changes may be required against the current API. A successful CLI build would still not implement the missing output-kind command-line option.

## Dependency preparation and limits

`prepare` runs the API's two existing preparation scripts. They recreate ignored compatibility dependencies under `cardano-api/.inspection-deps`: hash-pinned cardano-addresses with metadata adjustments, two checked copies of ledger packages with BLS test-helper adjustments, and consensus 5.1 with ledger API compatibility adapters. Generated dependencies and build products are not submodules.

The wrapper imports `cardano-api/shell-v2-minutxo.nix` through the root `shell.nix`. This uses relative sibling paths and avoids the earlier inspection's machine-specific API flake input. Use the wrapper for this integration workspace instead of the API's historical default project/flake or the CLI's old inspection project.

No full wallet or balancer build is exposed here. Earlier wallet checks compiled a focused coin-selection adapter only. The node/consensus lifecycle checks used another explicitly recorded dependency closure and are not rerun by these writer commands. This workspace does not claim whole-node performance, LSM storage, database-upgrade or deposit-store accounting coverage.

## Branches and preservation

Each initialized submodule has a local `v2-minutxo` branch. The parent pins its
exact commit; `components.json` records the inspected upstream bases and imported
source changes. Ledger and balancer production sources are unchanged.

The RPC output-kind fix is kept as separate commits on the API's
`v2-minutxo-rpc` branch, based on its writer branch. To review it locally:

```sh
git -C cardano-api diff v2-minutxo..v2-minutxo-rpc
```

Original repositories, their branches, stashes and staging were left intact.
Exact index/worktree patches and untracked-source backups are stored locally in
`.git/import-backups/`; those backups are not part of the published repository.
The API's original machine-specific flake changes remain in the import history;
its checked-out flake is restored to upstream. Use `./scripts/workspace shell`
for this migration's shell and build configuration.

## Local fork repositories

Until GitHub forks are created by the user, `.gitmodules` points at sibling bare
repositories in `../cardano-minutxo-forks/`. This supports a local recursive clone
without touching GitHub:

```sh
git -c protocol.file.allow=always clone --recurse-submodules \
  /home/will/git/cardano-minutxo-integration /tmp/cardano-minutxo-clone
```

The user will create the GitHub forks and publish the prepared branches. Then
the parent can record the confirmed fork URLs instead of local URLs. No GitHub
repository creation or publication was performed during setup.

## Historical wallet probe

`scripts/prepare-wallet-deps.py` uses three checksum-pinned cached archives and
the actual sibling balancer submodule. It performs no downloads. The archives
were copied into the ignored wallet dependency cache on this machine; another
checkout needs them supplied with `--archive-cache PATH`.

```sh
python3 scripts/prepare-wallet-deps.py --archive-cache PATH
python3 cardano-wallet/scripts/check-v2-minutxo.py
```

This remains a baseline selection probe and deliberately verifies pristine
balancer sources. Its fixtures and checks must be updated when implementing the
balancer migration. It is not a full wallet/balancer build.
