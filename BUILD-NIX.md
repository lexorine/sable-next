# Nix packaging notes (`flake.nix`)

Not upstream documentation — this file is ours, for the fork. It records the
non-obvious things that cost real time to get right. Verified by actual builds
on this machine (4 cores, 15 GB).

## Outputs

| Attribute | What it is | Verified |
|---|---|---|
| `packages.lib` | `crates/sable-core` for the host, installs `lib/libsable_core.rlib` | built, 21 MB |
| `packages.web-build` | the static site only, `$out/share/sable/dist` | built, 32 MB |
| `packages.sable-web` | site + WebKitGTK window, `$out/bin/sable` | built, launched |
| `packages.tauri` | the upstream desktop shell, **CI-only, never built here** | eval only |
| `devShells.default` | full toolchain, no Tauri needed | toolchain verified |

## Why WebKit and not Tauri

`packages.tauri` still exists and still evaluates, and it is the real upstream
artefact. It is not the default and it is not built: ~1036 crates, hours on this
machine. `sable-web` is the deliverable. Upstream ships
`sable-next-<version>-web.tar.gz` in every release and runs its Playwright suite
against that build, so the web build is a supported artefact, not a hack.

The wrapper does **not** provide, because they are Tauri-only: tray icon,
native push notifications (UnifiedPush/VAPID), custom URL-scheme / deep-link
handling, window-geometry and window-state restore, the autoupdater. Everything
inside the web build itself works.

## Eight things that are not obvious

1. **`webkitgtk_4_1` is not GTK4.** In nixpkgs it is
   `webkitgtk_6_0.override { gtk4 = gtk3; }`
   (`pkgs/top-level/all-packages.nix:6679`). The only GTK4-backed WebKitGTK is
   `webkitgtk_6_0`, which ships the **6.0** API, not 4.1. The wrapper uses
   `webkit2gtk-4.1` / `gtk+-3.0`, which is also the ABI upstream's Tauri shell
   links against, so the site is exercised on the same ABI either way.

2. **`pnpmConfigHook` runs in `postConfigureHooks`.** Setting `dontConfigure`
   silently skips it: `node_modules` never gets installed, and the first
   `pnpm exec vite build` then tries to download the whole tree from
   registry.npmjs.org, which the sandbox forbids. The derivation must let
   `configurePhase` run.

3. **`packageManager: pnpm@12.4.1` is honoured, and that breaks offline builds.**
   nixpkgs has `pnpm_12` = 12.3.4. On first run the 12.3.4 binary tries to
   download and signature-verify 12.4.1 and fails:
   `ERR_PNPM_PNPM_ENGINE_IDENTITY_UNVERIFIABLE`. npmjs has no
   `@pnpm/exe-linux-x64` 12.4.1 tarball at all, so there is no artefact to verify
   even with network access. `manage-package-manager-versions=false` and
   `COREPACK_ENABLE_STRICT=0` were both tried and neither prevents it. The fix is
   the upstream standalone release binary — use the **-musl** variant, because the
   glibc one wants `/lib64/ld-linux-x86-64.so.2` and NixOS will not run it.

4. **`wasm-bindgen-cli` must be 0.2.128 exactly.** `scripts/build-wasm.mjs` reads
   the version out of `Cargo.lock` and throws if `wasm-bindgen --version`
   disagrees. nixpkgs ships 0.2.127, so the upstream musl release is fetched.
   Do not "fix" this by editing the lockfile or skipping the assertion.

5. **Do not overwrite the repo's `.cargo/config.toml`.** It is not just config:
   `scripts/build-wasm.mjs` *parses* it to recover the wasm32 rustflags
   (`getrandom_backend="wasm_js"`) and throws if they are absent. Vendor config
   goes in `$CARGO_HOME/config.toml` instead, which cargo reads *in addition* to
   the tree-local file. Also note `importCargoLock` already emits
   `.cargo/config.toml` whose `[source."git+…"]` keys carry the `#<sha>` fragment
   that Cargo.lock actually uses — hand-written keys without the fragment match
   nothing and cargo falls through to the network.

6. **`importCargoLock` is on `pkgs.rustPlatform`, not `pkgs`.** It also takes no
   `gitDir` argument. Its `outputHashes` are keyed on `name-version`, and each
   key must correspond to a real git dependency or evaluation throws.

7. **A pure-rlib crate "builds" into an empty store path.** `cargoInstallHook`
   copies only executables and `.so`/`.a`/`.dylib`, so `packages.lib` succeeded
   while installing nothing. `dontCargoInstall = true` plus an explicit
   `installPhase` is the fix. Artefacts land in `target/<triple>/release/`
   because `cargoBuildHook` passes `--target`; ask
   `rustc --print host-tuple` rather than relying on `substituteAll`, which does
   not apply to phases set in the derivation.

8. **`webkit_web_view_get_title` is transfer-none.** Wrapping it in
   `g_autofree` frees memory GLib still owns and aborts the process on the first
   title change of a real page:
   `PageLoadStateObserver::didChangeTitle() → notify::title → handler → g_free →
   malloc_printerr: "free(): invalid size"`. Reproduced with gdb, fixed by using
   a plain `const gchar *`. `gtk_window_set_title` copies, so nothing leaks.

Also needed: `stdenv` not `stdenvNoCC` (cargo build scripts are real host links,
so `cc` must exist), and `lld` in `nativeBuildInputs` because nixpkgs' rustc
rewrites the hardcoded `rust-lld` to `lld` while `build-wasm.mjs` invokes plain
`cargo`, putting no linker on PATH.

## Verified by running it

`nix build .#sable-web` then, under Xvfb, the packaged `$out/bin/sable` opens a
**1280x900** window whose title becomes **"Sable"** — i.e. the real built page
loaded, the `sable://` custom scheme served it, and the `notify::title` handler
ran. All four wrapper failure paths exit 1 with a real message (no `SABLE_DIST`,
unresolvable `SABLE_DIST`, missing `index.html`, no display).

## Offline-ness

Nothing in the build reaches the network. The two things that would have are
handled explicitly:

- `vite.config.ts`'s `deepfilternet-assets` plugin fetches two payloads in
  `buildStart`. They are fetched by Nix with the same URLs and the same
  sha256s the script asserts, then `install(1)`ed into `static/` (install, not
  `cp`: the store copies are read-only and vite copies `static/` verbatim).
- `SENTRY_AUTH_TOKEN` is left empty, so `autoUploadSourceMaps` is false and
  nothing is uploaded.

## Known coupling

`src = ./.`, so touching `flake.nix`, `webview/` or anything else in the tree
changes the source hash and re-runs the whole 12-minute web build. `packages.lib`
is the fast iteration target for MSC2815 work and does not depend on any of it.