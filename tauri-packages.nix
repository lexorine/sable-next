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

          # The CEF runtime, fetched as a fixed-output derivation.
          #
          # cef-dll-sys's build script downloads a ~668 MB binary from
          # cef-builds.spotifycdn.com unless CEF_PATH points at one that is
          # already there. A Nix sandbox has no network, so without this the
          # build dies 25 minutes in with:
          #
          #   error: failed to run custom build command for `cef-dll-sys`
          #     Error: HTTP request error: io: failed to lookup address
          #     information: Temporary failure in name resolution
          #
          # So fetch it here, lay it out the way cef-dll-sys expects, and pass
          # CEF_PATH. Its layout is produced by download_cef::extract_target_archive:
          # the archive holds <name>/Release and <name>/Resources, and those are
          # merged into a single cef_linux_<arch>/ directory.
          #
          # archive.json is what makes cef-dll-sys trust the directory and skip
          # the download: check_archive_json reads it, and only downloads when
          # that read or the version check fails. Its `name` must match
          # `^cef_binary_([^+]+)` with a version no newer than 150.0.14; the
          # `sha1` field is not read but serde still requires it to be present.
          cefVersion = "150.0.14+g7c1aa68+chromium-150.0.7871.129";
          cefSha1 = {
            x86_64 = "d34827597239c647f2502d6ce5f8534a95407c30";
            aarch64 = "8003e8288c5092e0f11227e1878dcfb5a2e71f87";
          };

          cefRuntime =
            {
              pkgs,
              system,
            }:
            let
              # The CDN names its archives by platform as `linux64` /
              # `linuxarm64`, which is *not* the same token cef-dll-sys uses
              # internally (`x86_64`/`aarch64`, giving cef_linux_x86_64).
              arch = if system == "x86_64-linux" then "x86_64" else "aarch64";
              cdnArch = if system == "x86_64-linux" then "linux64" else "linuxarm64";
              top = "cef_binary_${cefVersion}_${cdnArch}";
            in
            # x86_64-linux only, deliberately. CI builds that platform and
            # nothing else. aarch64 would need its own 668 MB archive fetched
            # and hashed on a machine that can build it, and before this
            # derivation existed aarch64 could not build at all: cef-dll-sys
            # tried to download its runtime inside a network-less sandbox.
            # So aarch64 stays broken rather than becoming broken *and*
            # unbuildable for everyone who runs nix flake check --all-systems.
            if system != "x86_64-linux" then
              throw "sable-next's Tauri package (with CEF) is x86_64-linux only for now: the CEF runtime for ${system} has no hashed fetchurl in this flake."
            else
              pkgs.stdenvNoCC.mkDerivation {
                pname = "cef-binary";
                version = cefVersion;

                src = pkgs.fetchurl {
                  url =
                    "https://cef-builds.spotifycdn.com/" +
                    top +
                    "_minimal.tar.bz2";
                  # Recorded from the archive itself, not the CDN's index, so the
                  # two agreeing is a real check rather than a copied field.
                  # 314776103 bytes, sha256-QO9hPkVcrNB6p8gfQl76qLb3frg/E8wo1HDuuk5h+Y8=.
                  hash = "sha256-QO9hPkVcrNB6p8gfQl76qLb3frg/E8wo1HDuuk5h+Y8=";

                  # Spotify's CDN violates HTTP/2 framing rules part-way through
                  # these downloads and curl aborts with:
                  #   curl: (92) [HTTP2] [3] received invalid frame:
                  #     FRAME[DATA, len=0, eos=1, ...], error -532: Violation in
                  #     HTTP messaging rule
                  # It retries three times and still dies, so the build fails with
                  # "cannot download ... from any mirror". HTTP/1.1 avoids it.
                  curlOpts = "--http1.1";
                };

                dontPatch = true;
                dontConfigure = true;

                # bzip2 and tar only; nothing is compiled here.
                nativeBuildInputs = [
                  pkgs.bzip2
                  pkgs.coreutils
                ];

                installPhase = ''
                  runHook preInstall

                  tar xjf "$src" --strip-components=1 -C .

                  # Merge Release/ and Resources/ into the one directory
                  # cef-dll-sys links against, mirroring extract_target_archive.
                  mkdir -p "$out/cef_linux_${arch}"
                  mv Release/* "$out/cef_linux_${arch}/"
                  mv Resources/* "$out/cef_linux_${arch}/"

                  # CMakeLists.txt, cmake/ and include/ have to move in too:
                  # build.rs runs cmake::Config::new(&cef_dir) against that
                  # directory, so a CEF_PATH without them dies with
                  # "CMake must be installed to run" or a missing-project error.
                  for extra in CMakeLists.txt cmake include LICENSE.txt; do
                    [ -e "$extra" ] && mv "$extra" "$out/cef_linux_${arch}/"
                  done
                  true

                  # archive.json belongs at the CEF_PATH *root*, not inside
                  # cef_linux_<arch>/: build.rs calls check_archive(&configured_path)
                  # and archive_json_path() is location.join("archive.json"), where
                  # location is CEF_PATH itself. Placing it one level down leaves
                  # check_archive_json unable to open the file, which sends
                  # build.rs down the download branch all over again.
                  #
                  # Its `name` is parsed with ^cef_binary_([^+]+), so the version
                  # read back is 150.0.14 -- equal to the crate's, which passes.
                  # `sha1` is never read, but serde requires the field to exist.
                  cat > "$out/archive.json" <<EOF
                  {"type":"minimal",
                   "name":"${top}_minimal.tar.bz2",
                   "sha1":"${cefSha1.${arch}}"}
                  EOF

                  # No CEF_PATH/<version>/ directory: if it exists, build.rs takes
                  # the resolve_from_versioned path and expects a nested
                  # cef_linux_* inside it instead.
                  runHook postInstall
                '';

                meta = {
                  description = "CEF ${cefVersion} binary distribution for linux/${arch}";
                  homepage = "https://cef-builds.spotifycdn.com/";
                  license = lib.licenses.bsd3;
                  platforms = [ "x86_64-linux" ];
                };
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

                  # cef-dll-sys's build.rs drives the CEF wrapper project through
                  # the cmake crate:
                  #     cmake::Config::new(&cef_dir).generator("Ninja")
                  # That is the cmake *crate* (a Cargo build-dep, already in the
                  # closure), not the CMake binary -- nixpkgs' stdenv puts no
                  # cmake on PATH, so the build would die right after the
                  # prefetch with "CMake must be installed to run". cmake is
                  # therefore needed.
                  #
                  # Do NOT add pkgs.ninja alongside it. The `cmake` crate invokes
                  # plain `ninja`, but in a nixpkgs build that name is already
                  # the stdenv's *wrapper* for the derivation's own build.ninja
                  # generator, which stdenv puts first on PATH. Prepending real
                  # ninja shadows the wrapper, and the build dies instantly:
                  #     build flags: -j4
                  #     ninja: error: loading 'build.ninja': No such file or directory
                  pkgs.cmake

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

                # Points cef-dll-sys at the runtime fetched above instead of
                # letting its build script download one. Must name the parent of
                # cef_linux_<arch>/, not the directory itself: with CEF_PATH set
                # to a path that exists, the script joins the version onto it
                # only when a versioned subdirectory is absent, and otherwise
                # checks archive.json in the directory named here.
                CEF_PATH = cefRuntime { inherit pkgs system; };
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
                                # not linked, and tauri-runtime-cef resolves its .pak/.dat/locales
                                # relative to the executable's own directory — so libcef.so and
                                # the resources have to sit in $out/bin, beside `sable`, exactly
                                # as upstream's own package builds them. Elsewhere, the app
                                # aborts at startup with no useful message.
                                #
                                # NOT scripts/cef/copy-libs.sh: it locates the runtime with
                                # `find target -name cef_linux_* -path "*/release/build/*"`,
                                # which only holds when cef-dll-sys downloaded and unpacked the
                                # distribution itself. With CEF_PATH set, its build script copies
                                # the runtime to target/<triple>/release/ instead, so that find
                                # matches nothing and the script exits 1.
                                #
                                # Same two things copy-libs.sh would do: strip libcef.so (1.3 GB
                                # -> ~241 MB) and keep only the en-US locale (220 .pak files ->
                                # one).
                                cef_dir=$(echo "$CEF_PATH"/cef_linux_*)
                                if [ ! -d "$cef_dir" ]; then
                                  echo "install: no cef_linux_* under CEF_PATH=$CEF_PATH" >&2
                                  ls -l "$CEF_PATH" >&2
                                  exit 1
                                fi

                                mkdir -p "$out/bin/locales"
                                cp -f "$cef_dir"/*.so* "$out/bin/" 2>/dev/null || true
                                cp -f "$cef_dir"/v8_context_snapshot.bin "$out/bin/" 2>/dev/null || true
                                cp -f "$cef_dir"/*.pak "$cef_dir"/*.dat "$cef_dir"/*.bin \
                                  "$cef_dir"/*.json "$out/bin/" 2>/dev/null || true
                                cp -f "$cef_dir/locales/en-US.pak" "$out/bin/locales/" 2>/dev/null || true
                                cp -f packaging/licenses/CEF-LICENSE.txt "$out/bin/CEF-LICENSE.txt"

                                # cp without --no-preserve carries the store's read-only mode onto
                                # the copies, and strip needs to rewrite the result.
                                chmod -R u+w "$out"

                                # `strip -s` rewrites in place but leaves the original behind as
                                # <name>.stripped on some binutils versions; either way, any
                                # leftover costs ~1.4 GB in the store and in every Cachix push.
                                for lib in "$out/bin/libcef.so" "$out/bin/libEGL.so" \
                                  "$out/bin/libGLESv2.so"; do
                                  if [ -f "$lib" ]; then
                                    strip -s "$lib" 2>/dev/null || true
                                    rm -f "$lib.stripped" "$lib.orig"
                                  fi
                                done

                                # libcef.so is dlopened by path, so the dynamic loader needs to be
                                # told where it is.
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
