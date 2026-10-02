{
  description = "Sable Next — the static web build, wrapped in a minimal WebKitGTK window";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/c59305bab2065cfecc4944690d9eedbb56f3a9fa";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;

      pnpmDepsHash = "sha256-c8KPyvK0m78O9ih0U+U0ts9jHEiLTcIO5uu3YtdotlI=";

      version = "0.1.0";

      # scripts/build-wasm.mjs aborts unless `wasm-bindgen --version` equals the
      # wasm-bindgen in Cargo.lock — 0.2.128. nixpkgs 26.11 ships 0.2.127, so the
      # upstream release build is used rather than editing the lockfile or
      # bypassing the assertion.
      wasmBindgenCli =
        { pkgs, muslArch }:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "wasm-bindgen-cli";
          version = "0.2.128";

          src = pkgs.fetchurl {
            url = "https://github.com/rustwasm/wasm-bindgen/releases/download/0.2.128/wasm-bindgen-0.2.128-${muslArch}-unknown-linux-musl.tar.gz";
            hash =
              if muslArch == "x86_64" then
                "sha256-tR8CCP3/g1FaeHvYq5rFhl7YTau2bQxwmVe7WXk8ZF8="
              else
                "sha256-B5cx3RvHeYwe+k8I/MRRMIJ8vMn/YKC0xgR9ZPxv0lw=";
          };

          dontUnpack = true;
          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            tar xzf "$src" -C "$out/bin" --strip-components=1
            runHook postInstall
          '';

          meta = {
            description = "wasm-bindgen CLI 0.2.128 (matches Cargo.lock)";
            license = lib.licenses.mit;
            platforms = lib.platforms.linux;
          };
        };

      # ---------------------------------------------------------------------
      # The static site. This is the actual deliverable: it builds sable-wasm
      # for wasm32-unknown-unknown and then runs vite, exactly as the repo's own
      # `pnpm build` does. No Rust is compiled for the host here, which is why
      # this is fast and why Tauri is not a dependency.
      # ---------------------------------------------------------------------
      webBuild =
        { pkgs, src, muslArch }:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "sable-next-web-build";
          inherit version;

          inherit src;

          nativeBuildInputs = with pkgs; [
            nodejs_24
            pnpm_12
            pnpmConfigHook
            binaryen

            # scripts/build-wasm.mjs shells out to `cargo` and `rustc`; neither
            # is otherwise on PATH here, and a missing binary surfaces as a
            # spawn error ("status null"), not a useful message.
            cargo
            rustc

            (wasmBindgenCli {
              inherit pkgs muslArch;
            })
          ];

          pnpmDeps = pkgs.fetchPnpmDeps {
            pname = "sable-next";
            inherit version src;
            pnpm = pkgs.pnpm_12;
            fetcherVersion = 4;
            hash = pnpmDepsHash;
          };

          # scripts/fetch-deepfilternet.mjs pulls these from the network during
          # vite's buildStart. Same URLs it uses, so the build stays hermetic
          # without disabling its checksum verification.
          SABLE_DEEPFILTERNET_WASM = pkgs.fetchurl {
            url = "https://cdn.mezon.ai/AI/models/datas/noise_suppression/deepfilternet3/v3/pkg/df_bg.wasm";
            hash = "sha256-RAtdErbqfZUAhzb4RCIdeHTuFd5csQ0wFQAkcP26BDI=";
          };

          SABLE_DEEPFILTERNET_ONNX = pkgs.fetchurl {
            url = "https://github.com/Rikorose/DeepFilterNet/raw/84d57ec2c08fe08e68a13fb32a58cd7092060a0f/models/DeepFilterNet3_onnx.tar.gz";
            hash = "sha256-yU2R9wkRAByUbg+rtKqa3DcEX0WgO1YAjLDIJEy2NhY=";
          };

          # Sentry only uploads source maps when this is set; leave it empty so
          # the build never reaches out.
          SENTRY_AUTH_TOKEN = "";

          dontConfigure = true;

          # The wasm build is a real cargo invocation, so it needs the five git
          # repositories Cargo.lock pins, vendored — the sandbox has no network.
          # importCargoLock fetches them as fixed-output derivations.
          cargoGitDeps = pkgs.importCargoLock {
            lockFile = ./Cargo.lock;
            gitDir = "cargo-vendor";
            outputHashes = {
              # matrix-rust-sdk 0.19.1, rev bc2502ee….
              "matrix-sdk-base-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-common-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-qrcode-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-sqlite-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-store-encryption-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-test-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-test-macros-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-test-utils-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-ui-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";

              # tauri-plugin-notifications 0.5.0, SableClient fork (UnifiedPush/VAPID).
              "tauri-plugin-notifications-0.5.0" = "sha256-IRjkPyK7F5I5LlPprTp1qjVvtaFPsBoArT8mLxjPN+Q=";

              # tauri-plugin-app-icon 0.1.0. android/ios only; not compiled here.
              "tauri-plugin-app-icon-0.1.0" = "sha256-yC835kEOJZje7kZ6H/DAbLUPjipu4NQqqJ6SimQthBM=";

              # tauri-runtime-cef 0.1.0. Behind the non-default `cef` feature,
              # which pulls a CEF download, so the default build never touches it.
              "tauri-runtime-cef-0.1.0" = "sha256-d+m6Bh6PMj82qOtHWGmjUai0aApBiIkndUhK+vp/p6w=";

              # tauri-plugin-livekit-mobile 0.2.0, android/ios only. Its
              # Cargo.toml asks for rev ca97b1ec… but the locked commit is
              # 92ddc076…, so the hash is for that tree.
              "tauri-plugin-livekit-mobile-0.2.0" = "sha256-5QB7wu2js4JLkJWiJ6YgR7QpLzuVpm49PmKnO9tNm94=";
            };
          };

          # Not actually needed: the vendor directory is referenced by absolute
          # store path from the cargo config below, not injected as a dependency.

          buildPhase = ''
            runHook preBuild

            export CARGO_HOME="$NIX_BUILD_TOP/cargo-home"
            mkdir -p "$CARGO_HOME"

            # Vendor the five git dependencies and rewrite cargo's source config
            # so the wasm build resolves them from disk. Revs below are the ones
            # Cargo.lock pins; they must match the [source."git+…"] keys exactly
            # or cargo ignores the replacement and tries the network.
            mkdir -p .cargo
            {
              echo '[source.crates-io]'
              echo 'replace-with = "vendored-sources"'
              echo

              echo '[source."git+https://github.com/matrix-org/matrix-rust-sdk?rev=bc2502ee3d3ba1dc687740df5be0f8635032399e"]'
              echo 'git = "https://github.com/matrix-org/matrix-rust-sdk"'
              echo 'rev = "bc2502ee3d3ba1dc687740df5be0f8635032399e"'
              echo 'replace-with = "vendored-sources"'
              echo

              echo '[source."git+https://github.com/SableClient/tauri-plugin-notifications.git?rev=f230395e47f326cc09bcf644f7952d57cab518f7"]'
              echo 'git = "https://github.com/SableClient/tauri-plugin-notifications.git"'
              echo 'rev = "f230395e47f326cc09bcf644f7952d57cab518f7"'
              echo 'replace-with = "vendored-sources"'
              echo

              echo '[source."git+https://github.com/SableClient/tauri-plugin-app-icon?rev=bab80ae17f6d018702e472c539d0f02eba480c21"]'
              echo 'git = "https://github.com/SableClient/tauri-plugin-app-icon"'
              echo 'rev = "bab80ae17f6d018702e472c539d0f02eba480c21"'
              echo 'replace-with = "vendored-sources"'
              echo

              echo '[source."git+https://github.com/SableClient/tauri-plugin-livekit-mobile.git?rev=ca97b1ecd6fae4fc8faa3fe0b3e67661a98f7fe9"]'
              echo 'git = "https://github.com/SableClient/tauri-plugin-livekit-mobile.git"'
              echo 'rev = "ca97b1ecd6fae4fc8faa3fe0b3e67661a98f7fe9"'
              echo 'replace-with = "vendored-sources"'
              echo

              echo '[source."git+https://github.com/SableClient/tauri-runtime-cef?rev=6568170ae5fb27b38dae1e367f0bb3a09a040152"]'
              echo 'git = "https://github.com/SableClient/tauri-runtime-cef"'
              echo 'rev = "6568170ae5fb27b38dae1e367f0bb3a09a040152"'
              echo 'replace-with = "vendored-sources"'
              echo

              echo '[source.vendored-sources]'
              echo "directory = \"${cargoGitDeps}\""
            } > .cargo/config.toml

            export CARGO_NET_OFFLINE=true

            # 1. wasm32 bindings. The only Rust compilation in the whole flake,
            #    and a small one: sable-wasm plus its wasm-only dependencies.
            node scripts/build-wasm.mjs --release

            # 2. DeepFilterNet payloads, planted where vite's
            #    deepfilternet-assets plugin looks for them so it skips the
            #    network fetch. install(1), not cp: the fetched files are
            #    read-only in the store and vite copies static/ verbatim, which
            #    turns a read-only source into an EACCES.
            install -Dm644 "$SABLE_DEEPFILTERNET_WASM" \
              static/deepfilternet3/v3/pkg/df_bg.wasm
            install -Dm644 "$SABLE_DEEPFILTERNET_ONNX" \
              static/deepfilternet3/v3/models/DeepFilterNet3_onnx.tar.gz

            # 3. vite build. Not `pnpm build`: its prebuild hook would re-run
            #    the wasm build a moment ago. adapter-static writes dist/.
            pnpm exec vite build

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p "$out/share/sable/dist"
            cp -r dist/. "$out/share/sable/dist/"
            # Source maps would embed absolute build paths and are useless
            # without a symbol server.
            find "$out/share/sable/dist" -name '*.map' -delete

            runHook postInstall
          '';

          doCheck = false;

          meta = {
            description = "Static Sable Next web build (dist/)";
            homepage = "https://sable.moe";
            license = lib.licenses.agpl3Plus;
            platforms = lib.platforms.linux;
          };
        };

      # ---------------------------------------------------------------------
      # The wrapper. Plain C against webkit2gtk 4.1 — no Rust, no Tauri, no
      # wry. nixpkgs has both from the binary cache, which is the point.
      #
      # NOTE on the GTK version: the card asked for webkit2gtk_4_1 + gtk4, but
      # in nixpkgs `webkitgtk_4_1` is webkitgtk_6_0 overridden with gtk3
      # (pkgs/top-level/all-packages.nix: `webkitgtk_4_1 = webkitgtk_6_0.override
      # { gtk4 = gtk3; }`). The only gtk4-backed WebKitGTK here is
      # webkitgtk_6_0, which ships the 6.0 API rather than the 4.1 one named in
      # the card. 4.1 is also what upstream's own Tauri shell links against, so
      # the site is exercised on that ABI.
      # ---------------------------------------------------------------------
      webView =
        { pkgs }:
        pkgs.stdenv.mkDerivation {
          pname = "sable-web-view";
          version = "0.1.0";

          # Only the wrapper source, not the whole checkout.
          src = ./webview;

          strictDeps = true;

          nativeBuildInputs = with pkgs; [ pkg-config ];

          buildInputs = with pkgs; [
            glib
            gtk3
            libsoup_3
            webkitgtk_4_1
          ];

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            cc -O2 -Wall -Wextra -o sable-web-view sable-web-view.c \
              $(pkg-config --cflags --libs webkit2gtk-4.1 gtk+-3.0 glib-2.0)
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            install -Dm755 sable-web-view "$out/bin/sable-web-view"
            runHook postInstall
          '';

          meta = {
            description = "WebKitGTK 4.1 window that opens the Sable Next web build";
            longDescription = ''
              A minimal WebKitGTK shell around the static Sable Next web build.

              This is deliberately not Tauri. Upstream's desktop app pulls a
              ~1000-crate Rust tree that takes hours to build, while the web
              build is the artefact upstream actually ships and tests.

              NOT AVAILABLE, because they are Tauri-only:
                * tray icon
                * native push notifications (UnifiedPush / VAPID)
                * custom URL scheme / deep-link handling
                * window-geometry and window-state restore
                * the autoupdater

              Everything inside the web build works: Matrix login, timelines,
              E2EE, spaces, and the Rust/WASM crypto core.
            '';
            homepage = "https://sable.moe";
            license = lib.licenses.agpl3Plus;
            platforms = lib.platforms.linux;
            mainProgram = "sable-web-view";
          };
        };

      # The packaged app: both halves in one output, with the entry point
      # wired to the built site.
      sableWeb =
        { pkgs, src, muslArch }:
        let
          dist = webBuild {
            inherit pkgs src muslArch;
          };
          view = webView { inherit pkgs; };
        in
        pkgs.symlinkJoin {
          name = "sable-next";
          paths = [
            view
            dist
          ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/sable-web-view \
              --prefix SABLE_DIST : ${dist}/share/sable/dist
          '';
          meta =
            view.meta
            // {
              name = "sable-next-${version}";
              inherit version;
            };
        };

      # ---------------------------------------------------------------------
      # packages.lib — just crates/sable-core for the host, for fast iteration
      # on MSC2815 with no frontend and no wasm build.
      # ---------------------------------------------------------------------
      libOnly =
        {
          pkgs,
          src,
        }:
        pkgs.rustPlatform.buildRustPackage {
          pname = "sable-core";
          version = "0.1.0";

          inherit src;

          cargoBuildFlags = [
            "-p"
            "sable-core"
          ];

          # No test suite is wired into this target and the release build
          # already type-checks it. Without this, cargoCheckHook recompiles the
          # whole dependency tree a second time.
          doCheck = false;

          cargoLock = {
            lockFile = ./Cargo.lock;
            # Cargo.lock resolves 13 crates from five git repositories.
            # importCargoLock keys these on *name-version*, not on the commit,
            # and every entry must correspond to a git dependency or evaluation
            # fails. Produced by running fetchgit with lib.fakeHash, one per
            # repository; entries sharing a repository share its hash.
            outputHashes = {
              # matrix-rust-sdk 0.19.1, rev bc2502ee….
              "matrix-sdk-base-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-common-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-qrcode-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-sqlite-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-store-encryption-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-test-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-test-macros-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-test-utils-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";
              "matrix-sdk-ui-0.19.1" = "sha256-VF2son9vPfS10Lvm2GnnJatepTw/RODCimXaPv2RWd0=";

              # tauri-plugin-notifications 0.5.0, SableClient fork (UnifiedPush/VAPID).
              "tauri-plugin-notifications-0.5.0" = "sha256-IRjkPyK7F5I5LlPprTp1qjVvtaFPsBoArT8mLxjPN+Q=";

              # tauri-plugin-app-icon 0.1.0. android/ios only; not compiled here.
              "tauri-plugin-app-icon-0.1.0" = "sha256-yC835kEOJZje7kZ6H/DAbLUPjipu4NQqqJ6SimQthBM=";

              # tauri-runtime-cef 0.1.0. Behind the non-default `cef` feature,
              # which pulls a CEF download, so the default build never touches it.
              "tauri-runtime-cef-0.1.0" = "sha256-d+m6Bh6PMj82qOtHWGmjUai0aApBiIkndUhK+vp/p6w=";

              # tauri-plugin-livekit-mobile 0.2.0, android/ios only. Its
              # Cargo.toml asks for rev ca97b1ec… but the locked commit is
              # 92ddc076…, so the hash is for that tree.
              "tauri-plugin-livekit-mobile-0.2.0" = "sha256-5QB7wu2js4JLkJWiJ6YgR7QpLzuVpm49PmKnO9tNm94=";
            };
          };

          # Keep the store path free of the checkout's own noise. vendor/ stays:
          # the [patch] entries in the root Cargo.toml point into it, and
          # vendor/tauri-plugin-edge-to-edge is on the workspace exclude list
          # exactly as upstream does.
          prePatch = ''
            rm -rf .git node_modules result .svelte-kit dist
          '';

          nativeBuildInputs = with pkgs; [
            cargo
            rustc
            pkg-config
          ];

          buildInputs = with pkgs; [
            openssl
            sqlite
            zlib
          ];

          meta = {
            description = "sable-core — Sable Next core types and reducers";
            homepage = "https://sable.moe";
            license = lib.licenses.agpl3Plus;
            platforms = lib.platforms.linux;
          };
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
          src = ./.;
          muslArch = if system == "x86_64-linux" then "x86_64" else "aarch64";
        in
        {
          # Main deliverable: the site plus the window that shows it.
          sable-web = sableWeb {
            inherit pkgs src muslArch;
          };

          # Fast iteration target: host sable-core only.
          lib = libOnly {
            inherit pkgs src;
          };

          # The site on its own, without the window.
          web-build = webBuild {
            inherit pkgs src muslArch;
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              # frontend
              nodejs_24
              pnpm_12
              binaryen
              lefthook

              # rust, including the wasm32 target rust-toolchain.toml pins
              cargo
              rustc
              rustfmt
              clippy
              rust-analyzer

              # native: webkit2gtk_4_1 headers for the wrapper, plus gtk3,
              # which is what webkitgtk_4_1 links against in nixpkgs
              pkg-config
              glib
              gtk3
              libsoup_3
              webkitgtk_4_1
              openssl
              sqlite
            ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              # Tauri-iteration extras; not needed for the web build
              cmake
              perl
              pipewire
              librsvg
              xdotool
            ];
          };
        }
      );
    };
}