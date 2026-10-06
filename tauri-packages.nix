# The Tauri desktop shell, as an importable function.
#
# Split out of flake.tauri.nix so the main flake can expose it as packages.tauri
# without importing a flake: a flake is a set, not a function, so
# `import ./flake.tauri.nix` yields a set, nixpkgs' lib has no callFlake, and
# builtins.getFlake refuses an uncommitted local flake.
#
# CI-ONLY. Not packages.default and not packages.sable-web: it pulls ~1036
# crates and takes hours on a small machine. See BUILD-NIX.md.
nixpkgs:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;

      # Cargo.lock resolves 25 crates out of six git repositories.
      # importCargoLock keys its `outputHashes` on *name-version*, not on the
      # commit, and every entry it is given must correspond to a git dependency
      # or evaluation fails ("a hash was specified … but there is no
      # corresponding git dependency"). Hashes are of the locked Git checkout trees,
      # one per repository; importCargoLock reuses each hash for all crates
      # from the same revision.
      gitOutputHashes = {
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

        # tauri-runtime-cef 0.1.0. Behind the non-default `cef` feature, which
        # pulls a CEF download, so the default `wry` build never touches it.
        "tauri-runtime-cef-0.1.0" = "sha256-d+m6Bh6PMj82qOtHWGmjUai0aApBiIkndUhK+vp/p6w=";

        # tauri-plugin-livekit-mobile 0.2.0, android/ios only.
        # Hash of the locked revision b18b6822….
        "tauri-plugin-livekit-mobile-0.2.0" = "sha256-le7NYu9zRZWKO/fXF0r7tNJZvD0UG6VNE2hzJls/6us=";
      };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          inherit (pkgs) lib;

          muslArch = if system == "x86_64-linux" then "x86_64" else "aarch64";

          # scripts/build-wasm.mjs aborts unless `wasm-bindgen --version` equals
          # the wasm-bindgen in Cargo.lock — 0.2.129. nixpkgs 26.11 ships
          # wasm-bindgen-cli 0.2.127, so the upstream release tarball is used
          # rather than editing the lockfile or bypassing the assertion.
          wasm-bindgen-cli-0-2-129 = pkgs.stdenvNoCC.mkDerivation {
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

          # sha256 values are the ones scripts/fetch-deepfilternet.mjs asserts,
          # base64-encoded so Nix accepts them.
          deepfilternet-wasm = pkgs.fetchurl {
            url = "https://cdn.mezon.ai/AI/models/datas/noise_suppression/deepfilternet3/v3/pkg/df_bg.wasm";
            hash = "sha256-RAtdErbqfZUAhzb4RCIdeHTuFd5csQ0wFQAkcP26BDI=";
          };

          deepfilternet-onnx = pkgs.fetchurl {
            url = "https://github.com/Rikorose/DeepFilterNet/raw/84d57ec2c08fe08e68a13fb32a58cd7092060a0f/models/DeepFilterNet3_onnx.tar.gz";
            hash = "sha256-yU2R9wkRAByUbg+rtKqa3DcEX0WgO1YAjLDIJEy2NhY=";
          };

          # The Tauri desktop shell. sable-wasm is deliberately absent: it only
          # compiles for wasm32-unknown-unknown (its session store holds JS
          # functions, so it is not Send) and is produced as a wasm32 artefact in
          # preBuild, never as a native library.
          sable = pkgs.rustPlatform.buildRustPackage (
            finalAttrs:
            {
              pname = "sable-next";
              version = "0.1.0";

              src = ./.;

              # The binary crate is `app`; the library target is `app_lib`.
              #
              # `--no-default-features --features cef,geolocation` matches what
              # upstream's own Linux release build passes
              # (src-tauri/Cargo.toml: "Exactly one must be on. The Linux
              # release build passes `--no-default-features --features cef`").
              # `geolocation` is carried over from `default` because the app
              # registers the geolocation plugin unconditionally.
              #
              # `tauri/custom-protocol` is the load-bearing one, and it is
              # namespaced: `app` only declares wry/geolocation/cef, so a bare
              # `custom-protocol` fails with "the package 'app' does not
              # contain this feature". The `dep/feat` prefix is how a package
              # enables one of its dependency's features without the dependency
              # re-exporting it.
              #
              # Without it Tauri does not embed `frontendDist` and falls back to
              # `devUrl` (http://localhost:3000), so the packaged app renders
              # "Could not connect to localhost: Connection refused".
              cargoBuildFlags = [
                "-p"
                "app"
                "--bin"
                "app"
                "--no-default-features"
                "--features"
                "cef,geolocation,tauri/custom-protocol"
              ];

              # The repo has no `cargo test` suite wired into the build; the
              # release build already type-checks every crate. Without this,
              # cargoCheckHook recompiles the whole 1036-crate dependency tree a
              # second time, doubling build time for no additional coverage.
              doCheck = false;

              cargoLock = {
                lockFile = ./Cargo.lock;
                outputHashes = gitOutputHashes;
              };

              # Keep the store path free of the checkout's own noise. The vendor/ tree
              # stays: the [patch] entries in the root Cargo.toml point at it,
              # and vendor/tauri-plugin-edge-to-edge is excluded from the
              # workspace exactly as upstream does. This has to be prePatch —
              # overriding `postPatch` and calling runHook postPatch from it
              # re-enters cargo's own postPatch hook (cargoSetupPostPatchHook)
              # forever and the builder dies on a stack overflow.
              prePatch = ''
                rm -rf .git node_modules result .svelte-kit dist
              '';

              nativeBuildInputs =
                [
                  pkgs.cargo
                  wasm-bindgen-cli-0-2-129
                  pkgs.binaryen
                  pkgs.nodejs_24
                  pkgs.pnpm_12
                  pkgs.pnpmConfigHook
                  pkgs.pkg-config
                  pkgs.makeWrapper

                  # scripts/cef/copy-libs.sh uses find(1) to locate
                  # target/**/release/build/cef_linux_*/ and `strings` + `strip`
                  # from binutils on libcef.so, libEGL.so and libGLESv2.so.
                  pkgs.findutils
                  pkgs.binutils
                ]
                ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                  pkgs.perl

                  # libspa-sys (via pipewire) runs bindgen. This is the hook nixpkgs
                  # provides for that: it points LIBCLANG_PATH at clang's lib
                  # output and fills BINDGEN_EXTRA_CLANG_ARGS. Adding plain
                  # `clang` to the inputs is not enough — libclang.so.* lives
                  # in clang's `lib` output, and bindgen dlopens it by path.
                  pkgs.rustPlatform.bindgenHook

                  # nixpkgs' rustc substitutes the hardcoded "rust-lld" for
                  # "lld" (pkgs/development/compilers/rust/rustc.nix, postPatch),
                  # because Nixpkgs has no bundled rust-lld. The wasm32 build in
                  # scripts/build-wasm.mjs invokes plain `cargo` rather than the
                  # nix wrapper, so nothing else puts a linker on PATH and the
                  # build dies with "linker `lld` not found".
                  pkgs.lld
                ];

              buildInputs =
                (with pkgs; [
                  # tauri-plugin-deep-link shells out to
                  # `update-desktop-database` in its setup hook to refresh the
                  # XDG MIME cache, and the app calls `register_all()` during
                  # startup. Declared here so makeWrapper puts it on the
                  # wrapper's PATH: the tool is usually present in a user's
                  # shell but is NOT in the derivation's closure, so without
                  # this the wrapped app cannot find it and registration fails.
                  desktop-file-utils

                  glib
                  gtk3
                  libsoup_3
                  librsvg
                  openssl
                  pango
                  pipewire
                  webkitgtk_4_1
                  xdotool

                  # CEF's own runtime dependencies. libcef.so is a Chromium
                  # build and links NSS, the GL/EGL stack, xkbcommon and ALSA;
                  # it dlopens them, so a missing one is a startup abort with no
                  # useful message rather than a link error. These are the same
                  # set upstream declares in packaging/aur/sable-bin.PKGBUILD
                  # for its CEF build. Nothing here is needed by the wry path,
                  # and all of it is on cache.nixos.org.
                  alsa-lib
                  at-spi2-atk
                  cups
                  libdrm
                  libGL
                  libx11
                  libxcomposite
                  libxdamage
                  libxext
                  libxfixes
                  libxkbcommon
                  libxrandr
                  mesa
                  nspr
                  nss
                ])
                ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux (
                  with pkgs; [ libayatana-appindicator ]
                );

              env = {
                pnpmDeps = pkgs.fetchPnpmDeps {
                  pname = "sable-next";
                  version = finalAttrs.version;
                  src = finalAttrs.src;
                  pnpm = pkgs.pnpm_12;
                  fetcherVersion = 4;
                  hash = "sha256-a9rmsWRLL8GEzrtW0AwpbcNnC5Ct2h7FeE2uBfoQaUE=";
                };

                # fetch-deepfilternet.mjs would pull these from the network at
                # vite's buildStart; planting them first keeps the derivation
                # hermetic (and the script verifies the checksums anyway).
                SABLE_DEEPFILTERNET_WASM = deepfilternet-wasm;
                SABLE_DEEPFILTERNET_ONNX = deepfilternet-onnx;

                # No Sentry credentials in a Nix build, so the frontend must not
                # attempt a source-map upload.
                SENTRY_AUTH_TOKEN = "";
              };

              # `app` embeds ../dist and the wasm bindings, and tauri-build panics
              # when `frontendDist` is absent — so both are built first, in the
              # repo's own order: wasm bindings, then vite.
              #
              # No runHook here: nixpkgs appends a `preBuild` attribute to
              # preBuildHooks, which cargoBuildHook already calls once, so
              # calling runHook from inside it recurses until the builder dies.
              preBuild = ''
                # scripts/build-wasm.mjs shells out to cargo and reads CARGO_HOME
                # for its --remap-path-prefix set.
                export CARGO_HOME="$NIX_BUILD_TOP/cargo-home"
                mkdir -p "$CARGO_HOME"

                export SABLE_WASM_OUTPUT=src/generated/wasm
                node scripts/build-wasm.mjs --release

                # DeepFilterNet payloads; fetch-deepfilternet.mjs checksums them.
                # install(1), not cp: the fetched files are read-only in the
                # store, and vite's prepare-out-dir copies static/ verbatim,
                # so a read-only source turns into EACCES there.
                install -Dm644 "$SABLE_DEEPFILTERNET_WASM" \
                  static/deepfilternet3/v3/pkg/df_bg.wasm
                install -Dm644 "$SABLE_DEEPFILTERNET_ONNX" \
                  static/deepfilternet3/v3/models/DeepFilterNet3_onnx.tar.gz

                # `vite build`, not `pnpm build`: the npm prebuild hook would
                # rebuild the bindings compiled a moment ago.
                pnpm exec vite build
              '';

              installPhase = ''
                runHook preInstall

                mkdir -p "$out/bin"
                # cargoBuildHook passes `--target $rustcTargetSpec`, so cargo
                # writes to target/<triple>/<profile>/app, not target/<profile>/app.
                # Ask rustc for the triple rather than relying on Nix's
                # substituteAll, which does not apply to phases set here.
                host_triple=$(rustc --print host-tuple)
                app_bin="target/$host_triple/release/app"
                if [ ! -f "$app_bin" ]; then
                  # Fallback for any layout where the triple is absent.
                  app_bin=$(find target -type f -name app ! -name '*.d' \
                    -path '*/release/*' -perm -u+x | head -1)
                fi
                if [ -z "$app_bin" ] || [ ! -f "$app_bin" ]; then
                  echo "install: no built app binary under target/" >&2
                  find target -maxdepth 3 -type d >&2
                  exit 1
                fi
                install -Dm755 "$app_bin" "$out/bin/sable"

                # The CEF runtime, staged next to the binary. CEF is dlopened,
                # not linked, and resolves its .pak/.dat/locales relative to the
                # executable's own directory — so libcef.so and the resources
                # have to stay in $out/bin, beside `sable`, exactly as
                # upstream's own package builds them. Moving them elsewhere
                # makes the app abort at startup with no useful message.
                #
                # copy-libs.sh also strips libcef.so from 1.3 GB to ~241 MB and
                # trims the locale set to en-US alone.
                bash scripts/cef/copy-libs.sh release "$out/bin"

                # copy-libs.sh copies from the read-only store, so the staged
                # files are not writable and strip/RPATH fixups cannot apply.
                chmod -R u+w "$out"

                # libcef.so is dlopened by path, so the dynamic loader needs to
                # be told where it is. wrapProgram rather than patchelf: the
                # binary is already in $out/bin, and a wrapper keeps the store
                # path self-describing.
                wrapProgram "$out/bin/sable" \
                  --prefix LD_LIBRARY_PATH : "$out/bin" \
                  --prefix LOCALE : "$out/bin/locales"

                runHook postInstall
              '';

              meta = {
                description = "Sable Next — a Matrix client (Tauri desktop shell, CI-ONLY)";
                homepage = "https://sable.moe";
                license = lib.licenses.agpl3Plus;
                mainProgram = "sable";
                platforms = lib.platforms.linux;
              };
            }
          );
        in
        {
          inherit sable;
          default = sable;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              binaryen
              cargo
              cmake
              glib
              gtk3
              libayatana-appindicator
              libsoup_3
              librsvg
              nodejs_24
              openssl
              pango
              perl
              pipewire
              pkg-config
              pnpm_12
              rustc
              rustfmt
              clippy
              webkitgtk_4_1
              xdotool
            ];
          };
        }
      );
    }
