#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Chris <goabonga@pm.me>

# List the .deb files Launchpad built for uploaded source packages.
#
# Usage (through the environment, set by publish.yml):
#   PPA       the PPA the sources were uploaded to, e.g. ppa:goabonga/poc
#   SOURCE    the source package name, e.g. poc-hello
#   VERSIONS  the full Debian versions uploaded, separated by spaces
#
# Uses the public Launchpad API, without credentials: the binaries published
# for each source are listed, then the files of each. Writes to $GITHUB_OUTPUT
#   debs=<JSON array of {series, arch, url, sha256}>
# one entry per series and architecture that has a .deb, and prints the same
# on stdout. A series that was not built (or failed) simply has no entry.
#
# Launchpad serves binaryFileUrls on its "devel" API only.

set -euo pipefail

# Launchpad's anonymous API sits behind a cache that answers the same request
# the same way for a long time, an empty answer included (X-Cache: HIT, a
# growing Age): a source created minutes ago read as missing, and a build
# that was over for 25 minutes as still building. It honours no-cache.
lp_curl() { curl -fsS -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$@"; }

: "${PPA:?PPA is required, e.g. ppa:goabonga/poc}"
: "${SOURCE:?SOURCE is required}"
read -ra versions <<<"${VERSIONS:-}"

case "$PPA" in
  ppa:*/*) ;;
  *) echo "PPA must look like ppa:<owner>/<name>, got '$PPA'" >&2; exit 2 ;;
esac
owner="${PPA#ppa:}"
name="${owner#*/}"
owner="${owner%%/*}"
archive="https://api.launchpad.net/devel/~${owner}/+archive/ubuntu/${name}"

debs='[]'
for version in "${versions[@]}"; do
  source_link=$(lp_curl -G "$archive" \
    --data-urlencode "ws.op=getPublishedSources" \
    --data-urlencode "source_name=$SOURCE" \
    --data-urlencode "exact_match=true" \
    --data-urlencode "version=$version" \
    | jq -r '.entries[0].self_link // empty')
  if [ -z "$source_link" ]; then
    echo "::warning::$SOURCE $version is not published, no package to list" >&2
    continue
  fi
  while read -r binary series arch; do
    [ -n "$binary" ] || continue
    files=$(lp_curl -G "$binary" \
      --data-urlencode "ws.op=binaryFileUrls" \
      --data-urlencode "include_meta=true")
    # Only the .deb: a build also publishes -dbgsym.ddeb files.
    found=$(jq -c --arg series "$series" --arg arch "$arch" \
      '[.[] | select(.url | endswith(".deb")) | {series: $series, arch: $arch, url: .url, sha256: .sha256}]' \
      <<<"$files")
    debs=$(jq -c -s 'add' <<<"$debs $found")
  done < <(lp_curl "$source_link?ws.op=getPublishedBinaries" \
    | jq -r '.entries[] | [.self_link, (.distro_arch_series_link | split("/")[-2]), (.distro_arch_series_link | split("/")[-1])] | @tsv')
done

echo "$debs" | jq .
[ -z "${GITHUB_OUTPUT:-}" ] || echo "debs=$debs" >> "$GITHUB_OUTPUT"
