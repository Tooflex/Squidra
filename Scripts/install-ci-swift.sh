#!/usr/bin/env bash
# Install the exact official toolchain on disposable GitHub-hosted runners.
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
  echo 'This installer is restricted to GitHub Actions runners.' >&2
  exit 2
fi
swift_version=6.4.2
install_dir="${RUNNER_TEMP:?}/squidra-swift-${swift_version}"
mkdir -p "$install_dir"
case "$(uname -s)" in
  Linux)
    [[ "$(uname -m)" == x86_64 ]]
    archive="swift-${swift_version}-RELEASE-ubuntu24.04"
    url="https://download.swift.org/swift-${swift_version}-release/ubuntu2404/swift-${swift_version}-RELEASE/${archive}.tar.gz"
    curl --fail --location --retry 3 "$url" --output "$install_dir/swift.tar.gz"
    curl --fail --location --retry 3 "$url.sig" --output "$install_dir/swift.tar.gz.sig"
    curl --fail --location --compressed --retry 3 https://www.swift.org/keys/all-keys.asc --output "$install_dir/swift-keys.asc"
    mkdir -m 700 "$install_dir/gnupg"
    gpg --homedir "$install_dir/gnupg" --batch --import "$install_dir/swift-keys.asc"
    gpg --homedir "$install_dir/gnupg" --batch --verify "$install_dir/swift.tar.gz.sig" "$install_dir/swift.tar.gz"
    tar -xzf "$install_dir/swift.tar.gz" -C "$install_dir"
    swift_bin="$install_dir/$archive/usr/bin"
    ;;
  Darwin)
    url="https://download.swift.org/swift-${swift_version}-release/xcode/swift-${swift_version}-RELEASE/swift-${swift_version}-RELEASE-osx.pkg"
    curl --fail --location --retry 3 "$url" --output "$install_dir/swift.pkg"
    pkgutil --check-signature "$install_dir/swift.pkg"
    sudo installer -pkg "$install_dir/swift.pkg" -target /
    swift_bin="/Library/Developer/Toolchains/swift-${swift_version}-RELEASE.xctoolchain/usr/bin"
    ;;
  *) echo 'Unsupported CI installer platform' >&2; exit 2 ;;
esac
"$swift_bin/swift" --version | tee "$install_dir/version.txt"
grep -Eq 'Swift version 6\.4\.2([[:space:]]|$)' "$install_dir/version.txt"
echo "$swift_bin" >> "${GITHUB_PATH:?}"
