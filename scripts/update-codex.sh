#!/usr/bin/env bash
set -euo pipefail

REPO="openai/codex"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Error: this script only supports Linux." >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64)        TARGET="x86_64-unknown-linux-musl" ;;
  aarch64|arm64) TARGET="aarch64-unknown-linux-musl" ;;
  *) echo "Error: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

command -v curl     >/dev/null || { echo "Error: curl is required." >&2; exit 1; }
command -v tar      >/dev/null || { echo "Error: tar is required." >&2; exit 1; }
command -v readlink >/dev/null || { echo "Error: readlink is required." >&2; exit 1; }
command -v file     >/dev/null || { echo "Error: file utility is required." >&2; exit 1; }
command -v install  >/dev/null || { echo "Error: install is required." >&2; exit 1; }

active_codex="$(command -v codex || true)"

if [[ -z "$active_codex" ]]; then
  echo "Error: codex is not currently installed or not present in PATH." >&2
  exit 1
fi

codex_path="$(readlink -f "$active_codex")"
codex_dir="$(dirname "$codex_path")"

if [[ ! -f "$codex_path" || ! -x "$codex_path" ]]; then
  echo "Error: active codex is not a regular executable file: $codex_path" >&2
  exit 1
fi

reject_installation() {
  echo "Error: refusing to upgrade this Codex installation." >&2
  echo "Reason: $1" >&2
  echo "Detected path: $codex_path" >&2
  echo >&2
  echo "This script only upgrades direct GitHub binary installations." >&2
  exit 1
}

case "$codex_path" in
  */node_modules/*|*/.npm/*|*/npm/*)
    reject_installation "this looks like an npm-managed installation"
    ;;
  /snap/*|/var/lib/snapd/*)
    reject_installation "this looks like a Snap installation"
    ;;
  /app/*|*/flatpak/*)
    reject_installation "this looks like a Flatpak installation"
    ;;
  */.linuxbrew/*|*/linuxbrew/*|*/Homebrew/*)
    reject_installation "this looks like a Homebrew/Linuxbrew installation"
    ;;
  /usr/bin/*|/bin/*)
    reject_installation "this looks like a distribution-managed system installation"
    ;;
esac

if file "$codex_path" | grep -qiE 'script|text|node'; then
  reject_installation "the active codex command is a script/wrapper, not a direct binary"
fi

if ! "$codex_path" --version 2>/dev/null | grep -q '^codex-cli '; then
  reject_installation "the executable does not look like the Codex CLI binary"
fi

echo "Detected direct Codex installation:"
echo "  $codex_path"
echo

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

install_binary() {
  local exe="$1"
  local destination="$2"
  local destination_dir

  destination_dir="$(dirname "$destination")"

  if [[ -w "$destination_dir" && ( ! -e "$destination" || -w "$destination" ) ]]; then
    install -m 0755 "$exe" "$destination"
  else
    command -v sudo >/dev/null || {
      echo "Error: sudo is required to write to $destination." >&2
      exit 1
    }

    sudo install -m 0755 "$exe" "$destination"
  fi
}

download_and_install() {
  local name="$1"
  local destination="$2"
  local archive_name="${name}-${TARGET}"
  local asset="${archive_name}.tar.gz"
  local url="https://github.com/${REPO}/releases/latest/download/${asset}"

  echo "Downloading ${asset}..."

  curl -fL "$url" -o "$tmp/${asset}" || {
    echo "Error: failed to download ${asset}." >&2
    exit 1
  }

  mkdir -p "$tmp/${name}"
  tar -xzf "$tmp/${asset}" -C "$tmp/${name}"

  local exe="${tmp}/${name}/${archive_name}"

  if [[ ! -f "$exe" ]]; then
    echo "Error: cannot find expected executable '${archive_name}' inside ${asset}." >&2
    echo "Archive content:" >&2
    tar -tzf "$tmp/${asset}" >&2
    exit 1
  fi

  chmod +x "$exe"
  install_binary "$exe" "$destination"

  echo "Installed $destination"
}

download_and_install codex "$codex_path"

bwrap_path="$(command -v bwrap || true)"

if [[ -n "$bwrap_path" ]]; then
  bwrap_path="$(readlink -f "$bwrap_path")"

  case "$bwrap_path" in
    /usr/bin/*|/bin/*|/snap/*|/var/lib/snapd/*|/app/*|*/flatpak/*|*/.linuxbrew/*|*/linuxbrew/*|*/Homebrew/*)
      echo
      echo "Refusing to replace likely package-managed bwrap at:"
      echo "  $bwrap_path"
      echo "Only codex was upgraded."
      ;;
    *)
      echo
      echo "Detected direct bwrap installation:"
      echo "  $bwrap_path"
      download_and_install bwrap "$bwrap_path"
      ;;
  esac
else
  candidate_bwrap="${codex_dir}/bwrap"

  echo
  echo "No bwrap found in PATH."
  echo "Installing Codex bwrap next to codex:"
  echo "  $candidate_bwrap"

  download_and_install bwrap "$candidate_bwrap"
fi

echo
"$codex_path" --version || true

if command -v bwrap >/dev/null; then
  bwrap --version || true
elif [[ -x "${codex_dir}/bwrap" ]]; then
  "${codex_dir}/bwrap" --version || true
fi
