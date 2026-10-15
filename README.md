# Incremental minUTxO writer integration

This workspace tests how the minUTxO ledger change affects transaction-writing
code in `cardano-api`, `cardano-cli`, `cardano-wallet`, and
`cardano-balance-transaction`. Use this checkout and its declared submodules.

The working branch is `minutxo-incremental`. The API is based on its historical
prototype revision `cc614415bb588ab496ab34924c1b076bf1af59c3`, with focused
compilation adaptations, store-backed output construction, read-back, and nested
transaction construction for the existing `v2-minutxo` ledger pin. Other
downstream components retain their original pins and have not been tested in
this step.
The previous combined implementation is preserved separately. New work stays
staged for review until a commit is explicitly requested.

**Current checkpoint:** Nicolas's ledger has been pulled to `0675bed39`.
The funding command is now RED at API compilation because the deposit
declaration interface changed. Earlier green results below used ledger
`8352f9600`; transaction assertions have not run against the new pin.

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
the parent or by an ADA-only sibling. `serialisation` checks that both complete
unsigned parent transactions survive a CBOR round-trip through the public API.
`signing` requests signatures on the children before assembling and signing
each parent, using generated test keys.
`node-build` separately compiles the prototype node and its RPC dependency;
it does not start a node or submit a transaction.
`node` starts a fresh private node and checks that Dijkstra blocks advance.
`node-transaction` additionally submits an ordinary ADA transfer and checks its
resulting UTxO.
`node-token-funding` prepares two real token-only, store-backed inputs for the
nested examples, paying an explicit store deposit and requiring chain inclusion.

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
| Token child | Token-only input and output; requests `SubTxRequestDepositFromTopTx D` | Same |
| ADA supplier | Parent consumes `D + F` | Second child consumes `D`, with no outputs |
| Parent | One child; declares `DepositToStore D`; pays `F` | Two children; consumes `F`; declares `DepositToStore D`; pays `F` |

In both compositions, the token child explicitly requests the deposit from the
parent, following Nicolas's guidance. The token helper takes the deposit amount
alongside its token-only input and output. In the sibling composition, the ADA
contribution enters the combined transaction's input value; the ADA-only sibling
has no deposit operation. The parent explicitly records `DepositToStore D` once
in both examples. This check inspects the constructed fields, without establishing
deposit-funding enforcement.

The assertions inspect the built bodies for child membership and order, exact
inputs and outputs, token assets, the token child's request for exactly `D`,
absence of an ADA-sibling deposit operation, the parent deposit amount, and the
parent fee. They also check that the fixture supplies exactly the token output,
one deposit, and the fee. The runner saves `nested.log`
and returns the actual build or executable failure. The earlier checks remain
separate components.

The nested builder names (`defaultSubTxBodyContent`, `makeUnsignedSubTx`,
`UnsignedSubTx`, and `setTxSubTransactions`) follow the archived experimental
API. The fields `subTxDepositStoreChange` and `txDepositStoreChange` were proposed
additions at the red checkpoint, absent from both its API and that archive. They carry
`Maybe DepositStoreSubTxChange` and `Maybe DepositStoreChange` respectively.
The test uses ledger lenses only for inspection; it does not construct or patch
ledger transaction bodies to bypass missing API support.

This check targets **construction and representation**. `D` is a fixed declared
amount, not a calculated minimum. The synthetic UTxO is assertion data; no ledger
validation, signing, or submission runs. A later validation step must address
the pinned ledger's accounting gap: `dijkstraProducedValue` and
`localProducedValue` in `eras/dijkstra/impl/src/Cardano/Ledger/Dijkstra/UTxO.hs`
omit deposit-store operations, and its transaction rules do not implement
deposit-store funding enforcement. Construction green alone will not establish
funded minUTxO enforcement.

**Recorded result, 14 October 2026: RED while compiling the new check.**
At checkpoint `6b8d663`, the dependencies and API library built, but compilation
of `Nested.hs` started with:

```text
Not in scope: ‘Exp.defaultSubTxBodyContent’
NB: the module ‘Cardano.Api.Experimental.Tx’ does not export ‘defaultSubTxBodyContent’.
```

The compiler also reported the absent child fields, `UnsignedSubTx`,
`makeUnsignedSubTx`, `setTxSubTransactions`, and both proposed deposit-store
fields. Neither scenario's transaction assertions ran. That step contained no
API or ledger implementation changes: they were at `71666453c` and
`8352f9600` respectively.

| Command | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- |
| `./scripts/check-minutxo nested` | RED, exit 1: missing nested builder API; assertions not run | `run-5s0ftqpo` |
| `./scripts/check-minutxo --offline dependencies` | GREEN, exit 0 | `run-bl4x7_7e` |
| `./scripts/check-minutxo --offline build` | GREEN, exit 0 | `run-vhwxq_4q` |
| `./scripts/check-minutxo --offline transaction` | GREEN, exit 0: ordinary-output assertions passed | `run-yi0x_rge` |
| `./scripts/check-minutxo --offline store-backed` | GREEN, exit 0: construction assertions passed | `run-u5xk6vgd` |
| `./scripts/check-minutxo --offline read-back` | GREEN, exit 0: read-back assertions passed | `run-gw98bv3u` |

Fourmolu's formatting check passes for `Nested.hs`.

### Fixture correction and repeated red

After adding the missing builders, compilation exposed a separate setup mistake
in the check: `AssetName` is a type whose constructor in this API is
`UnsafeAssetName`. The fixture now decodes the same `"offer"` bytes with
`deserialiseFromRawBytes AsAssetName`. That correction preserved the policy ID,
quantity, both scenarios, and every assertion.

The corrected fixture was rerun with `./scripts/check-minutxo nested` against
an isolated `git archive` copy of the declared API submodule at `71666453c`,
using this checkout's ledger and identical runner, project, and manifest.
It remains RED at the missing nested-builder API; assertions did not run
(`run-i7kmckga`, copied into the usual check-log directory). The isolated
comparison is retained in `.workspace/minutxo-nested-baseline-y99lu7x7/`.
The pending API implementation was not overwritten during that comparison.

### Nested construction fix: green for both funding arrangements

**Recorded result, 14 October 2026: GREEN; both scenarios' assertions ran and
passed.** That run used the same corrected fixture and command as the repeated
red above. The runner, manifest, project, and ledger are unchanged.

The focused API changes on top of `71666453c` add a separate Dijkstra
`SubTxBodyContent` with inputs, outputs, and a deposit-store operation. Its
builder creates an unsigned ledger sub-transaction. The parent builder embeds
children in their requested order and preserves its explicit deposit operation.
Fees and children cannot be supplied as child-body fields.

This milestone supports key inputs in children. Script inputs return a typed
unsupported error. Conway rejects nested content and deposit operations.
Both existing balancing entry points also reject nested/deposit-bearing
content: their accounting and witness estimates are not ready for it. These
rejections avoid silently discarding fields or returning the deposit as change;
they do not implement balancing or ledger funding enforcement.

That construction check confirmed seven tokens and zero ADA in the token child's
input and output, the child funding request, one parent deposit, and the fee,
for both parent and sibling funding. The ledger remains at `8352f9600`.

| Command | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- |
| `./scripts/check-minutxo nested` | GREEN, exit 0: both funding scenarios' assertions passed | `run-z7eigs7m` |
| `./scripts/check-minutxo --offline dependencies` | GREEN, exit 0 | `run-tvepsmu7` |
| `./scripts/check-minutxo --offline build` | GREEN, exit 0 | `run-6dlnidnq` |
| `./scripts/check-minutxo --offline transaction` | GREEN, exit 0: ordinary-output assertions passed | `run-9j6g4thz` |
| `./scripts/check-minutxo --offline store-backed` | GREEN, exit 0: construction assertions passed | `run-9f5fa56p` |
| `./scripts/check-minutxo --offline read-back` | GREEN, exit 0: read-back assertions passed | `run-tsuukwxe` |

Seven additional checks passed: ordinary Conway construction, rejection of a
Conway deposit operation, rejection of a native-script child input, and rejection
of deposit-only and nested-only content by each balancing entry point. Their
source, runner, and output are retained in `.workspace/minutxo-nested-boundary/`.
Fourmolu passes for the four changed API files and `Nested.hs`; `git diff --check`
also passes. The source patch, hashes, and verification metadata are retained in
`.workspace/minutxo-nested-green-3uz63ti8/`.

The example now has two explicit entry points: `exampleParentFundsDeposit` and
`exampleSiblingFundsDeposit`. Each shows its input amounts and child list;
the first gives the parent deposit + fee, while the second gives the parent
only the fee and adds an ADA child supplying the deposit. `main` prepares the
token contribution once and passes it unchanged to both examples. Construction
helpers and assertions remain shared, without a funding sum type or branching
inside verification. That split preserved the fixed amounts and all 16
assertions; the helpers do not add balancing or ledger validation.
`./scripts/check-minutxo nested` remained GREEN after the split: both scenarios
passed in `run-sy9bgisk`.

An earlier version explicitly set `subTxDepositStoreChange = Nothing` in the
token contribution. Its helper omitted the deposit amount, and the assertion
checked `SNothing` instead of `SubTxRequestDepositFromTopTx D`. All other
assertions and both funding arrangements were preserved. That version exercised
the API's existing support for an absent operation, without changing the API or
ledger; the red/green logs above used the explicit child request.
`./scripts/check-minutxo nested` was GREEN with the absent operation: both funding
examples passed in `run-jixh3hws`, including the `SNothing` assertion. Fourmolu
and `git diff --check` also passed.

Following Nicolas's guidance, the current example restores
`Just (SubTxRequestDepositFromTopTx D)` on the token contribution and checks the
exact request amount. The ADA-only sibling still uses `Nothing`, and the parent
still records one deposit. This remains a construction check; it does not
establish ledger acceptance or automatic deposit funding.

The same `./scripts/check-minutxo nested` command verified the change: with the
updated assertion alone it failed with expected
`SJust (SubTxRequestDepositFromTopTx (Coin 2000000))`, actual `SNothing`
(`run-16datow4`). After restoring the request, both funding examples passed
(`run-fisd0hgc`). Fourmolu and `git diff --check` also pass.

## Nested transaction serialization

```sh
./scripts/check-minutxo serialisation
```

The separate `checks/transaction/Serialisation.hs` executable reuses the fixture
and builders in `Nested.hs` for both funding arrangements. It encodes each
complete unsigned parent with `Api.serialiseToRawBytes` and decodes it with
`Api.deserialiseFromRawBytes`. This is the existing public CBOR interface for
`UnsignedTx`; the check does not add a serializer or construct ledger bytes by
hand.

The decoded transaction must equal the original, including its children and
their order, store-backed token output, child deposit request, parent deposit,
and fee. Re-encoding must reproduce the same bytes. These are unsigned
transactions with synthetic inputs; the check does not establish signing,
ledger acceptance, or submission support.

`Nested.hs` now declares module `Nested` so the new executable can import its
helpers. The existing `nested` executable still runs `Nested.main` and retains
all its construction assertions. The new component is separate, so a future
serialization failure does not prevent running the earlier checks.

**Recorded result, 14 October 2026: GREEN on the first run, with no API or ledger
changes.** Both funding examples passed in `run-0cxv0e19`; the API remains at
`ab5ae587f` and the ledger at `8352f9600`. The requested check exposed no missing
serialization capability for these examples, so there is no red failure to
record. It is retained as a green baseline.

The existing `./scripts/check-minutxo nested` check also passed both examples
after the module rename (`run-prgj8k_z`). Fourmolu and `git diff --check` pass.

## Signing nested transactions

```sh
./scripts/check-minutxo signing
```

The separate `checks/transaction/Signing.hs` executable requests child signing
through `makeSubTxKeyWitness` and `signSubTx`, then embeds the signed children
before signing the parent. This order matters: the parent's body includes the
child witnesses. Each child needs witnesses over its own body; signing only the
parent does not satisfy the ledger's child witness checks.

This is a prerequisite missing from our historical API baseline, not evidence
of a signing regression caused by minUTxO. `makeSubTxKeyWitness` and `signSubTx`
exist in later experimental API history, introduced by Jordan Millar in
`6d5dee85b`. That implementation returns a raw ledger child; `SignedSubTx` and
`setTxSignedSubTransactions` are convenience wrappers added here. The existing
parent helpers accept only `TopTx`. Lower-level signature primitives exist,
but this check requests the higher-level child API directly instead of
constructing witnesses by hand.

The examples use generated in-memory keys and synthetic transaction inputs.
They require exactly one witness from the expected key on each signed child
and parent, verify each signature against its own transaction body, and check
that signing preserves bodies, deposit operations, and embedded children.
The signed parent must also survive a CBOR round-trip. These assertions concern
the supplied keys, not authority over real UTxOs or full ledger acceptance.
No node is contacted, and no key files are written.

**Recorded result, 14 October 2026: RED while compiling `Signing.hs`.** The
dependencies and API library build, but the new executable reports:

```text
Not in scope: type constructor or class ‘Exp.SignedSubTx’
NB: the module ‘Cardano.Api.Experimental.Tx’ does not export ‘SignedSubTx’.
```

The compiler also reports missing `makeSubTxKeyWitness`, `signSubTx`, and
`setTxSignedSubTransactions`. No signing assertions ran. The red step changed
only the check, runner, manifest, and documentation; the API was at `ab5ae587f`
and the ledger at `8352f9600`. It is committed as `f636338`.

| Command | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- |
| `./scripts/check-minutxo signing` | RED, exit 1: missing child-signing API; assertions not run | `run-35b69u0d` |
| `./scripts/check-minutxo nested` | GREEN, exit 0: both construction examples passed | `run-bxjwzmib` |
| `./scripts/check-minutxo serialisation` | GREEN, exit 0: both unsigned CBOR round-trips passed | `run-wcjvb0e_` |

Fourmolu and `git diff --check` pass. The initial attempt imported an internal
ledger module (`run-gdnygjme`); using its public `Cardano.Ledger.State` reexport
corrected that check setup error before recording the missing-API failure above.

### Signing fix: green with the same check

The focused API change adds `makeSubTxKeyWitness` and `signSubTx`, using the
later implementation as a reference. Each witness signs the child's own body;
attaching witnesses preserves its body and any existing witnesses. The
`SignedSubTx` wrapper and `setTxSignedSubTransactions` setter let the caller
embed finished signed children before signing the parent. All four names are
exported from both `Cardano.Api.Experimental.Tx` and `Cardano.Api.Experimental`.

The fix changes only those two API modules. The ledger, dependencies, and
`Signing.hs` assertions are unchanged. The API fix is committed as `3001ca37b`.

**Recorded result, 15 October 2026: GREEN.** The original signing command now
executes and passes the assertions for both funding arrangements, including
cryptographic signature verification and signed-parent CBOR round-trips.

| Command | Result | Saved run under `.workspace/minutxo-incremental/checks/` |
| --- | --- | --- |
| `./scripts/check-minutxo signing` | GREEN, exit 0: both signed examples passed | `run-64y5wejt` |
| `./scripts/check-minutxo nested` | GREEN, exit 0: both construction examples passed | `run-0zj9a_zu` |
| `./scripts/check-minutxo serialisation` | GREEN, exit 0: both unsigned CBOR round-trips passed | `run-t61isy0e` |

Fourmolu and `git diff --check` pass. These results establish local signing and
serialization, not ownership of real inputs or acceptance by a node.

Node submission remains a separate step after signing is green. A submission
check needs a compatible local prototype node, funded inputs, and their signing
keys. The archived runtime is only a reference; its prior results do not
establish compatibility with the current incremental stack.

## Local node build prerequisite

```sh
git submodule update --init cardano-node
./scripts/check-minutxo node-build
```

The new `cardano-node` submodule pins upstream prototype revision
`648fc48b045148a3b2acc5f3b04b039d50375bfc`. Its API baseline (`8749531d`) differs
from our historical API baseline (`cc614415`) only in `cabal.project`. Its
consensus pin (`02fa2487`) likewise differs from our `e5b82026` only in that
project file. This provides a source-aligned starting point, rather than using
the newer node and compatibility patches from the archived migration.

`cabal.project.minutxo-node` imports the incremental project and adds the node,
its trace libraries, and the current local `cardano-rpc` package. The API,
ledger, and consensus pins remain unchanged. The additional constraints,
`acts` flag, `ekg-forward` pin, and its `allow-older` setting come from the
pinned node's own historical project. Optional systemd integration is disabled
for a directly launched local node.

The existing API and transaction commands retain their original project. Both
projects reuse the incremental build directory; run their checks sequentially.
No archived binaries, sibling checkouts, or source compatibility patches are
used. This prerequisite does not start a node or submit a transaction.

**Recorded result, 15 October 2026: GREEN on the first build.** Dependencies
resolved and the node executable compiled without API, RPC, ledger, consensus,
or node source changes. Log: `run-d5s6xb9j/node-build.log` under
`.workspace/minutxo-incremental/checks/`. The resulting executable reports
`cardano-node 11.1.0.164`, Git revision `648fc48b045148a3b2acc5f3b04b039d50375bfc`.
There is no failing build to manufacture; this is a green infrastructure baseline.

## Local node startup

```sh
./scripts/check-minutxo node
```

After the node build was green, this separate check added a small fixture
generator and a process supervisor. It uses fresh local payment, staking,
pool, KES, and VRF keys and the current API's genesis defaults. A private
testnet starts with one funded stake pool, network magic 42, 0.1-second slots,
500-slot epochs, and the Dijkstra transition at epoch 1.

The node binds to loopback on an ephemeral port, has no configured peers, and
uses a fresh private temporary directory for keys, databases, socket, and logs.
The directory path is printed. The supervisor queries the node through the
public API and requires two increasing block numbers in Dijkstra. It stops its
own node afterward, including on failure, and retains the diagnostic files.
There is no dependency on `cardano-cli` or `cardano-testnet`.

**Recorded result, 15 October 2026: GREEN.** In `run-wrj381ms`, Dijkstra blocks
advanced from 49 to 52 and the node stopped cleanly. The initial helper build
(`run-dei5x515`) had an incorrect import for `unsafeBoundedRational`; correcting
it to the API export fixed the test setup. No node or ledger implementation
change was needed. This check does not submit transactions.

## Ordinary ADA submission baseline

```sh
./scripts/check-minutxo node-transaction
```

Added after startup was green, this check starts another fresh node and queries
its real genesis-funded UTxO through the public API. It builds and signs an
ordinary transaction using the generated payment key, sends the remaining ADA
to a fresh recipient after a fixed 1 ADA fee, and submits through
`submitTxToNodeLocal`. The output uses the ordinary implicit-deposit form.

Mempool acceptance is recorded in `ordinary-submitted.json`. Success additionally
requires querying the chain's UTxO state and finding the exact expected recipient
output while confirming that the original input is consumed. That evidence is
saved as `ordinary-included.json` in the printed private node directory. The
supervisor stops its node on success or failure. All funds are created in this
isolated local chain; no external node is used.

Nested transaction submission remains the next transaction capability after
this baseline is green.

**Recorded result, 15 October 2026: GREEN on the first submission run.**
`run-wql7k2j3` reached advancing Dijkstra blocks, submitted transaction
`d8afb769dcaf777be8dc5c8f40438dd729a183c7fa5f8ae8bf77b87aad7abdad`, and verified
that its 900,000,000,000-lovelace input was consumed and its recipient received
899,999,000,000 lovelace after the 1,000,000-lovelace fee. The node then stopped
cleanly. A copy of the non-secret inclusion evidence and node log is saved
alongside `node-transaction.log` under
`.workspace/minutxo-incremental/checks/run-wql7k2j3/`.

This establishes ordinary transaction submission on the prototype. No
additional API, RPC, ledger, consensus, or node implementation fixes were
needed for this baseline. The submodule pin, project, fixture, and checks make
the baseline reproducible from this checkout.

Regression checks also remain green: `dependencies --offline` in `run-vfmqaa4t`
and `signing --offline` in `run-t6r_khgy`. Fourmolu and `git diff --check` pass.

## Fund the inputs for nested submission

```sh
./scripts/check-minutxo node-token-funding
```

The existing nested checks use synthetic inputs. Before submitting those
examples, this prerequisite creates two real token-only inputs on a fresh
private node. [TokenFunding.hs](checks/node/TokenFunding.hs) spends the actual
genesis-funded UTxO and mints 14 native tokens under a policy authorized by its
payment key. It creates two store-backed outputs, each containing 7 tokens and
zero lovelace, and returns the remaining ADA as an ordinary change output.

The transaction declares `DepositToStore 4000000` and deducts that 4 ADA from
change, in addition to the fixed 1 ADA fee. These are manually chosen fixture
amounts, not an automatic calculation of the required deposit or fee. Omitting
the deposit or returning its ADA as change would bypass the funding capability
this check is intended to exercise.

The signed transaction is retained as `token-funding.cbor` in the printed
private node directory. A submission rejection is recorded separately in
`token-funding-rejected.json`. Mempool acceptance produces
`token-funding-submitted.json`; success also requires finding all three exact
outputs in the chain's UTxO and confirming the genesis input is consumed,
recorded in `token-funding-included.json`. The supervisor always stops its node.

This is input preparation only. Neither nested example is submitted by this
command; their submission checks follow after this prerequisite is green.

**Recorded result, 15 October 2026: RED at funding submission.** In
`run-yd4bl5mv`, compilation succeeded and Dijkstra blocks advanced from 48 to
49. The node rejected the funding transaction with `ValueNotConservedUTxO`:

```text
consumed: 900,000,000,000 lovelace + 14 tokens
produced: 899,996,000,000 lovelace + 14 tokens
difference: 4,000,000 lovelace (the declared store deposit)
```

The transaction returns 899,995,000,000 lovelace as change and pays a
1,000,000-lovelace fee. The pinned ledger's
[`dijkstraProducedValue` / `localProducedValue`](cardano-ledger-specs/eras/dijkstra/impl/src/Cardano/Ledger/Dijkstra/UTxO.hs)
omit `DepositToStore` from produced value, so the explicitly paid deposit
causes this mismatch. This is a ledger accounting prerequisite, not a nested
transaction rejection. Neither nested example was submitted or included.
No API, ledger, or node implementation was changed in this red step.

The ledger commit introducing these fields, `ee56dc046`, explicitly implements
interfaces only; it leaves deposit-store state and accounting unimplemented.
Adding the amount to `produced` alone would make this submission check pass
without retaining the deposit anywhere in ledger state. A correct green fix
must also record the deposit in persistent state and conserve total ADA.
The existing `utxosDeposited` field cannot serve as a substitute: Dijkstra's
epoch transition resets it to certificate and governance obligations, and
ADA-pot totals are derived from those obligations. Store allocation and
withdrawal rules need an agreed design before implementing this ledger support.
The current inclusion check alone does not prove deposit retention; verification
of the implementation must also cover state persistence and total ADA.

The node stopped cleanly. Non-secret rejection evidence, signed transaction,
ready-tip evidence, and node log are copied alongside `node-token-funding.log`
under `.workspace/minutxo-incremental/checks/run-yd4bl5mv/`. An initial
`--offline` attempt (`run-gy4u5_12`) stopped at missing cached dependencies;
it did not run transaction assertions. The command above completed the build
and demonstrated the actual submission failure.

The existing `node-transaction --offline` check remains GREEN with the extended
helper (`run-xs7r5jkx`): ordinary ADA submission was accepted and its exact
output and consumed input were verified on-chain. Fourmolu and
`git diff --check` pass.

### Upstream follow-up, 15 October 2026

Fetching Nicolas's `v2-minutxo` branch found tip
`0675bed392b4b5fe43b0c2a233888d18cc49d624`, 16 commits ahead of our pinned
`8352f9600`. His [13 October implementation](https://github.com/nhenin/cardano-ledger-specs/commit/dfdb8d936f19115287a403d74c2479181d614d0f)
adds the missing Store balance, allocations recorded by live output reference,
snapshot persistence, exact batch accounting, and inclusion of Store ADA in
the ledger total. The missing-state diagnosis above applies to our old pin;
we should integrate his implementation instead of creating a competing one.

This requires an API adaptation as well as a ledger pin update: the old
deposit-store operation types and lenses have been replaced by typed TopTx
and SubTx UTxO deposit declarations, with separate absent and explicit-zero
cases. No package-version, dependency-bound, or project-pin changes were found
in the ledger diff. Compilation was untested at the initial source audit;
the subsequent pull and build result are recorded below.

The newer rules require the exact net deposit: newly priced outputs minus
recorded deposits released by consumed inputs. The funding fixture's arbitrary
4 ADA must be replaced by that calculation. A child recreating the same-sized
store-backed output has zero net deposit; to demonstrate additional parent or
sibling funding, the live examples must add capacity, for example by splitting
the token input into two outputs.

The initial follow-up was a source audit only: it left the checkout and submodule
pin unchanged and ran no tests against the newer revision. Upstream's
[verification record](https://github.com/nhenin/cardano-ledger-specs/blob/0675bed392b4b5fe43b0c2a233888d18cc49d624/docs/dijkstra-deposit-store-verification.md#current-implementation-status)
reports 68 implemented business checks and 174 deliberate failing placeholders;
dedicated conservation, epoch and recovery checks are among the unfinished
coverage. Our build, funding, deposit-retention and nested-submission checks
remain necessary.

### Pulled ledger: API compilation red

The original funding red and upstream findings were committed as `d5764fc`
(`red: expose missing deposit-store funding accounting`). The clean ledger
submodule was then fast-forwarded from `8352f9600` to Nicolas's
`0675bed392b4b5fe43b0c2a233888d18cc49d624`, and the same command was rerun:

```sh
./scripts/check-minutxo node-token-funding
```

**Recorded result, 15 October 2026: RED at API compilation, exit 1.**
Dependency resolution succeeded, and the updated ledger and consensus libraries
compiled. The API failed in
`cardano-api/src/Cardano/Api/Experimental/Tx/Internal/BodyContent/New.hs`
at lines 285, 299, 326 and 880: the new ledger no longer exports
`depositStoreChangeTxBodyL`, `DepositStoreSubTxChange`,
`depositStoreSubTxChangeTxBodyL` or `DepositStoreChange`.

The node did not start and no transaction assertions ran. This is a compilation
prerequisite exposed by the ledger update; it neither repeats the old on-chain
funding rejection nor proves that funding now succeeds. No API or fixture
adaptations are included in this step. The complete log, exit summary and
repository revisions are retained in
`.workspace/minutxo-incremental/checks/run-y8uagohj/`.

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

At ledger pin `8352f9600`, the dependency, compilation, ordinary-output,
store-backed construction, read-back, nested construction, nested CBOR round-trip,
and signing checks were green. The update to `0675bed39` is currently red at API
compilation, as recorded above.
Ledger funding enforcement remains a separate capability; construction and
serialization do not establish it.
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
6. Construct token-only children with parent and sibling ADA funding (complete:
   both scenarios are green). Keep the ledger's deposit accounting and funding
   enforcement as a separate step.
7. Round-trip the two nested transactions through CBOR (complete: both are green
   without further API or ledger changes). Other serialization cases and
   minimum ADA for each output kind remain separate steps.
8. Sign the children and then their parent in both nested funding examples
   (complete: the same check is green after the focused child-signing API fix).
9. Establish a compatible local prototype node and ordinary ADA submission
   (complete: node build, startup, and ordinary transfer are green). Fund real
   token-only inputs with `node-token-funding`, then submit the nested examples
   using manually determined fees and deposits; keep input funding separate
   from nested transaction failures.
10. Add automatic balancing, change, and collateral checks as separate
    capabilities. Exercise CLI, Plutus, wallet, and balancer paths with their
    own reproducers.

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
`minutxo-incremental` and run `git submodule update --init` again. These are
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
