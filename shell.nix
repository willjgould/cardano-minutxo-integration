# Use the ledger's pinned compiler and crypto libraries plus the storage
# dependencies required by the downstream packages. Independent of API branches.
{
  ledger ? builtins.getFlake ("git+file://" + toString ./cardano-ledger-specs),
  system ? builtins.currentSystem,
}:
let
  pkgs = import ledger.inputs.nixpkgs { inherit system; };
in
ledger.devShells.${system}.default.overrideAttrs (old: {
  buildInputs =
    (old.buildInputs or [ ])
    ++ [ pkgs.lmdb pkgs.snappy ]
    ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.liburing ];
})
