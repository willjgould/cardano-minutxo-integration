{
  description = "Pinned compiler and native libraries for the minimum-UTxO workspace";

  # A Git input reads the initialized submodule even when Nix omits submodules
  # from the parent source. Keep the URL relative so recursive clones relocate.
  inputs.ledger.url = "git+file:./cardano-ledger-specs";

  outputs = { ledger, ... }: {
    devShells = builtins.mapAttrs (system: _: {
      default = import ./shell.nix { inherit ledger system; };
    }) ledger.devShells;
  };
}
