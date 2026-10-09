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

          # The Tauri desktop shell, built two ways. They share one definition so
          # the wry and cef builds cannot drift apart; only the runtime-specific
          # bits differ.
          #
          #   sable      — wry/WebKitGTK. The default, and the only variant the
          #                 upstream Nix CI ever built. Fully hermetic: CEF is
          #                 simply not enabled, so no build script needs network.
          #   sable-cef  — chromium-cef. cef-dll-sys's build.rs downloads the CEF
          #                 distribution at build time, which the Nix sandbox
          #                 forbids, so this derivation sets __noChroot. That is a
          #                 deliberate hermeticity trade-off and the reason it is a
          #                 separate attribute rather than a feature flag on
          #                 `default`: `default` stays reproducible.
          #
          # sable-wasm is deliberately absent everywhere: it only compiles for
          # wasm32-unknown-unknown (its session store holds JS functions, so it is
          # not Send) and is produced as a wasm32 artefact in preBuild, never as a
          # native library.
          mkSable =
            {
              pname,
              cef,
            }:
            let
              # The shared libraries libcef.so dlopens. Upstream states this as
              # runtime `depends` in packaging/aur/sable-bin.PKGBUILD (`nss`,
              # `nspr`, `mesa`, `libdrm`, `libxkbcommon`, `alsa-lib`, `libcups`,
              # `gtk3`, `at-spi2-*`) and does NOT bundle them: the AppImage
              # ships only CEF's own files -- scripts/cef/copy-libs.sh copies
              # `*.so*` out of the CEF distribution directory and nothing else
              # -- and its AppRun merely adds $APPDIR to LD_LIBRARY_PATH. That
              # works on Arch because `depends` are already installed. Copying
              # that list verbatim would not fix a NixOS system profile, which
              # usually has none of them.
              cefRuntimeLibs = with pkgs; [
                alsa-lib
                at-spi2-atk
                at-spi2-core
                cups
                # No libGLESv2 / libEGL: the CEF distribution ships its own and
                # installPhase stages them into $out/bin, so declaring nixpkgs'
                # would only put a second unused copy in the closure. (There is
                # no `libGLESv2` attribute in nixpkgs in any case; the GLESv2
                # runtime arrives inside libGL.)
                libGL
                libdrm
                libgbm
                libxkbcommon
                mesa
                nspr
                nss
                pango
                xorg.libX11
                xorg.libXcomposite
                xorg.libXdamage
                xorg.libXext
                xorg.libXfixes
                xorg.libXrandr
              ];

              # rpath for both the binary and libcef.so. Nix records an rpath as
              # a closure reference, so the libraries travel with the package
              # and the loader never consults the host for them.
              cefLibPath = lib.makeLibraryPath cefRuntimeLibs;
            in
            pkgs.rustPlatform.buildRustPackage (
              finalAttrs:
              {
                inherit pname;

                version = "0.1.0";

                src = ./.;

              # The binary crate is `app`; the library target is `app_lib`.
              # `tauri/custom-protocol` is a feature of the *tauri dependency*,
              # not of the `app` package -- `app` only declares `wry`,
              # `geolocation` and `cef`, so the namespaced `dep/feature` syntax
              # is required here:
              #     error: the package 'app' does not contain this feature: custom-protocol
              #
              # Without it Tauri honours `devUrl: "http://localhost:3000"`
              # (src-tauri/tauri.conf.json) even in a release build, and the
              # packaged binary dies with "Could not connect to localhost:
              # Connection refused" inside WebKitGTK. Turning it on is what makes
              # Tauri embed `frontendDist: "../dist"` instead, and preBuild
              # already generates that directory before cargo runs.
              #
              # wry: default features, which is wry + geolocation.
              # cef: --no-default-features plus cef, matching upstream's own
              #   scripts/tauri.js, which expands `pnpm tauri:cef build` to
              #     tauri build --no-bundle --features cef -- --no-default-features
              # `tauri/custom-protocol` is required in both: it is a feature of the
              # *tauri dependency*, not of `app` (which declares only wry,
              # geolocation and cef), so the namespaced dep/feature syntax is
              # required. Without it Tauri honours devUrl http://localhost:3000
              # even in a release build and the packaged binary dies with
              # "Could not connect to localhost: Connection refused".
              cargoBuildFlags =
                [
                  "-p"
                  "app"
                  "--bin"
                  "app"
                  "--features"
                  (if cef then "tauri/custom-protocol,cef,geolocation" else "tauri/custom-protocol")
                ]
                ++ lib.optionals cef [
                  "--no-default-features"
                ];

              # cef-dll-sys's build.rs downloads the CEF binary from
              # https://cef-builds.spotifycdn.com at build time and the Nix
              # sandbox has no network, so the build died ~18 min in with
              #   Error: HTTP request error: ... Temporary failure in name resolution
              # which reads like an unrelated DNS flake. Prefetching the
              # distribution hermetically was attempted and abandoned: it needs
              # cmake (absent from stdenv), and adding cmake plus ninja to
              # nativeBuildInputs is not clean -- ninja's setup hook claims
              # buildPhase and the cargo build dies instantly with
              # "ninja: error: loading 'build.ninja': No such file or directory".
              # So the CEF variant runs unsandboxed, which is also how upstream
              # builds it: their .forgejo tauri-build.yml runs
              # `pnpm tauri:cef build` on a plain runner with no Nix involved,
              # and their flake.nix deliberately leaves CEF out with the comment
              # "the default build never touches it".
              #
              # Do NOT "fix" this by re-adding a CEF prefetch on top; the two
              # approaches conflict.
              #
              # `__noChroot` is NOT set here on purpose; see the `// lib.optionalAttrs`
              # merge at the end of this attrset. `__noChroot = cef && ...` would
              # evaluate to the boolean `false` for default, and Nix serialises a
              # boolean attrset value straight into the derivation env (`false`
              # becomes the empty string, `true` becomes "1"). default's drv would
              # then carry a `__noChroot = ""` entry that the pre-refactor drv
              # (4jrfhwhic59y8…) did not have, making the claim "the refactor did
              # not touch default" unprovable by diffing the two derivations.
              # It is not a *build* hazard -- both Nix 2.19.2, which is what CI
              # installs (see parsed-derivations.cc `getBoolAttr`: `return i->second
              # == "1"`), and Lix read any value other than "1" as false, so the
              # sandbox still applies -- but it is real derivation drift and it
              # must be absent for default to stay provably hermetic.

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
                  # installPhase calls `patchelf --set-rpath` on libcef.so so
                  # the CEF runtime resolves its own DT_NEEDED from $out/lib
                  # instead of from the host. stdenv's patchPhase would only
                  # ever touch the *linked* binary; libcef.so is dlopened.
                  pkgs.patchelf
                ]
                ++ lib.optionals cef [
                  # cef-dll-sys's build.rs runs
                  #   cmake::Config::new(&cef_dir).generator("Ninja")
                  # so the real CMake *binary* must be on PATH; stdenv ships
                  # neither cmake nor ninja. Only cmake is added -- adding ninja
                  # as well makes nixpkgs' ninja setup hook claim buildPhase ahead
                  # of cargo-build-hook, and the build dies instantly with
                  #   ninja: error: loading 'build.ninja': No such file or directory
                  # The `cmake` *crate* is a Cargo build-dep and is NOT the binary.
                  #
                  # cmake is safe by accident: the derivation already sets
                  # configurePhase, so cmake's own setup hook (which checks
                  # `if [ -z "$dontUseCmakeConfigure" ] && [ -z "$configurePhase" ]`)
                  # never claims the phase. Dropping configurePhase would let cmake
                  # hijack it, exactly as ninja hijacks buildPhase.
                  pkgs.cmake

                  # strip(1) for the libcef.so pass in installPhase. It is in no
                  # other closure entry here, and the call site is
                  # `strip -s ... 2>/dev/null || true` -- so a missing strip fails
                  # SILENTLY and ships an unstripped ~1.4 GB libcef.so to Cachix on
                  # every run. The only symptom is FileSize on the pushed narinfo,
                  # so it is easy to miss. Do not remove it.
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
                ])
                ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux (
                  with pkgs; [ libayatana-appindicator ]
                )
                # libcef.so is dlopened at runtime rather than linked, so its
                # dependencies are not caught by the link step -- they surface as a
                # startup abort with no useful message.
                #
                # Every shared library the CEF runtime dlopens. Upstream states this as
                # runtime `depends` in packaging/aur/sable-bin.PKGBUILD (`nss`,
                # `nspr`, `mesa`, `libdrm`, `libxkbcommon`, `alsa-lib`,
                # `libcups`, `gtk3`, ...) rather than bundling it -- the AppImage
                # ships only CEF's *own* files (scripts/cef/copy-libs.sh copies
                # *.so* from the CEF dir, nothing else) and its AppRun just adds
                # $APPDIR to LD_LIBRARY_PATH. On Arch that works because the
                # depends are already installed; on a NixOS system profile they
                # usually are not, and the loader aborts at startup with
                #   libnspr4.so: cannot open shared object file
                # with no way to tell which library is next. So we copy them into
                # $out/lib and put that on the wrapper's LD_LIBRARY_PATH: the
                # package then carries its own runtime and does not care what
                # the host has.
                ++ lib.optionals cef cefRuntimeLibs;

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

                ${lib.optionalString cef ''
                  # cef-dll-sys's build.rs copies the CEF runtime to
                  # target/<triple>/release/ when it downloads it itself, and it
                  # does NOT create a cef_linux_<arch>/ directory there.
                  # scripts/cef/copy-libs.sh looks for exactly that directory
                  # (`find target -type d -name cef_linux_$CEF_ARCH -path
                  # "*/$PROFILE/build/*"`) and exits 1 when it is absent:
                  #   cef_linux_x86_64 not found under target/**/release/build
                  #   -- build with --features cef first
                  # So find the runtime where build.rs actually put it rather
                  # than calling the script blindly.
                  cef_dir=$(find target -type d -name 'cef_linux_*' -print -quit 2>/dev/null || true)
                  if [ -z "$cef_dir" ]; then
                    # Fallback: build.rs may have copied the files flat into the
                    # target dir instead of creating the directory.
                    if [ -f "target/$host_triple/release/libcef.so" ]; then
                      cef_dir="target/$host_triple/release"
                    else
                      echo "install: no CEF runtime found under target/" >&2
                      find target -maxdepth 3 -name 'libcef.so*' >&2
                      exit 1
                    fi
                  fi

                  cp -f "$cef_dir"/*.so* "$out/bin/" 2>/dev/null || true
                  mkdir -p "$out/bin/locales"
                  # The full locale set is 49 MB against 570 KB for en-US alone,
                  # so ship only the one the app actually selects.
                  cp -f "$cef_dir/locales/en-US.pak" "$out/bin/locales/" 2>/dev/null || true
                  cp -f packaging/licenses/CEF-LICENSE.txt "$out/bin/CEF-LICENSE.txt"

                  # libcef.so is 1399 MB unstripped against ~241 MB stripped.
                  #
                  # strip needs a WRITABLE file: `cp -f` preserves the source's
                  # mode, and anything coming out of target/ is read-only here, so
                  # strip exits 1 with "unable to copy file ... Permission
                  # denied" -- which `2>/dev/null || true` swallows. The result is
                  # a silent ~1.4 GB output that then gets pushed to Cachix on
                  # every run. Hence chmod before strip, not after.
                  chmod -R u+w "$out"
                  for lib in "$out/bin/libcef.so" "$out/bin/libEGL.so" "$out/bin/libGLESv2.so"; do
                    if [ -f "$lib" ]; then
                      strip -s "$lib" 2>/dev/null || true
                      # Some binutils versions leave the original behind.
                      rm -f "$lib.stripped" "$lib.orig"
                    fi
                  done

                  # Bundle every shared library libcef.so needs into $out/lib.
                  #
                  # The Nix link step only records an rpath for the *linked*
                  # binary. libcef.so is an upstream Chromium build with no
                  # Nix rpath at all, and it is dlopened at runtime, so the
                  # loader resolves its DT_NEEDED entries from whatever the host
                  # happens to have. On a NixOS system profile that is usually
                  # nothing, and the app aborts at startup with
                  #   error while loading shared libraries: libnspr4.so
                  # and no hint as to which library is next. Copying the .so
                  # files in and setting an rpath on libcef.so makes the
                  # package self-contained.
                  mkdir -p "$out/lib"
                  for lib_ in $cefLibPath; do
                    [ -d "$lib_" ] || continue
                    cp -aL "$lib_"/*.so* "$out/lib/" 2>/dev/null || true
                  done

                  # Same rpath on libcef.so, for the dlopen path. Recorded as a
                  # closure reference, so these libraries stay reachable after
                  # GC even if $out/lib is not the one consulted.
                  for l in "$out/bin/libcef.so" "$out/bin/sable"; do
                    [ -f "$l" ] || continue
                    patchelf --set-rpath "$cefLibPath:$out/lib:$out/bin" "$l" \
                      || echo "warning: could not set rpath on $l" >&2
                  done

                  # libcef.so is dlopened by path and resolves its .pak/.dat/
                  # locales relative to the executable's own directory, so it has
                  # to sit in $out/bin next to the binary.
                  wrapProgram "$out/bin/sable" \
                    --prefix LD_LIBRARY_PATH : "$out/bin:$out/lib"
                ''}runHook postInstall
              '';

              meta = {
                description = "Sable Next — a Matrix client (Tauri desktop shell, CI-ONLY)";
                homepage = "https://sable.moe";
                license = lib.licenses.agpl3Plus;
                mainProgram = "sable";
                platforms = lib.platforms.linux;
              };
            }
            // lib.optionalAttrs cef {
              # Only the cef build carries these two keys. At cef = false the
              # merge operand is `{}`, so default's attrset (and therefore its
              # derivation env) is byte-identical to the pre-refactor one.
              #
              # `cef` in env is what a reader greps for to tell the variants
              # apart; `__noChroot` is read by the Nix *builder*, not stdenv --
              # there is no `dontChroot` attribute for it. nixpkgs sets it the
              # same way (pkgs/tools/nix/info/relaxedsandbox.nix,
              # generic-stack-builder.nix). On darwin there is no chroot at all,
              # so it is gated on Linux.
              inherit cef;
              __noChroot = pkgs.stdenv.hostPlatform.isLinux;
            }
          );

          # Two builds of the same shell:
          #   sable     — wry/WebKitGTK, hermetic. `default`, and the one the
          #               Cachix push points at.
          #   sable-cef — chromium-cef. Needs `__noChroot`, because cef-dll-sys
          #               downloads its distribution at build time, so it cannot be
          #               reproduced from a declared input set the way `sable` can.
          # Both are exported from the `in` block below.
        in
        {
          # Plain bindings, not `inherit`: these names are what the flake exposes.

          # `default` is the chromium-cef build. CEF is the webview sable actually
          # ships; wry/WebKitGTK is the lighter fallback, kept reachable by name.
          #
          # It is `default` even though it needs `__noChroot`, i.e. is not
          # hermetic. The trade is deliberate: a reproducible wry build that is
          # not what the project ships, versus a non-reproducible build of the
          # real thing. Upstream builds CEF the same way and for the same reason --
          # their .forgejo tauri-build.yml runs `pnpm tauri:cef build` on a plain
          # runner because cef-dll-sys downloads its distribution at build time,
          # and their Nix build deliberately never touched it.
          default = mkSable {
            pname = "sable-next";
            cef = true;
          };

          # wry/WebKitGTK. Still hermetic (`__noChroot` absent), still builds, and
          # ~115 MB smaller. Name it explicitly:
          #   nix run github:lexorine/sable-next#wry
          wry = mkSable {
            pname = "sable-next-wry";
            cef = false;
          };

          # `sable-cef` has meant the CEF build since PR #13, and it still does --
          # it now resolves to the same derivation as `default`. Kept as an
          # explicit alias because published Cachix paths and consumer scripts
          # reference it. Prefer `default` or `wry`.
          #
          # Written as the mkSable call, not `= default;`: inside an attrset a
          # sibling key is NOT in scope, so `default` here is an undefined
          # variable:
          #     error: undefined variable 'default'
          sable-cef = mkSable {
            pname = "sable-next";
            cef = true;
          };
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
