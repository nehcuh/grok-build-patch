#!/usr/bin/env bash
set -euo pipefail

REPO="celados/grok-build"
VERSION="${1:-}"

command -v gh >/dev/null || {
  echo "The custom updater requires the GitHub CLI (gh)." >&2
  exit 1
}

if [[ -z "$VERSION" ]]; then
  VERSION="$(gh release view --repo "$REPO" --json tagName --jq '.tagName' | sed 's/^v//')"
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid release version: $VERSION" >&2
  exit 2
fi

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "This distribution only supports macOS arm64." >&2
  exit 1
fi

grok_home="${GROK_HOME:-${HOME:?HOME is required}/.grok}"
download_dir="$grok_home/downloads"
bin_dir="$grok_home/bin"
asset="grok-$VERSION-macos-aarch64"
tmp="$download_dir/.$asset.tmp.$$"

mkdir -p "$download_dir" "$bin_dir"
trap 'rm -f "$tmp"' EXIT INT TERM
gh release download "v$VERSION" --repo "$REPO" --pattern "$asset" --output "$tmp" --clobber
chmod 755 "$tmp"
mv -f "$tmp" "$download_dir/$asset"
ln -sfn "../downloads/$asset" "$bin_dir/grok"
ln -sfn "../downloads/$asset" "$bin_dir/agent"
ln -sfn "$asset" "$download_dir/grok-latest"

echo "installed: $bin_dir/grok"
echo "ensure $bin_dir is on PATH"
"$bin_dir/grok" --version
