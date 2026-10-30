#!/bin/bash
# Installs or updates Uso from the latest GitHub release, picking the build for this Mac's chip:
#   curl -fsSL https://raw.githubusercontent.com/bujosa/uso/main/scripts/get.sh | bash
# USO_VERSION=1.4.0 picks a release. USO_INSTALL_DIR picks the folder (default ~/Applications, or
# /Applications when Uso is already there).
set -euo pipefail

repo="bujosa/uso"
work=""

fail() {
  echo "uso: $*" >&2
  exit 1
}

main() {
  [ "$(uname -s)" = Darwin ] || fail "Uso runs on macOS only."
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge 14 ] || fail "Uso needs macOS 14 or later. This Mac has $(sw_vers -productVersion)."

  # hw.optional.arm64 is 1 on Apple silicon, even from a Terminal running under Rosetta.
  local chip="intel"
  if [ "$(sysctl -in hw.optional.arm64)" = 1 ]; then chip="apple-silicon"; fi

  local version="${USO_VERSION:-}"
  if [ -z "$version" ]; then
    local latest
    latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")" ||
      fail "Can't reach GitHub."
    version="${latest##*/tag/v}"
  fi
  case "$version" in
    "" | */* | *:*) fail "Can't find the latest Uso release." ;;
  esac

  local zip="Uso-$version-macOS-$chip.zip"
  local url="https://github.com/$repo/releases/download/v$version/$zip"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  echo "Downloading Uso $version for $chip Macs…"
  curl -fL --progress-bar -o "$work/$zip" "$url" || fail "Can't download $url"
  curl -fsSL -o "$work/$zip.sha256" "$url.sha256" || fail "Can't download the checksum for $zip"
  (cd "$work" && shasum -a 256 -c "$zip.sha256" >/dev/null) || fail "$zip doesn't match its checksum."

  ditto -x -k "$work/$zip" "$work/app"
  codesign --verify --strict "$work/app/Uso.app" || fail "Uso.app's code signature is invalid."

  local dir="${USO_INSTALL_DIR:-}"
  if [ -z "$dir" ]; then
    dir="$HOME/Applications"
    if [ -d /Applications/Uso.app ] && [ -w /Applications ]; then dir="/Applications"; fi
  fi
  mkdir -p "$dir"

  # Quit the running copy and wait, so macOS doesn't refuse to open the new one.
  if pkill -x Uso 2>/dev/null; then
    local tries=0
    while pgrep -x Uso >/dev/null && [ "$tries" -lt 50 ]; do
      sleep 0.1
      tries=$((tries + 1))
    done
  fi
  rm -rf "$dir/Uso.app"
  ditto "$work/app/Uso.app" "$dir/Uso.app"

  open "$dir/Uso.app" || fail "Installed $dir/Uso.app, but macOS couldn't open it. Open it from Finder."
  echo "Installed Uso $version in $dir. Look for it in the menu bar."
}

main "$@"
