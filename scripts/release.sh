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

# Where the Homebrew formula is published. Set CB_SKIP_TAP=1 to skip the bump.
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

# Render Formula/cb.rb from the freshly-built assets and push it to the tap.
# The default GITHUB_TOKEN cannot write to a different repo, so CI must provide
# HOMEBREW_TAP_TOKEN (a PAT/App token with contents:write on the tap).
publish_formula() {
  local version="${TAG#v}"
  local url_base="https://github.com/${REPO}/releases/download/${TAG}"
  local work="$DIST/tap"
  local remote="https://github.com/${TAP}.git"
  [ -n "${HOMEBREW_TAP_TOKEN:-}" ] && remote="https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/${TAP}.git"

  git clone --depth 1 "$remote" "$work"
  mkdir -p "$work/Formula"
  cat > "$work/Formula/cb.rb" <<EOF
class Cb < Formula
  desc "Disposable git worktree manager"
  homepage "https://github.com/${REPO}"
  version "${version}"
  license "MIT"

  depends_on "git"

  on_macos do
    on_arm do
      url "${url_base}/cb-${TAG}-macos-arm64.tar.gz"
      sha256 "$(sha_for macos-arm64)"
    end
    on_intel do
      url "${url_base}/cb-${TAG}-macos-x86_64.tar.gz"
      sha256 "$(sha_for macos-x86_64)"
    end
  end

  on_linux do
    on_arm do
      url "${url_base}/cb-${TAG}-linux-arm64.tar.gz"
      sha256 "$(sha_for linux-arm64)"
    end
    on_intel do
      url "${url_base}/cb-${TAG}-linux-x86_64.tar.gz"
      sha256 "$(sha_for linux-x86_64)"
    end
  end

  def install
    bin.install "cb-bin"
  end

  def caveats
    <<~CAVEATS
      cb is driven by a shell function that fronts cb-bin (needed for \`cb cd\`,
      \`cb exit\`, and \`cb done\`). Add the integration to your shell rc:
        eval "\$(cb-bin init zsh)"    # ~/.zshrc
        eval "\$(cb-bin init bash)"   # ~/.bashrc
    CAVEATS
  end

  test do
    assert_match "cb", shell_output("#{bin}/cb-bin init zsh")
  end
end
EOF

  git -C "$work" add Formula/cb.rb
  git -C "$work" -c user.name="${GIT_AUTHOR_NAME:-cb release bot}" \
    -c user.email="${GIT_AUTHOR_EMAIL:-noreply@github.com}" \
    commit -m "cb ${TAG}"
  git -C "$work" push "$remote" HEAD
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
  tar -C "$STAGE" -czf "$STAGE/$name.tar.gz" "$name"
  rm -rf "$pkg"
done

( cd "$STAGE" && shasum -a 256 ./*.tar.gz > SHA256SUMS 2>/dev/null || sha256sum ./*.tar.gz > SHA256SUMS )

echo ">> creating GitHub release $TAG"
gh release create "$TAG" \
  --title "$TAG" \
  --notes "cb $TAG — disposable git worktree manager. Install: extract the archive for your platform, put cb-bin on PATH, then add \`eval \"\$(cb-bin init zsh)\"\` (or bash) to your shell rc." \
  "$STAGE"/*.tar.gz "$STAGE/SHA256SUMS"

if [ "${CB_SKIP_TAP:-0}" = "1" ]; then
  echo ">> skipping Homebrew tap bump (CB_SKIP_TAP=1)"
else
  echo ">> bumping Homebrew formula in $TAP"
  publish_formula
fi

echo ">> done"
