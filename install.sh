#!/usr/bin/env bash
set -euo pipefail

readonly REPO="celados/grok-build"
readonly VERSION="${1:-}"

if [[ -n "$VERSION" && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid release version: $VERSION (expected X.Y.Z)" >&2
  exit 2
fi

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "This distribution only supports Apple Silicon macOS." >&2
  exit 1
fi

if command -v curl >/dev/null 2>&1; then
  downloader=curl
elif command -v wget >/dev/null 2>&1; then
  downloader=wget
else
  echo "Either curl or wget is required." >&2
  exit 1
fi

download() {
  local url="$1"
  local output="${2:-}"

  if [[ "$downloader" == curl ]]; then
    if [[ -n "$output" ]]; then
      curl -fsSL --retry 3 --output "$output" "$url"
    else
      curl -fsSL --retry 3 "$url"
    fi
  elif [[ -n "$output" ]]; then
    wget -q --tries=3 --output-document="$output" "$url"
  else
    wget -q --tries=3 --output-document=- "$url"
  fi
}

version="$VERSION"
if [[ -z "$version" ]]; then
  echo "Fetching the latest custom release..." >&2
  release_json="$(download "https://api.github.com/repos/$REPO/releases/latest")"
  version="$(printf '%s\n' "$release_json" | sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"v?([^"]+)".*/\1/p' | head -1)"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Could not resolve the latest release version." >&2
    exit 1
  fi
fi

grok_home="${GROK_HOME:-${HOME:?HOME is required}/.grok}"
download_dir="$grok_home/downloads"
bin_dir="${GROK_BIN_DIR:-$grok_home/bin}"
asset="grok-$version-macos-aarch64"
binary="$download_dir/$asset"
tmp="$binary.tmp.$$"

mkdir -p "$download_dir" "$bin_dir"
trap 'rm -f "$tmp"' EXIT INT TERM

echo "Installing Grok $version (macOS aarch64)..." >&2
download "https://github.com/$REPO/releases/download/v$version/$asset" "$tmp"
chmod 755 "$tmp"

# Validate before replacing the current binary so a bad release cannot break a
# working installation.
if ! "$tmp" --version </dev/null >/dev/null 2>&1; then
  echo "The downloaded Grok binary failed to run; the existing install was kept." >&2
  exit 1
fi

mv -f "$tmp" "$binary"
ln -sfn "../downloads/$asset" "$bin_dir/grok"
ln -sfn "../downloads/$asset" "$bin_dir/agent"
ln -sfn "$asset" "$download_dir/grok-latest"

path_has_dir() {
  case ":$PATH:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

# A profile edit cannot alter the parent shell that invoked `curl | bash`.
# Linking into an existing PATH entry makes the new command usable immediately.
linked_dir=""
if ! path_has_dir "$bin_dir"; then
  for candidate in "$HOME/.local/bin" /usr/local/bin; do
    if path_has_dir "$candidate" && [[ -d "$candidate" && -w "$candidate" ]]; then
      ln -sfn "$bin_dir/grok" "$candidate/grok"
      ln -sfn "$bin_dir/agent" "$candidate/agent"
      linked_dir="$candidate"
      break
    fi
  done
fi

user_shell="$(basename "${SHELL:-}")"
config_file=""
case "$user_shell" in
  fish) config_file="$HOME/.config/fish/config.fish" ;;
  zsh) config_file="$HOME/.zshrc" ;;
  bash) config_file="$HOME/.bashrc" ;;
esac

if [[ -n "$config_file" ]]; then
  mkdir -p "$(dirname "$config_file")"

  # Rewrite the dotfiles target rather than replacing a symlink managed by
  # stow or another dotfile manager.
  if [[ -e "$config_file" || -L "$config_file" ]]; then
    resolved="$config_file"
    depth=0
    while [[ -L "$resolved" && "$depth" -lt 40 ]]; do
      link="$(readlink "$resolved")"
      if [[ "$link" == /* ]]; then
        resolved="$link"
      else
        resolved="$(cd "$(dirname "$resolved")" && pwd -P)/$link"
      fi
      depth=$((depth + 1))
    done
    if [[ ! -L "$resolved" ]]; then
      config_file="$(cd "$(dirname "$resolved")" && pwd -P)/$(basename "$resolved")"
    fi
  fi

  if [[ "$bin_dir" == "$HOME/.grok/bin" ]]; then
    shell_bin_dir='$HOME/.grok/bin'
  else
    shell_bin_dir="$bin_dir"
  fi

  case "$user_shell" in
    fish)
      new_block="# >>> grok-build installer >>>
fish_add_path \"$shell_bin_dir\"
# <<< grok-build installer <<<"
      ;;
    *)
      new_block="# >>> grok-build installer >>>
export PATH=\"$shell_bin_dir:\$PATH\"
# <<< grok-build installer <<<"
      ;;
  esac

  if grep -qs '# >>> grok-build installer >>>' "$config_file" 2>/dev/null; then
    config_tmp="$config_file.tmp.$$"
    awk '
      /# >>> grok-build installer >>>/ { skip=1; next }
      /# <<< grok-build installer <<</ { skip=0; next }
      !skip { print }
    ' "$config_file" > "$config_tmp"
    mv "$config_tmp" "$config_file"
  elif [[ -f "$config_file" ]]; then
    cp "$config_file" "$config_file.bak.$(date +%s)"
  fi

  printf '\n%s\n' "$new_block" >> "$config_file"

  # Login Bash on macOS does not read .bashrc unless .bash_profile delegates.
  if [[ "$user_shell" == bash ]] && ! grep -qs 'source ~/.bashrc' "$HOME/.bash_profile" 2>/dev/null; then
    printf '\n[[ -r ~/.bashrc ]] && source ~/.bashrc\n' >> "$HOME/.bash_profile"
  fi
fi

echo "Installed: $bin_dir/grok" >&2
if path_has_dir "$bin_dir" || [[ -n "$linked_dir" ]]; then
  [[ -n "$linked_dir" ]] && echo "Linked: $linked_dir/grok" >&2
  echo "Run 'grok' or 'agent' to get started." >&2
elif [[ -n "$config_file" ]]; then
  echo "Restart the terminal, then run 'grok' or 'agent'." >&2
else
  echo "Add $bin_dir to PATH, then run 'grok' or 'agent'." >&2
fi

"$bin_dir/grok" --version
