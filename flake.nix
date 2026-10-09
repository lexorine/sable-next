{
  description = "Sable Next — the static web build, wrapped in a minimal WebKitGTK window";

  nixConfig = {
    extra-substituters = [ "https://sable-cachix.cachix.org" ];
    extra-trusted-public-keys = [
      "sable-cachix.cachix.org-1:XXaZaHCKVrE9XOLfi1yG74+COyIrpjU0jeZ7SxVAz2U="
    ];
  };

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

      # Resets whenever pnpm-lock.yaml changes — the renovate "update npm"
      # bumps move dependency versions without touching this file, so a stale
      # hash here surfaces only as "hash mismatch in fixed-output derivation"
      # deep inside the pnpm fetch.
      #
      # IMPORTANT: this hash covers the *whole* source tree, not just the npm
      # manifests. Any file the derivation copies — including scripts/build-wasm.mjs
      # — changes it. So re-derive it from a CLEAN checkout of the tree you are
      # committing, never from a dirty one, or the value you record is the one
      # for your local edits and CI will not reproduce it:
      #
      #   git -C . stash -u            # or work from a fresh worktree
      #   nix build --no-link .#default 2>&1 | grep 'got: sha256'
      #
      # Use `.#default` (the Tauri shell), not `.#web-build`: CI builds that one.
      pnpmDepsHash = "sha256-a9rmsWRLL8GEzrtW0AwpbcNnC5Ct2h7FeE2uBfoQaUE=";

      version = "0.1.0";

      # package.json pins `packageManager: pnpm@12.7.0`; nixpkgs' pnpm_12 is
      # 12.3.4. That mismatch is not a warning — pnpm honours the pin and tries
      # to *download and signature-verify* 12.7.0 at first run, which fails in
      # the sandbox:
      #
      #   Error: ERR_PNPM_PNPM_ENGINE_IDENTITY_UNVERIFIABLE
      #   Refusing to run pnpm@12.7.0: its npm registry signature could not be
      #   verified (@pnpm/exe.linux-x64@12.7.0: … error sending request)
      #
      # (npmjs has no @pnpm/exe-linux-x64 12.7.0 tarball at all, so there is no
      # registry artefact to verify even with network access.)
      #
      # Neither `manage-package-manager-versions=false` nor COREPACK settings
      # stop it — verified against pnpm 12.3.4 directly. The upstream standalone
      # release binary is used instead: it is a self-contained musl executable
      # that is simply 12.7.0, so there is nothing to provision and nothing to
      # verify.
      pnpmPinned =
        { pkgs, muslArch }:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "pnpm";
          version = "12.7.0";

          src = pkgs.fetchurl {
            url =
              if muslArch == "x86_64" then
                "https://github.com/pnpm/pnpm/releases/download/v12.7.0/pnpm-linux-x64-musl.tar.gz"
              else
                "https://github.com/pnpm/pnpm/releases/download/v12.7.0/pnpm-linux-arm64-musl.tar.gz";
            hash =
              if muslArch == "x86_64" then
                "sha256-GCAp6RLFmU/tHqpxWjjrPG6ktCvK53DFKFKlSGKhPB0="
              else
                "sha256-SbjSLhQSDnFvc1t9uaAycP+MwoT40knl9bw04mNhuco=";
          };

          dontUnpack = true;
          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            # No --strip-components: this archive holds `pnpm` at its root
            # (alongside dist/), so stripping a component would strip the name
            # itself and install nothing. The binary is self-contained.
            tar xzf "$src" -C "$out/bin" pnpm
            runHook postInstall
          '';

          meta = {
            description = "pnpm 12.7.0 (matches package.json's packageManager pin)";
            homepage = "https://pnpm.io";
            license = lib.licenses.mit;
            platforms = lib.platforms.linux;
          };
        };

      # scripts/build-wasm.mjs aborts unless `wasm-bindgen --version` equals the
      # wasm-bindgen in Cargo.lock — 0.2.129. nixpkgs 26.11 ships 0.2.127, so the
      # upstream release build is used rather than editing the lockfile or
      # bypassing the assertion.
      wasmBindgenCli =
        { pkgs, muslArch }:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "wasm-bindgen-cli";
          version = "0.2.129";

          src = pkgs.fetchurl {
            url = "https://github.com/rustwasm/wasm-bindgen/releases/download/0.2.129/wasm-bindgen-0.2.129-${muslArch}-unknown-linux-musl.tar.gz";
            hash =
              if muslArch == "x86_64" then
                "sha256-gtEruUDi1OcuDVYFOH/BuMoXkETgErYg8M5OdEDoMg4="
              else
                "sha256-LtQ1HDXdlEAwi7sCdn1H6ieO/oUaUkZTAPPJT1tsKoc=";
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
            description = "wasm-bindgen CLI 0.2.129 (matches Cargo.lock)";
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
        let
          # The wasm build is a real cargo invocation, so it needs the six git
          # repositories Cargo.lock pins, vendored — the sandbox has no network.
          # importCargoLock fetches them as fixed-output derivations.
          #
          # A `let` binding, not a derivation attribute: `${cargoGitDeps}` in
          # buildPhase resolves the variable in scope, and a sibling attribute of
          # a non-recursive set is not in scope.
          cargoGitDeps = pkgs.rustPlatform.importCargoLock {
            lockFile = ./Cargo.lock;
            outputHashes = {
              # ruma 0.17.0, rev 2d8f3b44…. One hash covers all crates in this repo.
              "ruma-0.17.0" = "sha256-ecTSzXfZok72PPh+xVjkchqqCNb3NjYnOtHcgTXQnG8=";

              # matrix-rust-sdk 0.19.1, rev 4aea59dd….
              "matrix-sdk-base-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-common-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-qrcode-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-sqlite-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-store-encryption-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-test-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-test-macros-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-test-utils-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-ui-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";

              # tauri-plugin-notifications 0.5.0, SableClient fork (UnifiedPush/VAPID).
              "tauri-plugin-notifications-0.5.0" = "sha256-IRjkPyK7F5I5LlPprTp1qjVvtaFPsBoArT8mLxjPN+Q=";

              # tauri-plugin-app-icon 0.1.0. android/ios only; not compiled here.
              "tauri-plugin-app-icon-0.1.0" = "sha256-yC835kEOJZje7kZ6H/DAbLUPjipu4NQqqJ6SimQthBM=";

              # tauri-runtime-cef 0.1.0. Behind the non-default `cef` feature,
              # which pulls a CEF download, so the default build never touches it.
              "tauri-runtime-cef-0.1.0" = "sha256-d+m6Bh6PMj82qOtHWGmjUai0aApBiIkndUhK+vp/p6w=";

              # tauri-plugin-livekit-mobile 0.2.0, android/ios only.
              # Hash of the locked revision b18b6822….
              "tauri-plugin-livekit-mobile-0.2.0" = "sha256-le7NYu9zRZWKO/fXF0r7tNJZvD0UG6VNE2hzJls/6us=";
            };
          };
        in
        # stdenv, not stdenvNoCC: cargo compiles *build scripts* for the host,
        # and each one is a real link, so a C linker has to be on PATH even
        # though no C of ours is compiled.
        pkgs.stdenv.mkDerivation {
          pname = "sable-next-web-build";
          inherit version;

          inherit src;

          nativeBuildInputs = with pkgs; [
            nodejs_24

            # The pinned pnpm, not pkgs.pnpm_12 — see pnpmPinned above.
            (pnpmPinned {
              inherit pkgs muslArch;
            })
            pnpmConfigHook
            binaryen

            # scripts/build-wasm.mjs shells out to `cargo` and `rustc`; neither
            # is otherwise on PATH here, and a missing binary surfaces as a
            # spawn error ("status null"), not a useful message.
            cargo
            rustc

            # nixpkgs' rustc rewrites the hardcoded "rust-lld" to "lld"
            # (pkgs/development/compilers/rust/rustc.nix, postPatch) because
            # Nixpkgs ships no bundled rust-lld. build-wasm.mjs invokes plain
            # `cargo`, not the nix wrapper, so nothing else puts a linker on
            # PATH and the wasm32 link dies with "linker `lld` not found".
            lld

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

          # NOT dontConfigure: pnpmConfigHook registers itself in
          # postConfigureHooks, so skipping the configure phase skips the hook,
          # node_modules is never installed from the vendored store, and the
          # first `pnpm exec vite build` tries to download the tree from
          # registry.npmjs.org — which the sandbox forbids. configurePhase is
          # otherwise a no-op for stdenv on a source tree with no autotools.

          # Not actually needed: the vendor/ directory is not injected as a
          # dependency. The [patch] entries in the root Cargo.toml point into it,
          # and sable-wasm is the only crate the wasm build compiles, so it never
          # reaches the Tauri-only tree.

          buildPhase = ''
            runHook preBuild

            export CARGO_HOME="$NIX_BUILD_TOP/cargo-home"
            mkdir -p "$CARGO_HOME"

            # Point cargo's source replacement at the vendored crates without
            # touching .cargo/config.toml.
            #
            # importCargoLock already writes its own .cargo/config.toml holding
            # the [source."git+…#<sha>"] keys Cargo.lock actually uses — with the
            # fragment suffix. Overwriting that file with keys lacking the suffix
            # makes cargo fall through to the network.
            #
            # And the repo's own .cargo/config.toml must survive untouched:
            # scripts/build-wasm.mjs parses it for the wasm32 rustflags
            # (getrandom_backend="wasm_js") and refuses to build without them.
            # CARGO_HOME/config.toml is read *in addition* to the tree-local one,
            # so this layers on top instead of replacing anything.
            cp "${cargoGitDeps}/.cargo/config.toml" \
              "$CARGO_HOME/config.toml"
            # The vendored config points at a relative "cargo-vendor-dir"; make
            # that absolute now that the file lives somewhere else entirely.
            sed -i "s|directory = \"cargo-vendor-dir\"|directory = \"${cargoGitDeps}\"|" \
              "$CARGO_HOME/config.toml"

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
            # Named `sable`, not `sable-web-view`: this is the program the
            # package presents, and the symlinkJoin wraps $out/bin/sable.
            install -Dm755 sable-web-view "$out/bin/sable"
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
            mainProgram = "sable";
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
            wrapProgram $out/bin/sable \
              --prefix SABLE_DIST : ${dist}/share/sable/dist

            # A desktop entry, so the app shows up in a launcher rather than
            # only as a bare binary.
            mkdir -p $out/share/applications
            cat > $out/share/applications/sable.desktop <<EOF
            [Desktop Entry]
            Name=Sable Next
            Comment=Matrix client
            Exec=sable
            Icon=sable
            Terminal=false
            Type=Application
            Categories=Network;InstantMessaging;
            EOF
          '';
          # The icon is one the frontend already ships — static/icons/logo.svg,
          # referenced by its own web manifest. symlinkJoin would otherwise
          # collide on share/ between the two inputs.
          preBuild = ''
            mkdir -p $out/share/icons/hicolor/scalable/apps
            ln -s ${dist}/share/sable/dist/icons/logo.svg \
              $out/share/icons/hicolor/scalable/apps/sable.svg
          '';
          meta =
            view.meta
            // {
              name = "sable-next-${version}";
              inherit version;
              mainProgram = "sable";
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
            # Cargo.lock resolves 25 crates from six git repositories.
            # importCargoLock keys these on *name-version*, not on the commit,
            # and every entry must correspond to a git dependency or evaluation
            # fails. Hashes are of the locked Git checkout trees; entries
            # sharing a repository share its hash.
            outputHashes = {
              # ruma 0.17.0, rev 2d8f3b44…. One hash covers all crates in this repo.
              "ruma-0.17.0" = "sha256-ecTSzXfZok72PPh+xVjkchqqCNb3NjYnOtHcgTXQnG8=";

              # matrix-rust-sdk 0.19.1, rev 4aea59dd….
              "matrix-sdk-base-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-common-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-qrcode-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-sqlite-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-store-encryption-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-test-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-test-macros-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-test-utils-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";
              "matrix-sdk-ui-0.19.1" = "sha256-OXVeGa4mGiTX4pr+DFXSJLgtXA7qKE9AYmbdhun/b2E=";

              # tauri-plugin-notifications 0.5.0, SableClient fork (UnifiedPush/VAPID).
              "tauri-plugin-notifications-0.5.0" = "sha256-IRjkPyK7F5I5LlPprTp1qjVvtaFPsBoArT8mLxjPN+Q=";

              # tauri-plugin-app-icon 0.1.0. android/ios only; not compiled here.
              "tauri-plugin-app-icon-0.1.0" = "sha256-yC835kEOJZje7kZ6H/DAbLUPjipu4NQqqJ6SimQthBM=";

              # tauri-runtime-cef 0.1.0. Behind the non-default `cef` feature,
              # which pulls a CEF download, so the default build never touches it.
              "tauri-runtime-cef-0.1.0" = "sha256-d+m6Bh6PMj82qOtHWGmjUai0aApBiIkndUhK+vp/p6w=";

              # tauri-plugin-livekit-mobile 0.2.0, android/ios only.
              # Hash of the locked revision b18b6822….
              "tauri-plugin-livekit-mobile-0.2.0" = "sha256-le7NYu9zRZWKO/fXF0r7tNJZvD0UG6VNE2hzJls/6us=";
            };
          };

          # sable-core is a pure rlib — it produces no binary, no cdylib and no
          # .so. cargoInstallHook only copies executables and
          # .so/.a/.dylib, so with it in place this derivation "succeeds" into
          # an empty store path and `nix build .#lib` looks like it worked while
          # installing nothing at all.
          #
          # Skip it and install the rlib ourselves, from the same place the hook
          # would have looked. `dontCargoInstall` has to be set because the hook
          # self-installs in default.nix (`if [ -z "${dontCargoInstall-}" ] …
          # then installPhase=cargoInstallHook`), and we want our installPhase.
          dontCargoInstall = true;

          installPhase = ''
            runHook preInstall

            mkdir -p "$out/lib"
            # cargoBuildHook passes --target, so artefacts land in
            # target/<triple>/release/, not target/release/. Ask rustc for the
            # triple rather than relying on substituteAll, which does not apply
            # to phases set here.
            host_triple=$(rustc --print host-tuple)
            rlib="target/$host_triple/release/libsable_core.rlib"
            if [ ! -f "$rlib" ]; then
              echo "install: $rlib is missing" >&2
              find target -maxdepth 3 -name 'libsable_core*' >&2 || true
              exit 1
            fi
            install -Dm644 "$rlib" "$out/lib/libsable_core.rlib"

            runHook postInstall
          '';

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

          # The upstream Tauri desktop shell. CI-ONLY, and deliberately not
          # `default`: it pulls ~1036 crates and takes hours on a small machine.
          # Kept so the real desktop artefact stays reachable, and so a failure
          # there is visible as this attribute rather than as a missing one.
          # See BUILD-NIX.md.
          #
          # flake.tauri.nix is a separate flake, so it cannot be imported as a function
          # (a flake is a set). The package logic lives in tauri-packages.nix,
          # which is an ordinary function — so both flakes get the same
          # derivation with no getFlake/purity problem on a dirty tree.
          tauri = (import ./tauri-packages.nix nixpkgs).packages.${system}.default;

          # The Tauri shell is the deliverable, so it is what a bare `nix build`
          # and the Cachix workflow's `.#packages.<system>.default` both mean.
          # `sable-web` stays reachable by name for the browser-only artefact.
          #
          # `default` is the chromium-cef build. It needs `__noChroot`, because
          # cef-dll-sys downloads its CEF distribution during the build and the Nix
          # sandbox has no network. That makes it non-reproducible, and it is
          # `default` anyway: CEF is the webview sable actually ships. Upstream
          # builds it the same way for the same reason -- their
          # .forgejo/workflows/tauri-build.yml runs `pnpm tauri:cef build` on a
          # plain runner, no Nix involved.
          #
          # `wry` is the lighter hermetic fallback (no `__noChroot`, ~115 MB
          # smaller). Reach it by name:
          #   nix run github:lexorine/sable-next#wry
          # `sable-cef` is an alias for `default` -- same derivation.
          #
          # Note `sable-web` is a bare attribute, not a `let`-bound name, so it
          # is NOT visible as .#sable-web on the command line; BUILD-NIX.md says
          # so. Do not assume `inherit`-style reachability here.
          default = (import ./tauri-packages.nix nixpkgs).packages.${system}.default;
          wry = (import ./tauri-packages.nix nixpkgs).packages.${system}.wry;
          sable-cef = (import ./tauri-packages.nix nixpkgs).packages.${system}.sable-cef;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
          muslArch = if system == "x86_64-linux" then "x86_64" else "aarch64";
        in
        {
          default = pkgs.mkShell {
            packages = [
              # frontend
              pkgs.nodejs_24

              # The pinned pnpm, not pkgs.pnpm_12 — the same pin the package
              # build uses. `nix develop` must be able to run
              # `pnpm wasm:build`, and pnpm 12.3.4 refuses to honour
              # packageManager: pnpm@12.7.0 without network access.
              (pnpmPinned {
                inherit pkgs muslArch;
              })
              pkgs.binaryen
              pkgs.lefthook

              # rust, including the wasm32 target rust-toolchain.toml pins.
              # nixpkgs' rustc substitutes "rust-lld" for "lld", so lld has to be
              # on PATH here too or the wasm32 link fails.
              pkgs.cargo
              pkgs.rustc
              pkgs.rustfmt
              pkgs.clippy
              pkgs.rust-analyzer
              pkgs.lld

              # wasm-bindgen-cli, at the version Cargo.lock pins (0.2.129).
              # build-wasm.mjs refuses to run on a mismatch, and nixpkgs ships
              # 0.2.127.
              (wasmBindgenCli {
                inherit pkgs muslArch;
              })

              # native: webkit2gtk_4_1 headers for the wrapper, plus gtk3,
              # which is what webkitgtk_4_1 links against in nixpkgs
              pkgs.pkg-config
              pkgs.glib
              pkgs.gtk3
              pkgs.libsoup_3
              pkgs.webkitgtk_4_1
              pkgs.openssl
              pkgs.sqlite
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux (with pkgs; [
              # Tauri-iteration extras; not needed for the web build
              cmake
              perl
              pipewire
              librsvg
              xdotool
            ]);
          };
        }
      );
    };
}