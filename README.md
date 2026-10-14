# Incremental minUTxO writer integration

This workspace tests how the minUTxO ledger change affects transaction-writing
code in `cardano-api`, `cardano-cli`, `cardano-wallet`, and
`cardano-balance-transaction`. Use this checkout and its declared submodules.

The working branch is `work/minutxo-incremental`. The API is based on its historical
prototype revision `cc614415bb588ab496ab34924c1b076bf1af59c3`, with focused
compilation adaptations, store-backed output construction, and read-back for the existing
`v2-minutxo` ledger pin. Other downstream
components retain their original pins and have not been tested in this step.
The previous combined implementation is preserved separately. New work stays
staged for review until a commit is explicitly requested.

## Dependency baseline: green before and after minUTxO

This step asks whether Cabal can resolve `cardano-api:lib:cardano-api` against
the ledger source in this checkout. The runner invokes `cabal build --dry-run`.
GREEN means the dependency plan resolves; it does not establish compilation or
transaction behavior. Compilation is checked separately with `build`, below.

Run the dependency check from the repository root with the declared GHC 9.6.7 shell:

```sh
nix develop
./scripts/check-minutxo --offline dependencies
```

The runner preserves Cabal's exit status and prints a summary. Each run saves
the command, complete output, and summary in a fresh directory under
`.workspace/minutxo-incremental/checks/`, so the red and
green evidence remain available side by side. Terminal colors are cosmetic.

`dependencies` is the default when no step argument is given. `build` compiles
the API library; `transaction` builds and runs the local unsigned-body check
for ordinary implicit-deposit outputs. `store-backed` separately checks the
API's ability to construct a store-backed output in an unsigned body.
`read-back` checks that the constructed output can be read back through the API.
`nested` requests a token-only child with deposit funding supplied either by
the parent or by an ADA-only sibling.

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
standalone project. The compilation check below tests this configuration.

The original configuration used API `425f12244` and failed with a protocol
`^>=0.2` versus `0.1.1.0` conflict on both ledger revisions (runs `run-5uj41ml_`
and `run-bfonuthu`). That was a baseline mismatch. The earlier assessment that
the older stack could not resolve overlooked its existing project settings;
the successful reconstruction above corrects that assessment.

## Compilation check

Run from the same GHC 9.6.7 shell:

```sh
./scripts/check-minutxo build
```

This invokes the same Cabal project, build directory, and API library target as
`dependencies`, without `--dry-run`. It downloads any missing package sources
and compiles the required dependencies and API. Add `--offline` once the sources
are cached. The runner retains the full output in `build.log`, writes its
summary alongside it, and returns Cabal's exit status.

GREEN means the API library builds. A dependency compilation failure is RED
even if the compiler has not reached the API itself. Neither outcome establishes
transaction behavior. The red check was committed separately from its compilation
fixes, as recorded below.

**Recorded result, 13 October 2026: GREEN before minUTxO, RED after minUTxO.**
Both runs used the command above, API revision `cc614415`, GHC 9.6.7, and the
same project and runner. Only the ledger revision changed:

| Ledger | Revision | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- | --- |
| Before minUTxO | `d93c654699c8f10c883a625168f65dd387abc695` | GREEN, exit 0: API library built | `run-wgvo6zdz` |
| minUTxO tip | `8352f9600e06405e4428432bf68fcc126e58a711` | RED, exit 1: API compilation failed | `run-ppq22q_t` |

The minUTxO build completed the required ledger and consensus libraries, then
failed in `cardano-api/src/Cardano/Api/Ledger/Internal/Reexport.hs`:

```text
src/Cardano/Api/Ledger/Internal/Reexport.hs:392:5: error:
    Module 'Cardano.Ledger.Core' does not export 'mkBasicTxOut'
```

This is a source compatibility failure exposed by switching to minUTxO.
Commit `1254f0c` records this red checkpoint without compilation fixes. No
transaction assertions ran. Dependency resolution remained green. The ledger
checkout was restored to the minUTxO tip. Full logs, exact revisions, tool versions,
and matching project and runner hashes are retained in
`.workspace/minutxo-build-comparison-ljclibuw/`.

### Compilation fix: green on the same minUTxO ledger

**Recorded result, 13 October 2026: the same build check is now GREEN.**
The API source changes on top of `cc614415` adapt the existing implicit-output
paths to the ledger's new output wrapper:

- Use `mkBasicTxOutWithImplicitDeposit` and the corresponding payload type.
- Read and update values through the implicit payload, preserving the wrapper.
- Apply the ledger's minimum-coin calculation to that payload.

The ledger remains at `8352f9600e06405e4428432bf68fcc126e58a711`. At this green
checkpoint (`65b49f8`), the project, dependency pins, and check script were
unchanged from the red checkpoint.

| Command | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- |
| `./scripts/check-minutxo build` | GREEN, exit 0: API library built | `run-707hob82` |
| `./scripts/check-minutxo --offline dependencies` | GREEN, exit 0 | `run-iutd6r9n` |

Fourmolu's formatting check also passes for all seven changed Haskell files.
The source patch and verification metadata are retained locally in
`.workspace/minutxo-compile-green-20261013/`.

This established compilation only; no transaction assertions ran at that
checkpoint. Store-backed construction and ledger-to-API conversion are covered
by later steps below. JSON, minimum-coin calculation, and balancing still
require separate support; the adapted paths reject unsupported operations
explicitly. Full store-backed writer support remains later work.

## Local transaction construction

Run from the same shell:

```sh
./scripts/check-minutxo transaction
```

This uses `cabal run` to build and execute `checks/transaction/Main.hs` in the
same project and build directory. The new executable depends on this checkout's
API; its dependency pins and library sources are unchanged. Add `--offline`
once the sources needed for the executable are cached.

The check calls the existing public `createTransactionBody` API for Dijkstra
with a synthetic input, an explicit fee, and one ordinary output. It inspects
the resulting ledger body and asserts that it contains exactly one
`ImplicitDepositTxOut`, with 2,000,000 lovelace and no native assets. It uses the
existing API output type so that construction exercises the API-to-ledger
conversion adapted in the previous step.

The executable prints `RUN transaction assertions` when it starts and a `PASS`
line only after construction and all assertions succeed. Cabal/build failures
before that marker mean the transaction assertions did not run. All failures
remain RED, with the full output saved in `transaction.log`.

This checks unsigned transaction-body construction. It does not resolve the
synthetic input against a UTxO set or check balancing, minimum ADA, signing,
serialization, or node acceptance. Those are separate capabilities.

**Recorded result, 13 October 2026: GREEN with no further API or ledger fixes.**
This establishes the working implicit-output baseline before introducing a
store-backed check. The API remains at `31fe7986b`, and the ledger remains at
`8352f9600`.

| Command | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- |
| `./scripts/check-minutxo transaction` | GREEN, exit 0: transaction assertions ran and passed | `run-z1iwx57x` |
| `./scripts/check-minutxo --offline dependencies` | GREEN, exit 0 | `run-gux25kb1` |
| `./scripts/check-minutxo --offline build` | GREEN, exit 0 | `run-_tzrphu9` |

The initial offline attempt (`run-r5x2jbvu`) stopped because Cabal lacked cached
source packages needed for the executable build. No transaction assertions ran
in that attempt; it is not evidence of missing transaction support. The normal
run above completed the build and assertions without changing the check.

## Store-backed output construction

```sh
./scripts/check-minutxo store-backed
```

This separate executable (`checks/transaction/StoreBacked.hs`) requests a
store-backed output through `Api.TxOutValueStoreBacked` and
`Api.createTransactionBody`. The constructor follows the interface in the
archived implementation; it was absent at the red checkpoint (`f7a1299`).
The check uses the existing ledger `ApplicationAssets` type directly, without
constructing or injecting a ledger output in place of the missing API support.

The check must compile and build a Dijkstra body containing exactly one
`StoreBackedTxOut` with the requested application assets: 2,000,000 lovelace
and no native assets. Those lovelace are application assets, not a capacity
deposit. An implicit output or changed assets must fail the check. Serialization,
minimum-deposit calculation, balancing, and node acceptance remain later steps.

The new executable is a separate Cabal component so the ordinary `transaction`
check remains runnable even when this one cannot compile. Its complete output
is saved in `store-backed.log`. A compilation failure means its transaction
assertions have not run; the same command must eventually compile and pass all
assertions to demonstrate green.

**Recorded result, 13 October 2026: RED while compiling the new check.**
The API library builds, but the new executable reports:

```text
StoreBacked.hs:44:12: error: [GHC-76037]
    Not in scope: data constructor ‘Api.TxOutValueStoreBacked’
    NB: the module ‘Cardano.Api’ does not export ‘TxOutValueStoreBacked’.
```

No store-backed transaction assertions ran at that checkpoint. The red step
included no API or ledger implementation changes; their revisions were
`31fe7986b` and `8352f9600` respectively.

| Command | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- |
| `./scripts/check-minutxo store-backed` | RED, exit 1: missing API constructor; assertions not run | `run-lvq2lbtf` |
| `./scripts/check-minutxo --offline dependencies` | GREEN, exit 0 | `run-cwvyurnh` |
| `./scripts/check-minutxo --offline build` | GREEN, exit 0 | `run-8svhv4e8` |
| `./scripts/check-minutxo --offline transaction` | GREEN, exit 0: ordinary-output assertions passed | `run-_8dnhtr_` |

### Store-backed construction fix: green with the same check

**Recorded result, 13 October 2026: GREEN; the store-backed assertions now run
and pass.** The focused API changes on top of `31fe7986b` add the Dijkstra-only
`TxOutValueStoreBacked` constructor and convert it to a ledger store-backed
output. The basic value projections expose application assets only, excluding
the separate capacity deposit.

Two existing fee calculations now reject store-backed values explicitly where
their old pattern filters would otherwise silently omit them. This does not
implement store-backed balancing. At this checkpoint, JSON encoding,
ledger-to-API conversion, and minimum-coin calculation for these outputs were
explicitly unsupported. The read-back step below adds ledger-to-API conversion.

At this green checkpoint (`0ed36f1`), the test, runner, Cabal project, and
dependency pins were unchanged from the red checkpoint. The ledger remains at
`8352f9600`. The same command now compiles
the check and confirms exactly one store-backed output with the requested
application assets.

| Command | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- |
| `./scripts/check-minutxo store-backed` | GREEN, exit 0: store-backed assertions ran and passed | `run-be_xxd1p` |
| `./scripts/check-minutxo --offline dependencies` | GREEN, exit 0 | `run-gzouhzag` |
| `./scripts/check-minutxo --offline build` | GREEN, exit 0 | `run-9682gshg` |
| `./scripts/check-minutxo --offline transaction` | GREEN, exit 0: ordinary-output assertions passed | `run-ufe14_6o` |

Fourmolu's formatting check passes for both changed Haskell files. This milestone
proves unsigned-body construction and output kind/assets preservation only.
Reverse conversion is covered by the next step. Serialization, minimum ADA,
balancing, and node acceptance need their own checks and implementation steps.

## Store-backed output read-back

```sh
./scripts/check-minutxo read-back
```

The separate `checks/transaction/ReadBack.hs` executable constructs the same
simple store-backed Dijkstra body, then reads its outputs through the public
`getTxBodyContent` API. It requires exactly one `TxOutValueStoreBacked` carrying
2,000,000 lovelace and no native assets. Matching the returned value constructor
forces the lazy ledger-to-API conversion; comparing the application assets
then checks their preservation.

This step covers read-back only. It does not add JSON, CBOR, balancing, or
minimum-ADA checks. The earlier construction checks remain separate and
unchanged. Full output is saved in `read-back.log`; the command returns nonzero
for an unsupported conversion, an assertion failure, or a build failure.

**Recorded result, 13 October 2026: RED at runtime, after successful compilation.**
At the red checkpoint (`8804700`), the executable started, but reading the output
value failed with:

```text
check-store-backed-readback: fromLedgerTxOutValue: store-backed outputs are not supported
```

This was the API's explicit rejection during reverse conversion. The read-back
assertions could not complete; no output-kind or asset comparison passed. It was
not a dependency or compilation failure. The API was at `7072bd8cc` and the
ledger at `8352f9600`; the red step included no implementation changes.

| Command | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- |
| `./scripts/check-minutxo read-back` | RED, exit 1: executable ran; reverse conversion raised an error | `run-xrn9d0ww` |
| `./scripts/check-minutxo --offline dependencies` | GREEN, exit 0 | `run-4sssg1iw` |
| `./scripts/check-minutxo --offline build` | GREEN, exit 0 | `run-4yluiyo4` |
| `./scripts/check-minutxo --offline transaction` | GREEN, exit 0: ordinary-output assertions passed | `run-6cadbrqq` |
| `./scripts/check-minutxo --offline store-backed` | GREEN, exit 0: construction assertions passed | `run-1l4kq4er` |

### Read-back fix: green with the same check

**Recorded result, 13 October 2026: GREEN; the read-back assertions now run and
pass.** The focused change to `fromLedgerTxOutValue` converts a Dijkstra ledger
store-backed output to `TxOutValueStoreBacked`, retaining its application assets.
The existing implicit-output conversion is unchanged.

The check, runner, Cabal project, and dependency pins are unchanged from the red
checkpoint. The API fix is on top of `7072bd8cc`; the ledger remains at
`8352f9600`. The same command now confirms exactly one store-backed output with
the requested application assets after public API read-back.

| Command | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- |
| `./scripts/check-minutxo read-back` | GREEN, exit 0: read-back assertions ran and passed | `run-zgq3xvwt` |
| `./scripts/check-minutxo --offline dependencies` | GREEN, exit 0 | `run-568y3dvv` |
| `./scripts/check-minutxo --offline build` | GREEN, exit 0 | `run-bcf047im` |
| `./scripts/check-minutxo --offline transaction` | GREEN, exit 0: ordinary-output assertions passed | `run-kfacflm0` |
| `./scripts/check-minutxo --offline store-backed` | GREEN, exit 0: construction assertions passed | `run-tvj2hsa2` |

Fourmolu's formatting check passes for the single changed Haskell file. This
establishes output-kind and application-assets preservation through body
construction and read-back. Serialization, minimum ADA, balancing, and node
acceptance still require separate checks.

## Nested token-only output with separate deposit funding

```sh
./scripts/check-minutxo nested
```

The separate `checks/transaction/Nested.hs` executable requests both compositions
through the public experimental API. Each has a child spending and producing
exactly seven native tokens with **zero ADA**, using a store-backed output.
The synthetic UTxO supplies the input values, so the check can verify what each
child offers as well as what it produces.

Both examples use a declared deposit `D = 2,000,000` lovelace and a fee
`F = 200,000` lovelace:

| Component | Parent funds the deposit | Sibling supplies the ADA |
| --- | --- | --- |
| Token child | Token-only input and output; requests `D` from parent | Same |
| ADA supplier | Parent consumes `D + F` | Second child consumes `D`, with no outputs |
| Parent | One child; declares `DepositToStore D`; pays `F` | Two children; consumes `F`; declares `DepositToStore D`; pays `F` |

In the sibling composition, the ADA contribution enters the combined
transaction's input value. The parent handles the token child's explicit
`SubTxRequestDepositFromTopTx D`. The supplier child has no deposit operation;
the parent records the deposit once. Absence of a child operation does not
implicitly request delegation.

The assertions inspect the built bodies for child membership and order, exact
inputs and outputs, token assets, the request and deposit amounts, and the
parent fee. They also check that the fixture supplies exactly the token output,
one deposit, and the fee. The runner saves `nested.log` and returns the actual
build or executable failure. The earlier checks remain separate components.

The nested builder names (`defaultSubTxBodyContent`, `makeUnsignedSubTx`,
`UnsignedSubTx`, and `setTxSubTransactions`) follow the archived experimental
API. The fields `subTxDepositStoreChange` and `txDepositStoreChange` are proposed
additions, absent from both the current API and that archive. They carry
`Maybe DepositStoreSubTxChange` and `Maybe DepositStoreChange` respectively.
The test uses ledger lenses only for inspection; it does not construct or patch
ledger transaction bodies to bypass missing API support.

This check targets **construction and representation**. `D` is a fixed declared
amount, not a calculated minimum. The synthetic UTxO is assertion data; no ledger
validation, signing, or submission runs. A later validation step must address
the pinned ledger's accounting gap: `dijkstraProducedValue` and
`localProducedValue` in `eras/dijkstra/impl/src/Cardano/Ledger/Dijkstra/UTxO.hs`
omit deposit-store operations, and its transaction rules do not enforce the
child funding request. Construction green alone will not establish funded
minUTxO enforcement.

**Recorded result, 14 October 2026: RED while compiling the new check.**
The dependencies and API library build, but compilation of `Nested.hs` starts
with:

```text
Not in scope: ‘Exp.defaultSubTxBodyContent’
NB: the module ‘Cardano.Api.Experimental.Tx’ does not export ‘defaultSubTxBodyContent’.
```

The compiler also reports the absent child fields, `UnsignedSubTx`,
`makeUnsignedSubTx`, `setTxSubTransactions`, and both proposed deposit-store
fields. Neither scenario's transaction assertions ran. This step contains no
API or ledger implementation changes: they remain at `71666453c` and
`8352f9600` respectively. Green must use the same command and pass both scenarios.

| Command | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- |
| `./scripts/check-minutxo nested` | RED, exit 1: missing nested builder API; assertions not run | `run-5s0ftqpo` |
| `./scripts/check-minutxo --offline dependencies` | GREEN, exit 0 | `run-bl4x7_7e` |
| `./scripts/check-minutxo --offline build` | GREEN, exit 0 | `run-vhwxq_4q` |
| `./scripts/check-minutxo --offline transaction` | GREEN, exit 0: ordinary-output assertions passed | `run-yi0x_rge` |
| `./scripts/check-minutxo --offline store-backed` | GREEN, exit 0: construction assertions passed | `run-u5xk6vgd` |
| `./scripts/check-minutxo --offline read-back` | GREEN, exit 0: read-back assertions passed | `run-gw98bv3u` |

Fourmolu's formatting check passes for `Nested.hs`.

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

The dependency, compilation, ordinary-output, store-backed construction, and
read-back checks are green. The nested check is red at missing public API
construction support. This capability now precedes serialization.
Retain the existing checks as the sequence advances. Fixing one compiler error
and encountering another is still RED; it is not a passing build. A check that
already passes establishes a baseline; do not manufacture a failure. Each new
check should arrive with its own reproducer and observed result.

The intended progression is:

1. Reconstruct the API dependency baseline and compare the pre-minUTxO ledger
   with the minUTxO tip (complete: both dependency checks are green).
2. Run the API compilation check, then address its failures in a separate green
   step (complete: the same check is green with the focused API adaptations).
3. Introduce an ordinary implicit-output transaction test (complete: green
   baseline without further implementation changes).
4. Add direct construction of a store-backed output and preserve its kind and
   application assets through API-to-ledger conversion (complete: the same
   store-backed check is green).
5. Read store-backed outputs back through the API (complete: the same read-back
   check is green).
6. Construct token-only children with parent and sibling ADA funding (current
   red: missing public API builders). Keep the ledger's deposit accounting and
   funding enforcement as a separate step.
7. Check serialization and minimum ADA for each output kind in separate steps.
8. Add balancing, change, and collateral checks as separate capabilities.
9. Exercise the CLI writer path, then signing and submission; add Plutus
   execution and the wallet/balancer paths with their own reproducers.

Later items are future work, not claims of implemented support. Keep missing
support as a failure; do not add fallback behavior to make a reproducer run.
The old `scripts/workspace` inspection commands belong to the preserved broad
migration and are not the entrypoint for this sequence.

## Preserved work

`archive/minutxo-dependency-red-20261013` preserves root commit `4643c7f`
(`red: dependencies`). That checkpoint was removed from the working branch
after the control run showed its failure also occurs before minUTxO. The
dependency baseline was subsequently reconstructed and committed as `f14f211`
(`dependencies green`). The dependency check's command and default behavior
are retained as the runner gains additional stages.

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
