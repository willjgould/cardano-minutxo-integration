# Incremental minUTxO writer integration

This workspace tests how the minUTxO ledger change affects transaction-writing
code in `cardano-api`, `cardano-cli`, `cardano-wallet`, and
`cardano-balance-transaction`. Use this checkout and its declared submodules.

The working branch is `work/minutxo-incremental`. The API uses its historical
prototype revision `cc614415bb588ab496ab34924c1b076bf1af59c3`, alongside the
existing `v2-minutxo` ledger pin. Other downstream components retain their
original pins and have not been tested in this step. The previous combined
implementation is preserved separately; production changes have not been
reapplied. New work stays staged for review until a commit is explicitly requested.

## Dependency baseline: green before and after minUTxO

This step asks whether Cabal can resolve `cardano-api:lib:cardano-api` against
the ledger source in this checkout. The runner invokes `cabal build --dry-run`.
GREEN means the dependency plan resolves; it does not establish compilation or
transaction behavior. Build and transaction checks will be introduced in later
red steps and are not included here.

Run the dependency check from the repository root with the declared GHC 9.6.7 shell:

```sh
nix develop
./scripts/check-minutxo --offline dependencies
```

The runner preserves Cabal's exit status and prints a summary. Each run saves
the command, complete output, and summary in a fresh directory under
`.workspace/minutxo-incremental/checks/`, so the red and
green evidence remain available side by side. Terminal colors are cosmetic.

`dependencies` is the only check available in this step and is also the default
when no step argument is given.

`--offline` uses cached package metadata and source repositories. On a fresh
checkout, omit it to fetch the pinned source dependencies first. The project
uses the API and ledger source in this checkout and the historical API's
source pins, package-index dates, constraints, and `allow-newer` settings.
It does not load a prebuilt package environment or patch dependency sources.

**Recorded result, 13 October 2026: the reconstructed older stack resolves
dependencies both before and after minUTxO.**

```text
dependencies           GREEN
```

The same command above, project configuration, API revision `cc614415`, and
GHC 9.6.7 were used for both runs. Only the ledger revision changed:

| Ledger | Revision | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- | --- |
| Parent of the first minUTxO commit | `d93c654699c8f10c883a625168f65dd387abc695` | GREEN, exit 0 | `run-f2xdr5xq` |
| Current minUTxO tip | `8352f9600e06405e4428432bf68fcc126e58a711` | GREEN, exit 0 | `run-atssxtkh` |

The ledger checkout was restored to the minUTxO tip after the comparison.
Both plans select the same package versions, including protocol `0.1.1.0`,
crypto-class `2.6.0.0`, crypto-wrapper `1.7.0.0`, crypton `1.0.6`, and consensus
`3.0.1.0`. Neither run compiled code or executed transaction assertions.
The project snapshot, run metadata, and both plans are retained locally in
`.workspace/older-stack-reconstruction-__sa3b8t/`.

### What the reconstruction preserves

The historical API project pins ledger `daa38fec95ddba68ad4e780b933e7e094d68241d`,
the direct parent of Nicolas's pre-minUTxO base. Their Cabal manifests and
project configuration are identical. The root project substitutes the declared
ledger submodule and keeps the historical API's exact ledger package selection.
This uses published Byron packages, including crypto-wrapper `1.7`, and includes
the test-library packages needed by consensus. Test suites remain disabled.

The remaining source pins come unchanged from that API project's `cabal.project`:

| Dependency | Revision |
| --- | --- |
| cardano-base | `fbfb3f05d8092492f000264edca2d7a1a105741a` |
| typed-protocols | `9b4627221ae5d649f2303c6926a8dba3f9934658` |
| kes-agent | `4e7ec7b5102a030587413f4af770e87a15c9cb9c` |
| ouroboros-network | `4b3ab7664f609a1aee0f0c24dcfcfd0ab899fc42` |
| ouroboros-consensus | `e5b82026e4f3395fbb94f0af62f711655d96fec7` |

The API project's existing `allow-newer: cardano-crypto-class` permits its
pinned crypto-class `2.6` despite the API package's `^>=2.5` bound. Its
`crypton <1.1` constraint selects the older crypto implementation using `memory`.
These settings predate minUTxO (API commit `3654a7b7b1`); the other copied
overrides also predate it. No new bound overrides were introduced. This uses
the older API's cardano-base pin, rather than the different pin in the ledger's
standalone project. Compilation compatibility remains to be checked separately.

The original configuration used API `425f12244` and failed with a protocol
`^>=0.2` versus `0.1.1.0` conflict on both ledger revisions (runs `run-5uj41ml_`
and `run-bfonuthu`). That was a baseline mismatch. The earlier assessment that
the older stack could not resolve overlooked its existing project settings;
the successful reconstruction above corrects that assessment.

## Working one step at a time

For each capability:

1. **Red:** add the smallest direct check, run it, and retain its log. Leave this
   step staged for review. For a transaction assertion to demonstrate red, its
   dependencies and build must already be green.
2. **Green:** after the red step is reviewed, make the focused implementation
   change and rerun the **same command and assertions**. Leave the fix staged
   with its new log for review. Commit only when explicitly requested.
3. Rerun the existing checks to show that earlier capabilities still pass.
4. Introduce the next check in its own red step; do not include future checks
   in an earlier step.

For the current prerequisite step, use
`./scripts/check-minutxo --offline dependencies` before and after the dependency
changes. GREEN means the entire plan resolves. Fixing one version conflict and
encountering another is still RED; it is not a passing test. Once dependencies
are green, add a build check in a new red step. Once the build is green,
introduce the first transaction check. Each check should arrive with its own
reproducer and observed result.

The intended progression is:

1. Reconstruct the API dependency baseline and compare the pre-minUTxO ledger
   with the minUTxO tip (complete: both dependency checks are green).
2. Introduce an API compilation check and address its failures.
3. Introduce an ordinary implicit-output transaction test and make it pass.
4. Add direct construction of a store-backed output and preserve its kind
   through ledger conversion and serialization.
5. Check minimum ADA for each output kind.
6. Add balancing, change, and collateral checks as separate capabilities.
7. Exercise the CLI writer path, then signing and submission; add Plutus
   execution and the wallet/balancer paths with their own reproducers.

Later items are future work, not claims of implemented support. Keep missing
support as a failure; do not add fallback behavior to make a reproducer run.
The old `scripts/workspace` inspection commands belong to the preserved broad
migration and are not the entrypoint for this sequence.

## Preserved work

`archive/minutxo-dependency-red-20261013` preserves root commit `4643c7f`
(`red: dependencies`). That checkpoint was removed from the working branch
after the control run showed its failure also occurs before minUTxO. Its check
is retained unchanged; the corrected findings and scaffold remain staged for
review.

`archive/minutxo-bundle-20261013` exists in the root, API, CLI, and ledger
repositories. The root snapshot pins all three submodule snapshots and includes
the paired Plutus test, runtime setup, dependency patches, and previous README.
The earlier `v2-minutxo` and `v2-minutxo-rpc` branches remain available.

Inspect the previous work without applying it:

```sh
git show archive/minutxo-bundle-20261013:README.md
git -C cardano-api diff HEAD..archive/minutxo-bundle-20261013
```

To select the complete archived workspace:

```sh
git switch archive/minutxo-bundle-20261013
git submodule update --init
```

To return to the incremental workspace, switch the root to
`work/minutxo-incremental` and run `git submodule update --init` again. These are
local branches; they have not been published. Existing ignored build artifacts
are retained, but the new check uses its own build directory.

An additional local recovery copy in
`.workspace/incremental-recovery-07ug6tqd/` contains verified copies of modified
and untracked files, separate staged and unstaged patches, original revisions,
and index listings. This preserves the original staging information as well as
the archived source.

## Clone and shell

```sh
git clone --recurse-submodules https://github.com/willjgould/cardano-minutxo-integration
cd cardano-minutxo-integration
nix develop
```

The root Nix shell supplies GHC and native build libraries; it does not establish
that the downstream packages compile against the ledger. `components.json`
records the original import provenance and baseline pins. New local branches
must be published separately before they are available in a fresh clone.
