{
  description = "sable-next — native Nix packages";

  inputs = {
    # nixpkgs 26.11pre ships rustc 1.98.1, the exact version
    # rust-toolchain.toml pins, and its rustc already includes the
    # wasm32-unknown-unknown std.
    nixpkgs.url = "github:NixOS/nixpkgs/c59305bab2065cfecc4944690d9eedbb56f3a9fa";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }:
    # The actual package lives in tauri-packages.nix so that the main flake can
    # expose the same derivation as packages.tauri by importing it as a
    # function. A flake is a set, not a function, so `import ./flake.tauri.nix`
    # cannot be called; and builtins.getFlake refuses an uncommitted local
    # flake. Building the Tauri shell at all is impractical here (~1036 crates,
    # hours on a small machine) — see BUILD-NIX.md.
    import ./tauri-packages.nix {
      inherit nixpkgs;
    };
}
