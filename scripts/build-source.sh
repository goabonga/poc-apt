#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Chris <goabonga@pm.me>

# Assemble and build the Debian source package for one poc-app component.
#
# Usage:
#   scripts/build-source.sh <component> <version> [-S|-b]
#
# <component> is "greeter" or "pinger"; <version> is the upstream version
# that was tagged "<component>-v<version>" on poc-app (its release workflow
# creates that tag). -S builds a source-only package (for `dput` to a
# Launchpad PPA, the default); -b builds a binary .deb too, for local
# testing or a GitHub Release attachment.
#
# Launchpad's builders have no network access, so everything the build
# needs - including third-party Go modules - has to already be inside the
# orig tarball. `go mod vendor` runs here, where there IS network, not in
# debian/rules, which only ever runs -mod=vendor.

set -euo pipefail

COMPONENT="${1:?usage: build-source.sh <component> <version> [-S|-b]}"
VERSION="${2:?usage: build-source.sh <component> <version> [-S|-b]}"
MODE="${3:--S}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="poc-$COMPONENT"
TAG="$COMPONENT-v$VERSION"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "fetching poc-app@$TAG"
curl -fsSL -o "$WORK/src.tar.gz" \
  "https://github.com/goabonga/poc-app/archive/refs/tags/$TAG.tar.gz"

mkdir -p "$WORK/extracted"
tar -xzf "$WORK/src.tar.gz" -C "$WORK/extracted" --strip-components=1

echo "vendoring Go modules"
( cd "$WORK/extracted" && go mod vendor )

# Debian naming: <source>_<upstream-version>.orig.tar.gz, vendored so the
# builder never has to touch the network.
tar -czf "$WORK/${PKG}_${VERSION}.orig.tar.gz" -C "$WORK/extracted" .

SRC_DIR="$WORK/${PKG}-${VERSION}"
mkdir -p "$SRC_DIR"
tar -xzf "$WORK/${PKG}_${VERSION}.orig.tar.gz" -C "$SRC_DIR"
cp -r "$ROOT/packages/$COMPONENT/debian" "$SRC_DIR/debian"

( cd "$SRC_DIR" && dpkg-buildpackage "$MODE" -us -uc )

install -d "$ROOT/dist"
find "$WORK" -maxdepth 1 -name "${PKG}_${VERSION}*" -exec cp {} "$ROOT/dist/" \;
echo "built: $(ls "$ROOT/dist" | wc -l) file(s) in $ROOT/dist"
