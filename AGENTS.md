# Working constraints

Use this checkout and its declared submodules. Other local repositories and
their builds must be explicitly supplied; never substitute a sibling checkout.
Keep failing tests simple. Missing support should fail directly; do not add
workarounds or compatibility modes merely to make a reproducer run.

# Incremental writer support

On `minutxo-incremental`, expose one missing capability with a small,
direct failing check before implementing its support. Record the observed
failure, then keep the necessary fix and its verification in a focused commit.
Keep dependency and compilation prerequisites separate from transaction
behavior. Use the archived implementation as a reference; do not restore the
whole migration onto the incremental branch.

Leave changes staged for review. Do not commit unless explicitly asked.
Demonstrate red and green with the same check. A dependency or build failure
means transaction assertions have not run; do not report them as passed or as
an assertion failure. A different error is still red, not proof of green.

Introduce each new check in its own red step after the previous check is green.
Do not add future build or transaction checks to the dependency-resolution step.
