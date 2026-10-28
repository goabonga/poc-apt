#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Chris <goabonga@pm.me>

# Download the orig tarball a PPA already has for an upstream version.
#
# Usage (through the environment, set by publish.yml):
#   PPA      the PPA, e.g. ppa:goabonga/poc
#   SOURCE   the source package name, e.g. poc-pinger
#   VERSION  the upstream version, e.g. 0.4.0
#   OUT      the directory to download it to
#
# A source upload whose orig tarball has the name of one already in the
# archive but other bytes is rejected by Launchpad (by email: the upload
# itself looks fine). Two builds of the same tree are not byte-identical, so a
# rerun for a version that was uploaded before has to reuse the tarball the
# PPA holds. Writes
#   path=<the downloaded file>
# to $GITHUB_OUTPUT, and nothing when the PPA has no source of that version
# yet, which is the normal case of a first upload. Uses the public Launchpad
# API (devel: sourceFileUrls is not in the stable one), without credentials.

set -euo pipefail

: "${PPA:?PPA is required, e.g. ppa:goabonga/poc}"
: "${SOURCE:?SOURCE is required}"
: "${VERSION:?VERSION is required}"
: "${OUT:?OUT is required}"

case "$PPA" in
  ppa:*/*) ;;
  *) echo "PPA must look like ppa:<owner>/<name>, got '$PPA'" >&2; exit 2 ;;
esac
owner="${PPA#ppa:}"
name="${owner#*/}"
owner="${owner%%/*}"
archive="https://api.launchpad.net/devel/~${owner}/+archive/ubuntu/${name}"

# Any published source of that upstream version carries the orig tarball
# ("<version>-<revision>"), whatever its series.
source_link=$(curl -fsS -G "$archive" \
  --data-urlencode "ws.op=getPublishedSources" \
  --data-urlencode "source_name=$SOURCE" \
  --data-urlencode "exact_match=true" \
  | jq -r --arg prefix "${VERSION}-" \
    '[.entries[] | select(.source_package_version | startswith($prefix))][0].self_link // empty')
if [ -z "$source_link" ]; then
  echo "the PPA has no $SOURCE $VERSION yet: the orig tarball will be built"
  exit 0
fi

url=$(curl -fsS -G "$source_link" --data-urlencode "ws.op=sourceFileUrls" \
  | jq -r --arg orig "${SOURCE}_${VERSION}.orig.tar.gz" '.[] | select(endswith($orig))' | head -1)
if [ -z "$url" ]; then
  echo "::warning::$SOURCE $VERSION is in the PPA without an orig tarball to reuse" >&2
  exit 0
fi

mkdir -p "$OUT"
curl -fsSL -o "$OUT/${SOURCE}_${VERSION}.orig.tar.gz" "$url"
echo "reusing the orig tarball of the PPA: $url"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "path=$OUT/${SOURCE}_${VERSION}.orig.tar.gz" >> "$GITHUB_OUTPUT"
