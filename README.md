# Incremental minUTxO writer integration

This workspace tests how the minUTxO ledger change affects transaction-writing
code in `cardano-api`, `cardano-cli`, `cardano-wallet`, and
`cardano-balance-transaction`. Use this checkout and its declared submodules.

The working branch is `minutxo-incremental`. The API combines upstream Leios
revision `717d326ccb6b0ee1982dfffd2d0cbd4876094666` with our focused minUTxO
adaptations for store-backed output construction, read-back, and deposit
declarations. The node and dependencies follow the matching upstream stack;
the ledger retains Nicolas's `v2-minutxo` work. CLI, wallet, and balancing
components retain their original pins and have not been tested in this step.
The previous combined implementation is preserved separately. New work stays
staged for review until a commit is explicitly requested.

**Current checkpoint: GREEN — store-backed UTxO JSON round-trip.** The unchanged
`./scripts/check-minutxo utxo-json` passed (`run-ykon66uw`), preserving ordinary
and store-backed output kinds and assets. Ordinary JSON keeps its `value`
field; store-backed outputs use `applicationAssets`. The existing `read-back`
regression also passed (`run-35985knr`). This is a local read check, using
synthetic UTxOs without starting a node.

**Previous checkpoint: GREEN — automatic fee/change for direct store-backed
outputs.** The unchanged `./scripts/check-minutxo node-token-funding` passed
(`run-7djmx9ww`), including node acceptance, inclusion, exact deposits, epoch
retention and total ADA conservation. The API now applies minimum ADA checks
only to implicit-deposit outputs. Both nested regressions also passed
(`run-vz9bb5wf` and `run-hfxirq3_`). Deposit pricing remains explicit.

**Earlier checkpoint: GREEN — automatic fee/change balancing for both nested
examples.** `./scripts/check-minutxo node-nested-parent` (`run-48lzg7tu`) and
`./scripts/check-minutxo node-nested-sibling` (`run-eufxdic_`) passed with the
same API fix: automatic parent fee/change, preserved signed children and
deposit declarations, node acceptance, inclusion, and exact accounting. The
parent check also passed its ordinary balancing control. Deposit pricing
remains explicit; this step supports signed key-only children.

**Earlier checkpoint: GREEN** on Nicolas's rebased ledger `e5da0be24` with the
aligned upstream stack. The existing live examples now use separate payment
owners: two for `node-nested-parent` (`run-4x_o48y2`) and three for
`node-nested-sibling` (`run-7swr908a`). Both passed input ownership and witness
checks, mempool acceptance, block inclusion, exact UTxO, deposit replacement,
and total ADA conservation. The six local transaction checks passed at the
previous checkpoint. The upstream child-input loading fix is in the ledger
pin; no local ledger patch is applied.

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
`utxo-json` checks the public JSON round-trip for an ordinary UTxO and a mixed
UTxO containing an ordinary output and a token-only store-backed output.
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
nested examples, paying an exact store deposit and requiring chain inclusion,
recorded allocations, and conservation of total ADA across an epoch boundary.
`node-nested-parent` runs that funding prerequisite, then submits one token-only
child whose additional deposit and fee are funded by the parent.

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

## UTxO JSON round-trip

```sh
./scripts/check-minutxo utxo-json
```

[UTxOJson.hs](checks/transaction/UTxOJson.hs) exercises the public `ToJSON` and
`FromJSON` instances of `Api.UTxO Api.DijkstraEra` through `Aeson.encode` and
`Aeson.eitherDecode`. The local fixture uses the same typed UTxO returned by
node queries. It first checks an ordinary 3 ADA output as a control, then a
mixed UTxO containing that output and a store-backed output with seven native
tokens and zero ADA. Full equality requires preservation of both input
references, addresses, output kinds and assets, plus the absent datum and
reference script. No JSON schema is supplied by the test.

**Recorded result, 16 October 2026: RED** (`run-y20syg08`, exit 1). Compilation
and the ordinary UTxO control passed. Encoding the mixed UTxO failed directly:

```text
toJSON TxOutValue: store-backed output JSON is not supported
```

The mixed UTxO was not successfully encoded or decoded; its equality assertion
did not run. The API implementation was unchanged at this red checkpoint.
Green must pass the same check through public JSON encoding and decoding, preserving the store-backed
kind and application assets. This step does not query a live node, encode the
deposit store, or exercise CLI, wallet or indexer readers. The log and tested
source hashes are retained under `.workspace/minutxo-incremental/checks/run-y20syg08/`.

The existing `./scripts/check-minutxo read-back` regression passed
(`run-dvouk859`). Fourmolu, runner syntax and whitespace checks passed.

**Recorded result, 16 October 2026: GREEN** (`run-ykon66uw`, exit 0). The same
check now encodes and decodes both UTxOs and passes both full-equality
assertions. The check, runner and Cabal manifest are unchanged from the red
commit `0b51760`.

The API encodes store-backed outputs with a top-level `applicationAssets`
field, following the ledger's discriminator and retaining the API's asset-map
format. Ordinary outputs keep their existing `value` field. Both transaction
and UTxO output decoders preserve the output kind; standalone store-backed
values use an `applicationAssets` wrapper. Decoding reuses the existing
quantity validation and rejects ambiguous value fields and store-backed
representations before Dijkstra.

The existing `read-back` regression passed (`run-35985knr`). Supplemental local
checks passed for both output contexts, standalone values, the unchanged
ordinary JSON schema, and rejection of ambiguous, nested and pre-Dijkstra
representations and negative, fractional or overflowing quantities. Evidence,
the API diff, and source hashes are saved under
`.workspace/minutxo-incremental/checks/run-ykon66uw/`. These results cover local
JSON conversion; they do not add live queries or deposit-store JSON support.

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

The fixture queries the node's protocol parameters and uses the ledger's
`requiredUTxODeposit` to price each serialized store-backed output. It supplies
their sum through `txNetUTxODepositChange` as
`DeclaresNetUTxODepositAllocation`. It now asks `makeTransactionBodyAutoBalance`
to calculate the fee and change, supplying only the two token outputs and the
live input UTxO. The returned body must preserve both outputs, the input and
deposit declaration, and add exactly one ordinary ADA change output satisfying
`input = fee + deposit + change`. Deposit pricing remains explicit. Earlier
checkpoints used a fixed 1 ADA fee and manually calculated change; the new
automatic-balancing step is recorded below.

The signed transaction is retained as `token-funding.cbor` in the printed
private node directory. A submission rejection is recorded separately in
`token-funding-rejected.json`. Mempool acceptance produces
`token-funding-submitted.json`; success also requires finding all three exact
outputs in the chain's UTxO and confirming the genesis input is consumed,
then checking the Store balance and both allocation records. The check also
requires unchanged total ADA at inclusion and in the next epoch, with both
allocations still present. `token-funding-included.json` records those results.
Consensus keeps UTxO tables outside its debug ledger state, so both are queried
at one acquired point before summing all ADA pots. The supervisor always stops
its node.

This is input preparation only. Neither nested example is submitted by this
command; their submission checks follow after this prerequisite is green.

**Original result, 15 October 2026: RED at funding submission.** In
`run-yd4bl5mv`, compilation succeeded and Dijkstra blocks advanced from 48 to
49. The node rejected the funding transaction with `ValueNotConservedUTxO`:

```text
consumed: 900,000,000,000 lovelace + 14 tokens
produced: 899,996,000,000 lovelace + 14 tokens
difference: 4,000,000 lovelace (the declared store deposit)
```

The original fixture declares `DepositToStore 4000000`, returns
899,995,000,000 lovelace as change and pays a 1,000,000-lovelace fee. Ledger
`8352f9600`'s
[`dijkstraProducedValue` / `localProducedValue`](https://github.com/nhenin/cardano-ledger-specs/blob/8352f9600e06405e4428432bf68fcc126e58a711/eras/dijkstra/impl/src/Cardano/Ledger/Dijkstra/UTxO.hs)
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
withdrawal rules needed an agreed design before implementing this ledger support;
the subsequent upstream implementation is described below. The original
inclusion check alone did not prove deposit retention, so verification now also
covers the stored allocations and total ADA across an epoch boundary.

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

The ledger update and this compilation red were committed as `40bb5b0`
(`red: update ledger to recorded deposit-store accounting`). The ledger itself
was fast-forwarded; there was no merge commit inside the submodule.

### Adapt declarations and calculate exact funding

The API now passes `TopTxUTxODepositDeclaration` and
`SubTxUTxODepositDeclaration` through `txNetUTxODepositChange` and
`subTxNetUTxODepositChange`. Defaults use `NoUTxODepositDeclaration`; explicit
declarations are still rejected in Conway and by automatic balancing. The
existing nested construction and signing fixtures use the new constructors
and `StrictlyPositiveCoin` for positive amounts. These names supersede the old
operation types in the historical steps above.

With compilation restored, the same funding check reached the node but remained
RED in `run-5i9z7ihx`: the old fixture declared 4,000,000 lovelace while the
updated ledger required 2,267,060. Its rejection was
`InexactTopTxDepositChange (Coin 4000000) (Coin 2267060)`. The fix prices the two
outputs using the queried protocol parameters and deducts their exact deposit
from change. No further ledger, consensus, RPC, node, or dependency changes
were needed for the API and fixture adaptation.

**Recorded result, 15 October 2026: GREEN, exit 0**, using the same command:

```sh
./scripts/check-minutxo node-token-funding
```

Run `run-zkgbxt32` verified the genesis input was consumed and all three outputs
matched. Each token-only output received a recorded allocation of 1,133,530
lovelace, for a Store balance of 2,267,060. Both records and the balance were
unchanged from inclusion in epoch 1 to epoch 2. Total ADA was
1,000,000,400,000 lovelace before submission, at inclusion, and after the epoch
transition. Change was 899,996,732,940 lovelace after the deposit and 1 ADA fee.
The node stopped cleanly.

The run directory retains the command log, summary, non-secret submission and
inclusion evidence, signed CBOR, node log, revisions, and the tested API/check
patches. During development, `run-374yfm8n` included the funding transaction but
failed the new ADA-total assertion because the debug-state query omitted UTxO
tables. Querying both components at one acquired point corrected that test;
the failure was not evidence of ADA creation by the ledger.

The construction fixtures retain their synthetic inputs and chosen amounts;
they are not live-valid examples under the new net-deposit rules. Their future
submission step must account for released input allocations and create a
positive net capacity increase to demonstrate parent or sibling funding.

All existing regression checks also passed on ledger `0675bed39` with this API
adaptation. Saved runs are under `.workspace/minutxo-incremental/checks/`:

| Check | GREEN run |
| --- | --- |
| Ordinary node submission | `run-p1krriey` |
| Dependency resolution | `run-129mnv1y` |
| API compilation | `run-0dvc2_zd` |
| Ordinary transaction construction | `run-u1534uqh` |
| Store-backed construction | `run-vf6ix7t4` |
| Store-backed read-back | `run-n9r_c1rm` |
| Both nested constructions | `run-so25bfka` |
| Both nested CBOR round-trips | `run-7yhbpttx` |
| Both nested signing examples | `run-1hjn5010` |

Fourmolu and `git diff --check` pass.

## Submit a parent-funded nested transaction

```sh
./scripts/check-minutxo node-nested-parent
```

This starts a fresh private node and runs the existing funding check first.
[NestedParent.hs](checks/node/NestedParent.hs) then consumes one of the two
seven-token outputs in a child and creates two token-only outputs containing
three and four tokens. The other funded token output remains untouched.

The child requests only the additional capacity deposit: the prices of its two
new outputs minus the recorded allocation released by its consumed input.
The parent spends the funding transaction's ordinary ADA change, declares that
net deposit, and asks `makeTransactionBodyAutoBalance` to calculate its fee and
change. Deposit pricing remains explicit. The child is signed by the token
owner before it is embedded in the parent, which is
signed by a different payment key. The check verifies each input's ownership
and requires exactly that owner's valid witness on its own transaction body;
balancing must preserve the signed child and the deposit declaration.

First, an ordinary 10 ADA payment exercises the same balancer using a live
ADA input. This construction-only control verifies the computed fee, change,
and ADA conservation, saving `ordinary-autobalance.json`. It is not submitted,
so the input remains available for the nested example.

Success requires block inclusion, the exact whole UTxO (including consumption
of both inputs), and the expected deposit store: remove the spent token input's
allocation, retain the untouched allocation, and add records for the two child
outputs under the child's transaction ID. Total ADA must remain unchanged.
Submission and inclusion evidence are saved separately as
`nested-parent-submitted.json` and `nested-parent-included.json`; a rejection
is saved as `nested-parent-rejected.json`. The signed parent, including its
child, is saved as `nested-parent.cbor`. The supervisor always stops its node.

This step adds only the parent-funded submission check. The sibling-funded
submission check follows once this check is green.

**Recorded result, 15 October 2026: RED at nested submission, exit 1.** In
`run-nq_rvx7s`, compilation succeeded, Dijkstra blocks advanced from 37 to 38,
and the funding prerequisite passed, including deposit retention through the
next epoch and conserved total ADA. The nested transaction then failed with:

```text
SubBadInputsUTxO: funding transaction's output #0 (the child's token input)
ValueNotConservedUTxO:
  consumed: 899,996,732,940 lovelace
  produced: 899,996,732,940 lovelace + 7 tokens
```

The child input exists in the queried chain UTxO and has a recorded allocation
of 1,133,530 lovelace. Its two new outputs require 2,267,060 in total, so the
parent funds a net 1,133,530 plus the 1,000,000-lovelace fee. The ADA amounts
balance; the node's validation view is missing the child's input and tokens.

Source review identifies the input-loading gap:
[`allInputsTxBodyF`](cardano-ledger-specs/eras/dijkstra/impl/src/Cardano/Ledger/Dijkstra/TxBody.hs)
still uses Babbage's enumeration of only the parent's spending, collateral and
reference inputs. Consensus uses that getter to load UTxO tables for mempool
validation, and `neededTxInsForBlock` also uses it for block validation. Child
inputs are omitted. The check leaves the token input solely in the child;
adding it as a parent reference input would conceal the missing support.

That run rejected the nested transaction before inclusion, so its inclusion,
deposit-replacement and conservation assertions did not run. The private
node stopped cleanly. The run directory contains the log and summary, funding
inclusion evidence, nested rejection, signed CBOR, node log, and revisions.
Fourmolu and `git diff --check` pass. No API, ledger, consensus or node support
fix is included in this new check.

**Temporary upstream-fix experiment, 15 October 2026: GREEN, exit 0.** A local
backport of upstream commit
[`027026061`](https://github.com/IntersectMBO/cardano-ledger/commit/027026061e1de792ff8fb6329df4efb27355907d)
("Switch `allInputsTxBodyF` to look into sub-transactions") made the unchanged
`node-nested-parent` check pass in `run-ynzr22q3`. The parent was accepted into
the mempool and included in a block. Both inputs were consumed, the child
created its three-token and four-token outputs, and the whole UTxO matched.
The Store balance increased from 2,267,060 to 3,400,590 lovelace with the expected
replacement allocations. Total ADA remained 1,000,000,400,000 lovelace.

The temporary backport preserved Nicolas's deposit accounting. It was then
removed, and the original source and staging state were verified as restored.
The ledger pin remains `0675bed39`, so this committed checkpoint retains the
red reproducer. The experiment's patch, adaptations, inclusion evidence, and
restoration record are saved under
`.workspace/minutxo-incremental/checks/run-ynzr22q3/`.

## Pull Nicolas's rebased ledger

On 16 October 2026, Nicolas's `v2-minutxo` branch was rebased from `0675bed39`
to `e5da0be244308c217a9b0eecf221c797f4176f44`. The clean ledger checkout was
aligned with that rewritten branch, preserving the old revision under
`refs/backup/minutxo-before-rebase-20261016-0675bed39`. The parent submodule
pointer and this result were left staged at this pull checkpoint; no ledger
merge commit was created.

The new history includes upstream `027026061`, so the child-input loading fix
is now part of Nicolas's branch. It also updates the ledger package baseline,
including `cardano-ledger-api` 1.16, ledger core 1.23, Dijkstra 0.5, and
`cardano-protocol` 0.3. At this pull checkpoint, the integration's API and other
dependency pins were unchanged.

**Recorded result, 16 October 2026: RED at dependency resolution, exit 1**, using
the same command:

```sh
./scripts/check-minutxo node-nested-parent
```

Run `run-yblpntxa` stopped with:

```text
rejecting: cardano-ledger-api-1.16.0.0
  (conflict: cardano-api => cardano-ledger-api^>=1.15)
```

Compilation did not start, the node did not start, and no transaction assertions
ran. This is a dependency-alignment prerequisite; it does not reproduce the old
missing-child-input rejection or establish green on the new ledger. The log,
summary, and repository revisions are retained in
`.workspace/minutxo-incremental/checks/run-yblpntxa/`.

## Align the stack with the rebased ledger

The newer ledger requires a newer consensus/protocol interface, not just a
relaxed API version bound. Its upstream ancestor `8a15ddc07` has exactly the
same Git tree as official ledger `505fa72260632fca6df33e18e18719730bf9a460`.
That identifies the matching upstream Leios stack:

| Component | Revision |
| --- | --- |
| Nicolas's ledger | `e5da0be244308c217a9b0eecf221c797f4176f44` |
| API upstream baseline | `717d326ccb6b0ee1982dfffd2d0cbd4876094666` |
| API integration merge | `279943133` |
| Node | `715b8d2a649e1b97263b3854127d3cff5b09ab8e` |
| Consensus | `5cc95f4caf294751318f8637ab2fb60d5de6eb29` |
| Network | `96ee6e0e689770b5a3d664c59f2d13b05c5d9c4d` |
| Base | `c1e1ed8d7ae39c111c73fc5f59ac37ce5933b83c` |
| Keys | `f89a91b41ff171dd062a0cae0e93b8b999fedf40` |
| Config | `3ea0916679922c0694e4835d2491c3ae9146d037` |

The projects use these pins, the upstream package-index dates and its targeted
dependency-bound exceptions. The API merge retains our minUTxO adaptations;
upstream now supplies the nested construction and signing implementation.
No local ledger or node source patch was needed for this alignment.

**Dependency result, 16 October 2026: GREEN**, using
`./scripts/check-minutxo dependencies` (`run-91015a42`).

**API compilation result: GREEN**, using `./scripts/check-minutxo build`
(`run-vib_vaaz`). The ledger and matching consensus libraries compiled without
source patches.

Two integration regressions were exposed before the final green:

- `node-nested-parent` (`run-npubchpk`) built successfully but stopped at node
  startup. The merged API used the ledger's full testing cost model (369
  parameters) for Dijkstra genesis, whose decoder requires 251 initial
  parameters. Restoring the API's existing genesis-sized `testingCostModelV4`
  fixed this; no transaction assertions ran in that failed attempt.
- `transaction --offline` (`run-tdyqb8zg`) stopped during check compilation:
  `Cardano.Api.Ledger.valueTxOutL` was missing from the merged reexports. Its
  standalone export was restored for the implicit-deposit output interface.

**Live nested-submission result: GREEN**, using the same
`./scripts/check-minutxo node-nested-parent` command (`run-y3u_dr9h`). The node
accepted and included parent transaction
`980fec6f1b0fe1bb592479092ac445c4380de630ad19d3d92bfacd92f3261b77`.
The child spent its seven-token, zero-ADA input and created three-token and
four-token, zero-ADA outputs. Both parent and child inputs were consumed and
the whole UTxO matched. The parent supplied the net deposit of 1,133,530
lovelace, the Store balance changed from 2,267,060 to 3,400,590, and total ADA
remained 1,000,000,400,000 lovelace. The funding prerequisite also verified
deposit retention across an epoch. The node was stopped after the check.

All existing local checks passed with `--offline`:

| Check | Green run |
| --- | --- |
| `transaction` | `run-c3ip2dem` |
| `store-backed` | `run-h98anvpl` |
| `read-back` | `run-809q_lfm` |
| `nested` (both examples) | `run-noymu1y9` |
| `serialisation` (both examples) | `run-feknvmt8` |
| `signing` (both examples) | `run-90lanaa7` |

Logs and non-secret inclusion evidence are retained under
`.workspace/minutxo-incremental/checks/`. The API merge is committed as
`279943133`, and the parent records that commit alongside the aligned ledger,
node, and dependency pins. Nothing has been pushed.

## Submit the sibling-funded example

```sh
./scripts/check-minutxo node-nested-sibling
```

[NestedSibling.hs](checks/node/NestedSibling.hs) submits two separately signed
children in one parent transaction. The token child spends seven tokens and
creates two store-backed outputs containing three and four tokens, with zero
ADA in its input and outputs. It explicitly requests its additional capacity
deposit from the parent. The ADA sibling spends an ordinary input worth exactly
that additional deposit, creates no output, and has no deposit-store operation
of its own. The parent records the allocation once; its own input pays only
the fee and returns all remaining ADA as change.

The check first runs the existing token-funding prerequisite, including Store
retention across an epoch. It then submits an ordinary preparation transaction
that splits the funding change into distinct sibling and parent ADA inputs.
Preparation must be included with the exact UTxO, an unchanged Store, and
conserved total ADA before nested submission starts. The deposit is calculated
from the actual token outputs and the node's protocol parameters. Preparation
uses an explicit 1 ADA fixture fee. The nested transaction uses
`makeTransactionBodyAutoBalance` with all three selected input UTxOs and both
signed children to calculate the parent's fee and change. The check requires
the parent to return all its own ADA except that fee, preserving both children
and the explicit deposit declaration.

The nested check requires mempool acceptance and block inclusion, consumption
of all three inputs, the exact token outputs and parent change, retention of
the unused token input, replacement of the spent token's allocation with two
new allocations, and unchanged total ADA across all pots. Evidence is saved as
`sibling-funding-*.json` and `nested-sibling-*.json` in the printed private node
directory, alongside both signed CBOR transactions. Preparation rejection and
nested rejection are reported separately.

The two live examples have separate modules and assembly functions.
[NestedCommon.hs](checks/node/NestedCommon.hs) holds their token-child,
ownership/witness, and inclusion-query helpers. The token owner, ADA sibling,
and parent use three distinct payment keys. Each signs only its own body, and
the check verifies ownership of its live input and its sole valid witness.
The harness holds all three keys; exchanging independently prepared children
between participants and Plutus spending remain untested.

**Initial single-owner result, 16 October 2026: GREEN on the first run**, using
`./scripts/check-minutxo node-nested-sibling --offline` (`run-o05gsqpp`).
The existing implementation already supports this capability; no artificial
red or API, ledger, consensus, or node patch was introduced. The included
transaction is
`fe811db1284d315fffb735729f5e7019708de6cf9fae877351f6a3a3f72e1509`.

- Both children were embedded in the signed parent and all three inputs were
  consumed. The token child spent zero ADA and produced the three-token and
  four-token outputs with zero ADA.
- The ADA sibling supplied 1,133,530 lovelace for the net deposit. The parent's
  own net spend was exactly the 1,000,000-lovelace fee, with change of
  899,993,599,410 lovelace.
- The exact UTxO and allocation map matched. The Store balance increased from
  2,267,060 to 3,400,590 lovelace, and total ADA remained 1,000,000,400,000
  lovelace.

Non-secret submission and inclusion evidence, signed CBOR, and node logs are
retained alongside the check log under
`.workspace/minutxo-incremental/checks/run-o05gsqpp/`. The node stopped after
the check. The existing `node-nested-parent --offline` regression also passed
(`run-i_ysch6h`) after extracting the shared helpers. Fourmolu, Python syntax,
and whitespace checks passed.

**Separate-owner replacement, 16 October 2026: GREEN.** The same commands,
`node-nested-parent --offline` and `node-nested-sibling --offline`, passed as
`run-4x_o48y2` and `run-7swr908a`. Each live input matched its intended owner,
and each body carried exactly that owner's valid witness. Both transactions
were accepted and included, with the existing UTxO, deposit, and ADA assertions
passing. Non-secret evidence is retained under those run directories. No
implementation fix was needed. Earlier attempts stopped before assertions
because of Cabal's offline-mode refusal during reconfiguration and a type
annotation error in the new test helper; those were build failures, not
transaction failures.

### Automatic parent fee and change

The existing `node-nested-parent` check now calls
`makeTransactionBodyAutoBalance` instead of supplying a fixed fee and computed
change. The selected inputs, explicit deposit calculation, signed token child,
and inclusion/accounting assertions remain. At this red checkpoint the sibling
example still used explicit balancing.

**Recorded result, 16 October 2026: RED** using
`./scripts/check-minutxo node-nested-parent` (`run-t_7qtmm2`). Compilation, node
startup, and token funding passed. The ordinary construction-only control
passed with an automatically calculated 392-lovelace fee under the private
node's parameters, positive change, and conserved ADA. The nested request then
failed directly:

```text
Automatic balancing failed: Balancing sub-transactions or deposit-store operations is not supported.
```

The node stopped cleanly; no nested transaction was submitted. The control
report and node evidence are retained with the run log. Green will require the
same check to preserve the signed child/deposit declaration, return correct
change, and pass node inclusion and accounting. No API or ledger fix is
included in this red step.

**Green, 16 October 2026:** the same command and unchanged check passed as
`run-48lzg7tu`. The API's UTxO-aware balancer now permits signed key-only children
with an explicit net deposit. The rebased ledger already accounts for child
inputs/outputs and that deposit, while the serialized signed children already
contribute to the fee. The fix replaces the blanket rejection with scoped
checks; it introduces no new ledger arithmetic. Estimation without real UTxOs,
nested script execution, and parent store-backed outputs remain unsupported.

Under the private node's parameters, the API calculated a 706-lovelace fee and
899,995,598,704 lovelace of parent change after the 1,133,530-lovelace net deposit.
The separately signed child and deposit declaration were preserved. The node
accepted and included transaction
`d5a693e26e86bd751ff4a75ac0f8db16f425e2c6081889db79115eee0038423d`; both inputs
were consumed, the whole UTxO and deposit allocation map matched, and total ADA
remained 1,000,000,400,000 lovelace. The ordinary control also passed. Evidence,
the API patch, and tested source hashes are retained under the run directory.
Fourmolu and whitespace checks passed; no ledger or check-source changes were
needed for green.

**Sibling verification, 16 October 2026: GREEN.** The existing sibling check now
uses the same automatic-balancing helper, supplying all three selected inputs
and both independently signed children. `./scripts/check-minutxo node-nested-sibling`
passed as `run-eufxdic_` with the same API patch; no further implementation fix
was needed. The sibling supplied the full 1,133,530-lovelace net deposit. The
API calculated an 859-lovelace fee and 899,994,598,551 lovelace of parent
change; the parent's net spend was exactly that fee. The token child still
spent and produced zero ADA. Both signed children and the deposit declaration
were preserved, and all three distinct owners' input and witness checks passed.
The node accepted and included transaction
`ea67d54efec2329c439b98ea52b99a4538f05a24648f001ac6ce3cbccbe47dd7`.
All three inputs were consumed, the exact UTxO and deposit map matched, and
total ADA remained 1,000,000,400,000 lovelace. Non-secret evidence, patches,
and tested source hashes are retained under the run directory. Preparation
still uses an explicit fixture fee; nested fee/change are automatic, while
deposit pricing remains explicit.

### Automatic fee and change for direct store-backed outputs

The existing `node-token-funding` check now requests automatic fee/change for
its two top-level store-backed outputs. It retains the explicit deposit
calculation, native minting policy, and live funding input. No fee or change
output is supplied to the balancer. The returned body must preserve the input,
both zero-ADA token outputs and the deposit declaration, and add one ordinary
ADA change output after paying the deposit and a positive fee. Submission,
inclusion, allocation-map, epoch-retention and total-ADA assertions remain.

**Recorded result, 16 October 2026: RED**, using
`./scripts/check-minutxo node-token-funding` (`run-z4hvkbcm`). Compilation passed
and Dijkstra blocks advanced from 64 to 66. The API then rejected the request:

```text
Automatic balancing failed: Balancing store-backed outputs is not supported.
```

No transaction was constructed or submitted; returned-body, inclusion and
accounting assertions did not run. The private node stopped cleanly. The log,
node evidence, check patch and source hashes are retained under
`.workspace/minutxo-incremental/checks/run-z4hvkbcm/`. The API implementation is
unchanged from the preceding nested green runs. Both nested commands share
this funding prerequisite and will stop here while this step is red. Green
must pass the same check and its retained assertions. Deposit pricing remains
explicit; no fallback to manual balancing is provided.

**Green, 16 October 2026:** the same command and unchanged check passed as
`run-7djmx9ww`. The API no longer rejects direct store-backed outputs in its
UTxO-aware balancer. Its output minimum-ADA check now follows the ledger:
implicit-deposit outputs retain their existing minimum, while store-backed
outputs are covered by the separate deposit declaration. The ledger validates
that declaration; fee and balance arithmetic are unchanged. Generated change
remains an ordinary implicit-deposit output, and deposit pricing is explicit.

The node accepted and included transaction
`db69f82bc0057556604c2ff25dd630895d54d5864141b879a0f7498a7bae2fef`.
The API calculated a 619-lovelace fee and 899,997,732,321 lovelace of change,
after the explicit 2,267,060-lovelace deposit. Both seven-token outputs retained
zero ADA. The original input was consumed, the exact outputs and allocation map
matched, both deposits survived the next epoch, and total ADA remained
1,000,000,400,000 lovelace. Evidence, the focused API patch and source hashes
confirming the check is unchanged from red are retained under the run directory.

Both unchanged nested regression commands also passed with automatic token
funding: `./scripts/check-minutxo node-nested-parent` (`run-vz9bb5wf`) and
`./scripts/check-minutxo node-nested-sibling` (`run-hfxirq3_`). The parent check's
ordinary balancing control passed. Both nested transactions preserved their
signed children and deposits, passed distinct-owner witness checks, were
included, and matched the exact UTxO, allocation map and total ADA assertions.
Their non-secret evidence and tested source hashes are retained with each run.
Fourmolu and whitespace checks passed. No ledger or check-source changes were
needed for this green step.

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
and signing checks were green. They remained green on `0675bed39` after the
declaration migration, while parent-funded nested submission was red at child
input loading. On `e5da0be24` with the aligned stack, those local checks and the
live parent-funded nested submission are green, including token funding, Store
retention across an epoch, and total ADA conservation. The sibling-funded live
submission now passes on this same stack as well.
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
   token-only inputs with `node-token-funding` (complete: inclusion, exact Store
   allocations, epoch retention and total ADA are green). Parent-funded nested
   submission and sibling-funded submission are both green with Nicolas's
   rebased ledger and the aligned stack.
10. Automatic fee/change balancing is green for direct store-backed outputs
    and both nested examples, with explicit deposit pricing. Add deposit
    calculation and collateral checks as separate capabilities. Exercise CLI,
    Plutus, wallet, and balancer paths with their own reproducers.

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
