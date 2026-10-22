# SPDX-License-Identifier: AGPL-3.0-or-later
{
  nixConfig = {
    extra-substituters = [ "https://sable-cachix.cachix.org" ];
    extra-trusted-public-keys = [
      "sable-cachix.cachix.org-1:XXaZaHCKVrE9XOLfi1yG74+COyIrpjU0jeZ7SxVAz2U="
    ];
  };

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      forAllSystems =
        f:
        lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ] (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          callPackage = lib.callPackageWith (pkgs // packages // { src = self; });
          packages = {
            sable-deepfilternet-assets = callPackage ./packaging/nix/deepfilternet.nix { };
            sable-unwrapped = callPackage ./packaging/nix/unwrapped.nix { };
            sable = callPackage ./packaging/nix/sable.nix { };
            default = packages.sable;
          }
          // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
            sable-electron-app = callPackage ./.fork/nix/electron-app.nix { };
            sable-desktop = callPackage ./.fork/nix/desktop.nix { };
          };
        in
        packages
      );

      checks = forAllSystems (
        pkgs:
        let
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) sable-unwrapped;
          pnpmCheck =
            name: script:
            sable-unwrapped.overrideAttrs {
              pname = "sable-${name}";
              postPatch = "";
              buildPhase = ''
                pnpm wasm:dev
                pnpm exec svelte-kit sync
                pnpm run ${script}
              '';
              installPhase = "touch $out";
            };
        in
        lib.mapAttrs pnpmCheck {
          lint = "lint";
          fmt = "fmt:check";
          test = "test";
          typecheck = "check";
          knip = "knip";
        }
        // {
          build = self.packages.${pkgs.stdenv.hostPlatform.system}.sable;
        }
      );
    };
}
