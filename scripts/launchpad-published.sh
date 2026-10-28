#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Chris <goabonga@pm.me>

# Wait until the binaries Launchpad built for an uploaded source are published.
#
# A build that succeeded is not installable yet: its binaries are published to
# the archive a few minutes later, and only then does `apt install` find them.
#
# Usage (through the environment, set by publish.yml):
#   PPA      the PPA, e.g. ppa:goabonga/poc
#   SOURCE   the source package name, e.g. poc-hello
#   VERSION  the full Debian version uploaded, e.g. 0.3.0-1+t1~noble1
#
# Uses the public Launchpad API (devel: the stable one lists no binary),
# without credentials. Writes
#   published=true|false
# to $GITHUB_OUTPUT: true once every binary of the source is Published, false
# when LIMIT seconds (45 minutes by default) went by first, or when the source
# has no binary. A binary a newer version superseded counts as published.

set -euo pipefail

: "${PPA:?PPA is required, e.g. ppa:goabonga/poc}"
: "${SOURCE:?SOURCE is required}"
: "${VERSION:?VERSION is required}"
INTERVAL="${INTERVAL:-30}"
LIMIT="${LIMIT:-2700}"

case "$PPA" in
  ppa:*/*) ;;
  *) echo "PPA must look like ppa:<owner>/<name>, got '$PPA'" >&2; exit 2 ;;
esac
owner="${PPA#ppa:}"
name="${owner#*/}"
owner="${owner%%/*}"
archive="https://api.launchpad.net/devel/~${owner}/+archive/ubuntu/${name}"

output() { [ -z "${GITHUB_OUTPUT:-}" ] || echo "$1=$2" >> "$GITHUB_OUTPUT"; }

deadline=$(($(date +%s) + LIMIT))
published=false
while [ "$(date +%s)" -lt "$deadline" ]; do
  source_link=$(curl -fsS -G "$archive" \
    --data-urlencode "ws.op=getPublishedSources" \
    --data-urlencode "source_name=$SOURCE" \
    --data-urlencode "exact_match=true" \
    --data-urlencode "version=$VERSION" \
    | jq -r '.entries[0].self_link // empty')
  if [ -n "$source_link" ]; then
    statuses=$(curl -fsS "$source_link?ws.op=getPublishedBinaries" | jq -r '[.entries[].status] | sort | join(" ")')
    echo "binaries: ${statuses:-none yet}"
    # A Superseded or Obsolete binary was published and a newer version
    # replaced it: it is not waited for.
    waiting=$(jq -n --arg statuses "$statuses" \
      '$statuses | split(" ") | map(select(. != "" and . != "Published" and . != "Superseded" and . != "Obsolete")) | length')
    total=$(jq -n --arg statuses "$statuses" '$statuses | split(" ") | map(select(. != "")) | length')
    if [ "$total" -gt 0 ] && [ "$waiting" -eq 0 ]; then
      published=true
      break
    fi
  else
    echo "waiting for $SOURCE $VERSION to be published"
  fi
  sleep "$INTERVAL"
done

echo "$SOURCE $VERSION published: $published"
output published "$published"
