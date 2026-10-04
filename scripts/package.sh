#!/bin/sh
set -eu
name=${DOIN_BUILD_NAME:-doin}
version=${DOIN_BUILD_VERSION:-${GITHUB_REF_NAME:-0.3.0}}
version=${version#v}
case "$name" in ''|*[!a-z0-9-]*) echo 'Use a lowercase command name.' >&2; exit 1;; esac
case "$version" in
  ''|*[!0-9.]*|.*|*.|*..*) echo 'Use a stable numeric version (major.minor.patch).' >&2; exit 1;;
esac
case "$version" in *.*.*) ;; *) echo 'Use a stable numeric version (major.minor.patch).' >&2; exit 1;; esac
major=${version%%.*}
rest=${version#*.}
minor=${rest%%.*}
patch=${rest#*.}
case "$patch" in *.*) echo 'Use a stable numeric version (major.minor.patch).' >&2; exit 1;; esac
case "$major" in 0|[1-9]*) ;; *) echo 'Use a stable numeric version (major.minor.patch).' >&2; exit 1;; esac
case "$minor" in 0|[1-9]*) ;; *) echo 'Use a stable numeric version (major.minor.patch).' >&2; exit 1;; esac
case "$patch" in 0|[1-9]*) ;; *) echo 'Use a stable numeric version (major.minor.patch).' >&2; exit 1;; esac
mkdir -p dist
for pair in macos:aarch64 macos:x86_64 linux:aarch64 linux:x86_64; do
  os=${pair%:*}
  arch=${pair#*:}
  if [ "$os" = linux ]; then target="$arch-linux-musl"; else target="$arch-macos.15.0"; fi
  zig build -j1 -Doptimize=ReleaseSmall -Dname="$name" -Dversion="$version" -Dtarget="$target" --prefix "package/$os-$arch"
  cp LICENSE "package/$os-$arch/bin/LICENSE"
  COPYFILE_DISABLE=1 tar -czf "dist/$name-$os-$arch.tar.gz" -C "package/$os-$arch/bin" "$name" LICENSE
done
zig build -j1 -Doptimize=ReleaseSmall -Dname="$name" -Dversion="$version" -Dtarget=x86_64-windows-gnu --prefix package/windows-x86_64
cp LICENSE package/windows-x86_64/bin/LICENSE
(cd package/windows-x86_64/bin && zip -q "../../../dist/$name-windows-x86_64.zip" "$name.exe" LICENSE)
(cd dist && if command -v sha256sum >/dev/null 2>&1; then sha256sum "$name"-*.tar.gz "$name"-*.zip; else shasum -a 256 "$name"-*.tar.gz "$name"-*.zip; fi) > dist/SHA256SUMS
