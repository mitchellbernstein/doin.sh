#!/bin/sh
set -eu
# Run from a downloaded script; DOIN_REPO selects the final public repository.
repo=${DOIN_REPO:-mitchellbernstein/doin.sh}
if [ -z "$repo" ]; then
  echo 'Set DOIN_REPO=OWNER/REPOSITORY to the public release repository.' >&2
  exit 1
fi
case "$repo" in *[!a-zA-Z0-9_./-]*|/*|*..* ) echo 'Invalid DOIN_REPO.' >&2; exit 1;; esac
case "$(uname -s)" in Darwin) platform=macos;; Linux) platform=linux;; *) echo 'Supported platforms: macOS and Linux.' >&2; exit 1;; esac
case "$(uname -m)" in arm64|aarch64) arch=aarch64;; x86_64|amd64) arch=x86_64;; *) echo 'Supported architectures: arm64 and x86_64.' >&2; exit 1;; esac
version=${DOIN_VERSION:-latest}
if [ "$version" = latest ]; then base="https://github.com/$repo/releases/latest/download"; else
  case "$version" in *[!a-zA-Z0-9_.-]*) echo 'Invalid version.' >&2; exit 1;; esac
  base="https://github.com/$repo/releases/download/$version"
fi
archive="doin-$platform-$arch.tar.gz"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
curl --disable --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$base/$archive" -o "$work/$archive"
curl --disable --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$base/SHA256SUMS" -o "$work/SHA256SUMS"
expected=$(awk -v name="$archive" '$2 == name {print $1}' "$work/SHA256SUMS")
case "$expected" in ''|*[!a-fA-F0-9]*) echo 'Missing or invalid checksum.' >&2; exit 1;; esac
[ "${#expected}" -eq 64 ] || { echo 'Invalid checksum length.' >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$work/$archive" | awk '{print $1}'); else actual=$(shasum -a 256 "$work/$archive" | awk '{print $1}'); fi
[ "$actual" = "$expected" ] || { echo 'Checksum mismatch; install stopped.' >&2; exit 1; }
# Archives contain the executable and its license; extract only the executable.
tar -xzf "$work/$archive" -C "$work" doin
[ -f "$work/doin" ] && [ ! -L "$work/doin" ] || { echo 'Invalid release executable.' >&2; exit 1; }
dest=${DOIN_INSTALL_DIR:-"$HOME/.local/bin"}
mkdir -p "$dest"
if [ -e "$dest/doin" ] && [ "${DOIN_REPLACE:-0}" != 1 ]; then
  echo "$dest/doin already exists. Set DOIN_REPLACE=1 to update it." >&2
  exit 1
fi
install -m 755 "$work/doin" "$dest/doin"
printf 'Installed %s/doin\nAdd %s to PATH, then run doin.\n' "$dest" "$dest"
