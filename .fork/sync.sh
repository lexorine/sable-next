#!/usr/bin/env bash
# Usage: .fork/sync.sh <msc2815|upstream> <workdir> <parent-rev>
# Builds one snapshot commit (upstream + .fork patches, regenerated protocol.ts, fixed FOD hashes)
# on top of <parent-rev> and leaves it checked out cleanly in <workdir>. Never builds or pushes.
# Outputs (stdout and $GITHUB_OUTPUT): status=ok|unchanged|conflict, upstream, commit, conflicts.
# Refreshing the patches after a conflict, in a fresh upstream clone:
#   git am -3 <fork>/.fork/patches/msc2815-*.patch   (resolve, git am --continue)
#   git format-patch --no-signature --zero-commit -o <fork>/.fork/patches <base>..HEAD -- . ':(exclude)src/generated/protocol.ts'
#   rename to msc2815-NNNN-*.patch, update msc2815.base, push to main.
set -euo pipefail
variant=$1 W=$2 parent=$3
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/SableClient/sable-next.git}
UPSTREAM_REF=${UPSTREAM_REF:-main}
FORCE=${FORCE:-false}
here=$(git rev-parse --show-toplevel)
fork_rev=$(git -C "$here" rev-parse HEAD)
out() {
  echo "$1=$2"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then echo "$1=$2" >>"$GITHUB_OUTPUT"; fi
}

git -C "$here" fetch -q --no-tags "$UPSTREAM_URL" "+refs/heads/$UPSTREAM_REF:refs/upstream/$UPSTREAM_REF"
up=$(git -C "$here" rev-parse "refs/upstream/$UPSTREAM_REF")
out upstream "$up"

rm -rf "${W:?}"
git clone -q --shared --no-checkout "$here" "$W"
cd "$W"
git -c advice.detachedHead=false checkout -q --detach "$up"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Upstream's own workflows must never land here: schedules run on the default branch.
git rm -rq --ignore-unmatch .github/workflows
git checkout "$fork_rev" -- .fork .github/workflows/sync-build.yml

shopt -s nullglob
patches=(.fork/patches/nix-*.patch)
if [[ $variant == msc2815 ]]; then patches+=(.fork/patches/msc2815-*.patch); fi
for p in "${patches[@]}"; do
  if ! git apply --3way --index --whitespace=nowarn "$p"; then
    out status conflict
    out conflicts "$(basename "$p"): $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
    exit 0
  fi
done

nix flake update nixpkgs

if [[ $variant == msc2815 ]]; then
  CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-${RUNNER_TEMP:-/tmp}/typegen-target} \
    nix shell --inputs-from . nixpkgs#cargo nixpkgs#rustc nixpkgs#gcc nixpkgs#cmake nixpkgs#perl \
    -c cargo run --locked -p sable-core --example generate-types --features typegen
fi

# Nix only sees tracked files.
git add -A

# Same fix-up as upstream's flake-lock-fix.yml; twice in case one fix unmasks another.
for _ in 1 2; do
  log=$(nix build -L --keep-going --no-link \
    .#sable-unwrapped.pnpmDeps .#sable-unwrapped.cargoDeps .#sable-deepfilternet-assets 2>&1 || true)
  pairs=$(grep -E '(specified|got):' <<<"$log" | grep -oE 'sha256-[A-Za-z0-9+/=]+' | paste - - || true)
  [[ -z $pairs ]] && break
  while read -r old new; do sed -i "s|$old|$new|" packaging/nix/*.nix; done <<<"$pairs"
  git add -A
done
nix build --no-link .#sable-unwrapped.pnpmDeps .#sable-unwrapped.cargoDeps .#sable-deepfilternet-assets

tree=$(git write-tree)
if [[ $FORCE != true && $tree == "$(git rev-parse "$parent^{tree}")" ]]; then
  out status unchanged
  exit 0
fi
nixpkgs_rev=$(nix flake metadata --json . | jq -r '.locks.nodes.nixpkgs.locked.rev')
commit=$(git commit-tree "$tree" -p "$parent" <<EOF
sync($variant): upstream ${up:0:12}, nixpkgs ${nixpkgs_rev:0:12}

Upstream-Commit: $up
Nixpkgs-Rev: $nixpkgs_rev
Fork-Rev: $fork_rev
Variant: $variant
EOF
)
# A clean checkout keeps src.shortRev identical to what a github: fetch of the commit sees.
git checkout -q --detach "$commit"
if [[ -n $(git status --porcelain) ]]; then
  echo "worktree dirty after commit" >&2
  exit 1
fi
out commit "$commit"
out status ok
