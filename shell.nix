# Use the ledger-pinned compiler and native libraries required by the API checks.
# Run through scripts/workspace so Nix evaluates the local submodule paths.
import ./cardano-api/shell-v2-minutxo.nix
