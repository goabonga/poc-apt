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
# poc-app is a private repo. The plain codeload.github.com/.../archive/
# URL 404s even with a correctly-scoped Authorization header when the
# token is a fine-grained PAT - confirmed for real against the user's own
# PAT (Contents: Read and write on poc-app, verified in the GitHub UI).
# The official REST API tarball endpoint works instead: it 302s to a
# pre-signed, time-limited codeload URL (a `?token=` query string, not a
# header), so the redirect needs no Authorization forwarding at all -
# also confirmed for real. GH_TOKEN needs Contents:read on poc-app; the
# caller passes CROSS_REPO_TOKEN for that.
auth=()
[ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GH_TOKEN")
curl -fsSL -L "${auth[@]}" -H "Accept: application/vnd.github+json" \
  -o "$WORK/src.tar.gz" \
  "https://api.github.com/repos/goabonga/poc-app/tarball/$TAG"

mkdir -p "$WORK/extracted"
tar -xzf "$WORK/src.tar.gz" -C "$WORK/extracted" --strip-components=1

echo "vendoring Go modules"
( cd "$WORK/extracted" && go mod vendor )

# Debian naming: <source>_<upstream-version>.orig.tar.gz, vendored so the
# builder never has to touch the network.
tar -czf "$WORK/${PKG}_${VERSION}.orig.tar.gz" -C "$WORK/extracted" .

DEB_CHANGELOG="$ROOT/packages/$COMPONENT/debian/changelog"
CURRENT_VERSION=$(dpkg-parsechangelog -l "$DEB_CHANGELOG" -S Version)
if [ "$CURRENT_VERSION" = "$VERSION-1" ]; then
  echo "debian/changelog already at $VERSION-1, leaving it as-is"
else
  echo "updating debian/changelog from poc-app's cmd/$COMPONENT/CHANGELOG.md"
  # Pull this release's actual notes out of multicz's own per-component
  # CHANGELOG.md (Keep a Changelog headings) rather than inventing text -
  # the Debian changelog should say what the upstream changelog says.
  mapfile -t notes < <(awk -v ver="$VERSION" '
    $0 ~ "^## \\[" ver "\\]" { capture=1; next }
    capture && /^## \[/        { exit }
    capture && /^- /           { sub(/^- /, ""); print }
  ' "$WORK/extracted/cmd/$COMPONENT/CHANGELOG.md")
  if [ "${#notes[@]}" -eq 0 ]; then
    notes=("New upstream release: poc-app $TAG.")
  fi

  # "noble" (24.04 LTS), not Debian's "unstable": Launchpad PPAs only
  # recognize real Ubuntu series names and silently reject (rejection
  # email, no build ever appears) anything else - confirmed for real, a
  # run that uploaded fine over FTP never produced a build because this
  # said "unstable". One series only for now; a PPA that needs to serve
  # several at once reheaders a per-series copy before each build instead
  # (see obd-tui's reheader_changelog.py for that pattern).
  export DEBEMAIL="goabonga@pm.me" DEBFULLNAME="Chris"
  dch --newversion "$VERSION-1" --distribution noble \
    --changelog "$DEB_CHANGELOG" "${notes[0]}"
  for note in "${notes[@]:1}"; do
    dch --append --changelog "$DEB_CHANGELOG" "$note"
  done
fi

SRC_DIR="$WORK/${PKG}-${VERSION}"
mkdir -p "$SRC_DIR"
tar -xzf "$WORK/${PKG}_${VERSION}.orig.tar.gz" -C "$SRC_DIR"
cp -r "$ROOT/packages/$COMPONENT/debian" "$SRC_DIR/debian"

( cd "$SRC_DIR" && dpkg-buildpackage "$MODE" -us -uc )

install -d "$ROOT/dist"
find "$WORK" -maxdepth 1 -name "${PKG}_${VERSION}*" -exec cp {} "$ROOT/dist/" \;
echo "built: $(ls "$ROOT/dist" | wc -l) file(s) in $ROOT/dist"
