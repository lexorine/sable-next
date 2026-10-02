# sable-next — build system map

Repo: https://github.com/SableClient/sable-next (cloned at
`/var/lib/hermes/.hermes/cache/scratch/sable`). Everything below is read out of
the checked-out config files; the file paths are given so each line can be
re-verified.

**Not executed on this host.** None of the toolchain (`mise`, `cargo`, `node`,
`pnpm`, `docker`) is installed here — see §8 for what a runner needs. Commands
are exact quotes from `mise.toml`, `package.json`, and the Forgejo workflows,
not transcripts of runs.

---

## 1. Layout

| Path                | What it is                                                                                                                                                                                                                         |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `crates/sable-core` | Matrix protocol core (also holds `generate-types` example, feature `typegen`)                                                                                                                                                      |
| `crates/sable-hdr`  | header/preview helper crate                                                                                                                                                                                                        |
| `crates/sable-push` | push gateway client                                                                                                                                                                                                                |
| `crates/sable-wasm` | WASM bindings — **wasm32-only** (session store holds JS fns, not `Send`)                                                                                                                                                           |
| `src-tauri`         | Tauri shell, package name `app`, lib name `app_lib`                                                                                                                                                                                |
| `vendor/`           | patched-in `matrix-sdk`, `matrix-sdk-crypto`, `matrix-sdk-indexeddb` (0.19.1, rev `bc2502ee3d3ba1dc687740df5be0f8635032399e`), `tauri-plugin-edge-to-edge`                                                                         |
| `src/`              | SvelteKit app (`src/generated/wasm` = bindings, `src/generated/protocol.ts` = Specta output)                                                                                                                                       |
| `tests/e2e`         | Playwright; `tests/e2e/fixtures/continuwuity.ts` is a testcontainers homeserver                                                                                                                                                    |
| `scripts/`          | helper scripts: `build-wasm.mjs`, `install-git-hooks.mjs`, `scripts/ci/*` (release/CI), `scripts/cef/*`; `mise.toml [task_config] includes = ["scripts"]` also points mise's task-file search here (currently no task files in it) |

Root `Cargo.toml`: `members = ["crates/*", "src-tauri"]`,
`default-members = ["crates/sable-core", "src-tauri"]`, `resolver = "3"`.
Profiles: `wasm-release` (opt-z, lto, cgu 1), `wasm-dev` (opt 1, no debug),
`wasm-test` (inherits wasm-dev, opt-z), `release` (opt-z, thin lto, panic abort).

## 2. Exact toolchain pins

| Tool                | Version                                                                                                  | Where pinned                                             |
| ------------------- | -------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| mise                | min `2026.7.11` (CI installs `2026.9.7`)                                                                 | `mise.toml:2`, `.forgejo/actions/*/action.yml`           |
| Node                | `24.21.0`                                                                                                | `mise.toml [tools]`, `.forgejo/actions/setup/action.yml` |
| pnpm                | `12.4.1` (aqua backend)                                                                                  | `package.json packageManager`, `mise.lock`               |
| Rust                | `1.98.1`, components `clippy,rustfmt`, target `wasm32-unknown-unknown` (backend `core:rust` = rustup)    | `rust-toolchain.toml`, `mise.lock`                       |
| wasm-bindgen CLI    | `0.2.128` — **must equal the `wasm-bindgen` version in `Cargo.lock`**, `build-wasm.mjs` aborts otherwise | `mise.toml [tools]`, `mise.lock`                         |
| binaryen (wasm-opt) | `132`                                                                                                    | `mise.toml`                                              |
| watchexec           | `2.7.2`                                                                                                  | `mise.toml`                                              |
| lefthook            | `2.1.14`                                                                                                 | `mise.toml`                                              |
| cargo-machete       | `0.9.2`                                                                                                  | `mise.toml [tasks.check].tools`                          |
| cargo-deny          | `0.20.2`                                                                                                 | `mise.toml [tasks.check].tools`                          |
| cargo-nextest       | `0.9.146` (`cargo-nextest-` prefix)                                                                      | `mise.toml [tasks.test].tools`                           |
| OpenTofu            | `1.12.6`                                                                                                 | `mise.toml [tasks.opentofu].tools`                       |
| Tauri env (opt.)    | Java `temurin-21`, `android-sdk 22.0`, `ANDROID_NDK_VERSION=29.0.14206865`                               | `mise.tauri.toml`, `mise.toml [env]`                     |

mise settings: `lockfile = true`, `minimum_release_age = "1d"`,
`experimental = true`, `idiomatic_version_file_enable_tools = ["pnpm","rust"]`,
`[task_config] includes = ["scripts"]`, `_.path` prepends
`node_modules/.bin`, `NODE_OPTIONS=--max-old-space-size=4096`.

## 3. Bootstrap

```bash
mise install            # node, pnpm, rust, wasm-bindgen, binaryen, watchexec, lefthook
mise run setup          # = ["mise install", "pnpm install"]
pnpm install --frozen-lockfile   # what CI runs (scripts/setup action)
```

`pnpm install` runs `prepare`: `svelte-kit sync || echo ''` +
`node scripts/install-git-hooks.mjs` (installs lefthook).
`MISE_ENV=tauri` additionally loads `mise.tauri.toml` (Java, Android SDK,
`[bootstrap.packages]` OS package lists) — installed by
`mise run tauri:setup` = `mise bootstrap packages apply --yes --update`.

## 4. Build commands

```bash
mise run dev            # alias d → pnpm dev → [predev: pnpm wasm:dev] + vite dev (:3000 for Tauri)
mise run build          # alias b → pnpm build → [prebuild: pnpm wasm:build] + vite build → dist/, .svelte-kit/output
mise run preview        # alias p → vite preview
mise run wasm:build     # alias wasm/wb → pnpm wasm:build  (release)
mise run wasm:watch     # alias ww → watchexec over crates/{sable-core,sable-wasm} → pnpm wasm:dev
pnpm storybook          # :6006 ; pnpm build-storybook → storybook-static/
docker build -t sable-next .   # after `pnpm build`; image is caddy:2-alpine serving dist (no Rust in image)
```

WASM pipeline (`scripts/build-wasm.mjs`, invoked as `mise exec -- node …`):

1. reads `.cargo/config.toml` `[target.wasm32-unknown-unknown].rustflags`
   (must exist — it carries `--cfg getrandom_backend="wasm_js"`), appends
   `--remap-path-prefix` for cargo home / sysroot / repo, exports as
   `CARGO_ENCODED_RUSTFLAGS` (release only).
2. asserts `wasm-bindgen --version` == `wasm-bindgen` in `Cargo.lock`.
3. `cargo build --locked --package sable-wasm --target wasm32-unknown-unknown --profile wasm-release|wasm-dev`
   (`CARGO_BUILD_JOBS=1` in CI).
4. `wasm-bindgen --target web --out-dir src/generated/wasm --out-name sable_wasm`
   (release adds `--remove-name-section` + friends), output dir lockfile-guarded.
5. Release enforces `MAX_RELEASE_WASM_BYTES = 18 MiB`.
   `SABLE_WASM_OUTPUT` overrides the output dir (e2e uses `src/generated/wasm-e2e`).

Native: `mise run tauri:setup` → `pnpm tauri` / `pnpm tauri:cef`;
platform extras: `tauri:setup:android|macos|ios|windows`, `tauri:icons`.

## 5. Test commands

```bash
mise run test           # alias t, raw=true
#   pnpm test                                    # svelte-kit sync && vitest run
#   cargo nextest run --locked --workspace --exclude app --all-features
#   cargo nextest run --locked -p app
#   cargo test --locked -p sable-wasm --target wasm32-unknown-unknown --profile wasm-test   # needs chromedriver on PATH
pnpm test:coverage      # vitest --coverage (CI thresholds live here)
pnpm test:e2e           # SABLE_WASM_OUTPUT=src/generated/wasm-e2e playwright test
pnpm test:timeline      # playwright -c playwright.timeline.config.ts
```

## 6. Lint / format / typecheck

`mise run ci` = `check` → `test` → `doc`. This is what `CONTRIBUTING.md`
tells contributors to run before a PR (plus `pnpm test:e2e`).

```bash
mise run check   # alias c, in this order:
# 1  pnpm fmt:check        oxfmt --check .
# 2  pnpm lint             oxlint && oxlint --type-aware && eslint . --max-warnings 0
# 3  pnpm stylelint        stylelint "src/**/*.{css,svelte}" --max-warnings 0
# 4  pnpm check            svelte-kit sync && check-theme-tokens && check-timeline-scroll
#                          && check-overlay-layers && check-date-inputs
#                          && svelte-check --tsconfig ./tsconfig.json --fail-on-warnings
#                          && tsc -p src/service-worker/tsconfig.json
# 5  pnpm knip             svelte-kit sync && knip
# 6  cargo fmt --all -- --check
# 7  cargo machete
# 8  cargo clippy --locked --workspace --exclude app --all-targets --all-features -- -D warnings
# 9  cargo clippy --locked -p app --all-targets -- -D warnings
# 10 cargo clippy --locked -p sable-wasm --target wasm32-unknown-unknown --all-targets --all-features -- -D warnings
# 11 { task = check:types } cargo run --locked -p sable-core --example generate-types --features typegen -- --check
# 12 cargo deny check

mise run doc     # RUSTDOCFLAGS=-D warnings cargo doc --locked --workspace --exclude app --all-features --no-deps
                 # + cargo doc --locked -p app --no-deps
mise run fix     # alias f → pnpm lint:fix && pnpm stylelint:fix && cargo fmt --all
mise run generate:types   # after editing crates/sable-core/src/protocol.rs → commit src/generated/protocol.ts
```

`--all-features` on the whole workspace is deliberately avoided for `-p app`:
it turns on both desktop runtimes and downloads CEF (see comments in `mise.toml`,
`.forgejo/workflows/quality-checks.yml`).

**Git hooks** (`lefthook.yml`, `parallel: true`, skipped on merge/rebase):
pre-commit — eslint+oxfmt on staged js/ts (excl. `src/generated`), eslint+oxfmt+
stylelint on `.svelte`, `oxlint --type-aware` on ts, stylelint on css,
`cargo fmt --all` (all with `stage_fixed: true`); pre-push — `svelte-check`,
the three clippy invocations above.

## 7. CI map

Primary CI is **Forgejo** (`.forgejo/`); GitHub (`.github/workflows/`) only
mirrors `codeql.yml`, `tauri-build.yml`, `zizmor.yml`.

`.forgejo/workflows/quality-checks.yml` (ubuntu-latest, on PR + push to main)

| job      | runs                                                                             | notes                                                                                                                                 |
| -------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `build`  | setup(action, `build: 'true'`) → wasm + `pnpm exec vite build`                   | uploads artifacts `.svelte-kit/output`, `dist`, `src/generated/wasm`; Sentry creds withheld on purpose                                |
| `format` | `pnpm fmt:check`, `pnpm stylelint`                                               |                                                                                                                                       |
| `checks` | `pnpm lint`, `pnpm check`, `pnpm test:coverage` + coverage upload                | restores ESLint cache                                                                                                                 |
| `e2e`    | `pnpm exec playwright install chromium webkit` + `install-deps`, `pnpm test:e2e` | `runs-on: docker` (needs a daemon), env `SABLE_E2E_PREBUILT=1`, points testcontainers at the docker host, uploads `playwright-report` |

`.forgejo/workflows/rust-quality.yml` (path-filtered on `crates/**`,
`src-tauri/**`, `Cargo.*`, `rust-toolchain.toml`, `deny.toml`, …)

| job         | runs                                                                                                                                                                                                                                                                           |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `workspace` | clippy (workspace excl. app), `cargo nextest run --locked --workspace --exclude app --all-features`, `generate-types -- --check`                                                                                                                                               |
| `app`       | clippy `-p app`, `cargo nextest run -p app`                                                                                                                                                                                                                                    |
| `wasm`      | clippy `-p sable-wasm --target wasm32-unknown-unknown`, installs google-chrome-stable + matching chromedriver, `cargo test -p sable-wasm --target wasm32-unknown-unknown --profile wasm-test` with `CHROMEDRIVER` + `WASM_BINDGEN_TEST_WEBDRIVER_JSON=.forgejo/webdriver.json` |
| `policy`    | rustfmt only toolchain + `cargo deny check` (needs `cargo metadata`, compiles nothing)                                                                                                                                                                                         |

Other Forgejo workflows: `tauri-build.yml` (release bundles: Linux/macOS/
Windows/iOS/Android), `docker-publish.yml`, `cloudflare-web{,-preview}.yml`,
`dco.yml`, `weblate-update.yml`, `issue-platform-labels.yml`.

Composite actions:

- `.forgejo/actions/setup/action.yml` — pnpm (action-setup) → Node 24.21.0
  with pnpm cache → mise 2026.9.7 (`cache: true`, `env: false`) →
  `mise settings set trusted_config_paths "$GITHUB_WORKSPACE"` → WASM binding
  cache keyed on `hashFiles(crates/**, Cargo.toml, Cargo.lock,
rust-toolchain.toml, .cargo/config.toml, mise.toml, scripts/build-wasm.mjs)`
  → optional rust 1.98.1 + `wasm32-unknown-unknown` + sccache 0.18.0 +
  Swatinem/rust-cache → `pnpm install --frozen-lockfile` → `pnpm wasm:build`
  on cache miss → Sentry source-map guard → `pnpm exec vite build` (not
  `pnpm build`, whose `prebuild` hook would rebuild the bindings).
- `.forgejo/actions/rust/action.yml` — mise + optional **Linux Tauri deps**
  (see §8) for `tauri-dependencies: 'true'`.

Env shared by CI: `MISE_GITHUB_TOKEN` (rate limits), `CARGO_INCREMENTAL=0`,
`sccache` via `SCCACHE_BUCKET=sccache`, `SCCACHE_ENDPOINT=https://s3.erwanleboucher.dev`,
`RUSTC_WRAPPER=sccache` only when AWS creds exist.

## 8. System dependencies for CI / a runner

**Web + Rust quality jobs (ubuntu-latest) — no extra apt packages.**
Needed: git, `mise` ≥ 2026.7.11, Node 24.21.0 + pnpm 12.4.1 (mise installs
both), Rust 1.98.1 with `wasm32-unknown-unknown` + clippy + rustfmt.
`pnpm install` builds `esbuild`/`lightningcss` (allow-listed in
`pnpm-workspace.yaml`) from prebuilt binaries — no compiler required.

**Tauri / Linux desktop build** (`.forgejo/actions/rust`, `tauri-dependencies: true`):

```
build-essential curl file libayatana-appindicator3-dev libclang-dev
libpipewire-0.3-dev libssl-dev libwebkit2gtk-4.1-dev libxdo-dev librsvg2-dev
patchelf wget
```

`tauri-build.yml` installs a slightly different set (adds `libgtk-3-dev`,
`libsoup-3.0-dev`, `pkg-config`, `libayatana-appindicator3-1` runtime, drops
`curl/wget/patchelf`). The canonical cross-distro list lives in
`mise.tauri.toml [bootstrap.packages]` for apt / dnf / pacman / apk —
`mise run tauri:setup` applies it, so prefer that over hand-rolled apt.

**WASM browser tests:** `google-chrome-stable` **and the chromedriver matching
that Chrome milestone** on `PATH` (CI fetches it from the Chrome for Testing
milestone JSON), plus `python3` and `unzip` for the fetch step;
`WASM_BINDGEN_TEST_WEBDRIVER_JSON=.forgejo/webdriver.json`; the runner
`wasm-bindgen-test-runner` ships with the mise-pinned wasm-bindgen.

**Playwright e2e:** a Docker daemon (testcontainers homeserver fixture — this
is why the job runs on a `docker` runner, not `ubuntu-latest`),
`pnpm exec playwright install chromium webkit` +
`pnpm exec playwright install-deps chromium webkit` (apt libs outside the
browser cache), optional `SABLE_E2E_PREBUILT=1` to reuse the `build` job's
bindings.

**Optional:** sccache + `SCCACHE_*`/`AWS_*` secrets (pure speed),
`MISE_GITHUB_TOKEN` (mise/GitHub API rate limits), `mise settings set
trusted_config_paths "$GITHUB_WORKSPACE"` (mise refuses an untrusted project
`mise.toml`; every workflow runs this step), Sentry `VITE_SENTRY_DSN` ⇒
`SENTRY_AUTH_TOKEN`/`SENTRY_ORG`/`SENTRY_PROJECT` are then mandatory (CI
asserts this).

**Mobile:** Android — `sdkmanager` licenses, `platform-tools`,
`platforms;android-36`, `build-tools;35.0.0`, `ndk;29.0.14206865`;
iOS — Xcode + cocoapods; Windows — VS Build Tools (VCTools workload,
Win11 SDK 26100) + WebView2 runtime.

## 9. Gotchas

1. `wasm-bindgen` CLI version is asserted against `Cargo.lock`; bump both or
   the WASM build fails immediately.
2. `.cargo/config.toml` rustflags are load-bearing: `getrandom_backend="wasm_js"`
   (getrandom 0.3 refuses wasm32 otherwise) and `runner = "wasm-bindgen-test-runner"`.
3. `sable-wasm` cannot be built for the host target — always
   `--target wasm32-unknown-unknown`.
4. Clippy on `-p app` must not get `--all-features` (the comment in `mise.toml`
   says it turns on both desktop runtimes and downloads CEF); the workspace-wide
   clippy/nextest commands all carry `--exclude app`, and `sable-wasm` only
   builds for wasm32 anyway.
5. CI builds with `pnpm exec vite build`, not `pnpm build`, to avoid the
   `prebuild` hook recompiling cached bindings.
6. Generated files are checked: `src/generated/protocol.ts` (Specta) via
   `check:types`, `src/generated/wasm` (restored from cache, key covers all
   Rust inputs).
7. `pnpm test:e2e` writes to `src/generated/wasm-e2e` so it can run alongside
   the dev server's `src/generated/wasm`.
8. Conventions for upstream contributions: DCO (`git commit -s`) and an
   explicit **no AI-generated contributions** policy in `CONTRIBUTING.md` —
   relevant only if changes are sent upstream.
9. Hooks are installed by `pnpm install` (`prepare` →
   `scripts/install-git-hooks.mjs`); a CI checkout that skips `pnpm install`
   has no lefthook.
