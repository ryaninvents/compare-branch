#!/usr/bin/env bash
# Build release binaries in the pinned-Zig Docker image, package them, and cut a
# GitHub release. Manually triggered — locally (`scripts/release.sh v0.1.0`) or
# via the release workflow. Requires docker (with BuildKit) and an authenticated
# gh CLI (GH_TOKEN / GITHUB_TOKEN in CI).
set -euo pipefail

TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: $0 <tag>   e.g. $0 v0.1.0"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"
STAGE="$DIST/assets"
rm -rf "$DIST"; mkdir -p "$STAGE"

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
  tar -C "$STAGE" -czf "$STAGE/$name.tar.gz" "$name"
  rm -rf "$pkg"
done

( cd "$STAGE" && shasum -a 256 ./*.tar.gz > SHA256SUMS 2>/dev/null || sha256sum ./*.tar.gz > SHA256SUMS )

echo ">> creating GitHub release $TAG"
gh release create "$TAG" \
  --title "$TAG" \
  --notes "cb $TAG — disposable git worktree manager. Install: extract the archive for your platform, put cb-bin on PATH, then add \`eval \"\$(cb-bin init zsh)\"\` (or bash) to your shell rc." \
  "$STAGE"/*.tar.gz "$STAGE/SHA256SUMS"

echo ">> done"
