#!/usr/bin/env bash
# Build release binaries in the pinned-Zig Docker image, package them, and cut a
# GitHub release. Manually triggered — locally (`scripts/release.sh v0.1.0`) or
# via the release workflow. Requires docker (with BuildKit), node (for the
# formula template), and an authenticated gh CLI (GH_TOKEN / GITHUB_TOKEN in CI).
set -euo pipefail

TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: $0 <tag>   e.g. $0 v0.1.0"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"
STAGE="$DIST/assets"
rm -rf "$DIST"; mkdir -p "$STAGE"

# Where the Homebrew formula is published. Set CB_SKIP_TAP=1 to skip the update.
REPO="ryaninvents/compare-branch"
TAP="${CB_HOMEBREW_TAP:-ryaninvents/homebrew-tap}"

# Map zig triples to friendly asset names.
friendly() {
  case "$1" in
    aarch64-macos)       echo "macos-arm64" ;;
    x86_64-macos)        echo "macos-x86_64" ;;
    aarch64-linux-musl)  echo "linux-arm64" ;;
    x86_64-linux-musl)   echo "linux-x86_64" ;;
    *)                   echo "$1" ;;
  esac
}

# Look up a packaged asset's sha256 from the generated SHA256SUMS by friendly name.
sha_for() { awk -v f="-$1.tar.gz" 'index($2, f) { print $1 }' "$STAGE/SHA256SUMS"; }

# Render scripts/formula/cb.rb.ejs against this release's assets into
# $STAGE/cb.rb. It's attached to the GitHub release below, not pushed to the
# tap directly — ryaninvents/homebrew-tap's own update-formula workflow pulls
# it from there (see trigger_tap_update).
render_formula() {
  CB_FORMULA_REPO="$REPO" \
  CB_FORMULA_TAG="$TAG" \
  CB_FORMULA_VERSION="${TAG#v}" \
  CB_FORMULA_SHA_MACOS_ARM64="$(sha_for macos-arm64)" \
  CB_FORMULA_SHA_MACOS_X86_64="$(sha_for macos-x86_64)" \
  CB_FORMULA_SHA_LINUX_ARM64="$(sha_for linux-arm64)" \
  CB_FORMULA_SHA_LINUX_X86_64="$(sha_for linux-x86_64)" \
    node "$ROOT/scripts/render-formula.mjs" > "$STAGE/cb.rb"
}

# Ask the tap repo's own workflow to fetch this release's cb.rb asset and
# commit it. The default GITHUB_TOKEN can't dispatch workflows in a different
# repo, so CI must provide HOMEBREW_TAP_TOKEN (a PAT/App token with the
# `actions: write` — classic PAT: `workflow` — scope on the tap repo; it no
# longer needs to write repo contents, since the tap's own workflow does that
# with its own token).
trigger_tap_update() {
  GH_TOKEN="${HOMEBREW_TAP_TOKEN:?HOMEBREW_TAP_TOKEN is required to trigger the tap update}" \
    gh workflow run update-formula.yml --repo "$TAP" -f project=compare-branch
}

echo ">> building binaries in Docker (pinned Zig)"
DOCKER_BUILDKIT=1 docker build --target artifacts --output "type=local,dest=$DIST/release" "$ROOT"

echo ">> packaging assets"
for dir in "$DIST"/release/*/; do
  triple="$(basename "$dir")"
  name="cb-${TAG}-$(friendly "$triple")"
  pkg="$STAGE/$name"
  mkdir -p "$pkg"
  cp "$dir/cb-bin" "$pkg/cb-bin"
  cp "$ROOT/README.md" "$pkg/README.md" 2>/dev/null || true
  cp "$ROOT/LICENSE" "$pkg/LICENSE" 2>/dev/null || true
  # Ship the shell integration, completion scripts, and man pages the
  # formula installs.
  cp -R "$ROOT/shell" "$pkg/shell"
  cp -R "$ROOT/completions" "$pkg/completions"
  cp -R "$ROOT/man" "$pkg/man"
  tar -C "$STAGE" -czf "$STAGE/$name.tar.gz" "$name"
  rm -rf "$pkg"
done

( cd "$STAGE" && shasum -a 256 ./*.tar.gz > SHA256SUMS 2>/dev/null || sha256sum ./*.tar.gz > SHA256SUMS )

echo ">> rendering Homebrew formula"
render_formula

echo ">> creating GitHub release $TAG"
gh release create "$TAG" \
  --title "$TAG" \
  --notes "cb $TAG — disposable git worktree manager. Install: extract the archive for your platform, put cb-bin on PATH, then add \`eval \"\$(cb-bin init zsh)\"\` (or bash) to your shell rc." \
  "$STAGE"/*.tar.gz "$STAGE/SHA256SUMS" "$STAGE/cb.rb"

if [ "${CB_SKIP_TAP:-0}" = "1" ]; then
  echo ">> skipping Homebrew tap update trigger (CB_SKIP_TAP=1)"
else
  echo ">> triggering Homebrew tap update ($TAP)"
  trigger_tap_update
fi

echo ">> done"
