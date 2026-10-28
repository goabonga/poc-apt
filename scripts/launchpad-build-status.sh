#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Chris <goabonga@pm.me>

# Wait for the Launchpad build of an uploaded source package and report how
# it ended.
#
# Usage (through the environment, set by publish.yml):
#   PPA      the PPA the source was uploaded to, e.g. ppa:goabonga/poc
#   SOURCE   the source package name, e.g. poc-hello
#   VERSION  the full Debian version, e.g. 0.3.0-1+test1793186573
#
# Uses the public Launchpad API, so it needs no credentials: the published
# source is looked up first (an upload takes a few minutes to be accepted and
# published), then its builds are polled until every one reached a final
# state. Never fails on a failed build: it writes
#   state=success|failure|timeout
#   build_url=<Launchpad build page>
#   log_url=<build log>
# to $GITHUB_OUTPUT and a table to $GITHUB_STEP_SUMMARY, and the workflow
# decides what to do with them.

set -euo pipefail

: "${PPA:?PPA is required, e.g. ppa:goabonga/poc}"
: "${SOURCE:?SOURCE is required}"
: "${VERSION:?VERSION is required}"
INTERVAL="${INTERVAL:-30}"
LIMIT="${LIMIT:-5400}"

case "$PPA" in
  ppa:*/*) ;;
  *) echo "PPA must look like ppa:<owner>/<name>, got '$PPA'" >&2; exit 2 ;;
esac
owner="${PPA#ppa:}"
name="${owner#*/}"
owner="${owner%%/*}"
archive="https://api.launchpad.net/1.0/~${owner}/+archive/ubuntu/${name}"

# A final state is one that will not change on its own. "Dependency wait" and
# every "needs/currently/uploading" state keep polling.
FINAL='["Successfully built","Failed to build","Failed to upload","Chroot problem","Cancelled build","Build for superseded Source"]'

output() { [ -z "${GITHUB_OUTPUT:-}" ] || echo "$1=$2" >> "$GITHUB_OUTPUT"; }

deadline=$((SECONDS + LIMIT))
source_link=""
builds='[]'

while [ "$SECONDS" -lt "$deadline" ]; do
  if [ -z "$source_link" ]; then
    # The version holds a "+", so it has to be URL-encoded.
    source_link=$(curl -fsS -G "$archive" \
      --data-urlencode "ws.op=getPublishedSources" \
      --data-urlencode "source_name=$SOURCE" \
      --data-urlencode "exact_match=true" \
      --data-urlencode "version=$VERSION" \
      | jq -r '.entries[0].self_link // empty')
    [ -n "$source_link" ] || echo "waiting for $SOURCE $VERSION to be published"
  fi
  if [ -n "$source_link" ]; then
    builds=$(curl -fsS "$source_link?ws.op=getBuilds" | jq -c '.entries')
    states=$(jq -r '.[].buildstate' <<<"$builds" | sort | uniq -c | tr '\n' ';')
    echo "builds: ${states:-none yet}"
    pending=$(jq --argjson final "$FINAL" '[.[] | select(.buildstate | IN($final[]) | not)] | length' <<<"$builds")
    if [ "$(jq length <<<"$builds")" -gt 0 ] && [ "$pending" -eq 0 ]; then
      break
    fi
  fi
  sleep "$INTERVAL"
done

count=$(jq length <<<"$builds")
pending=$(jq --argjson final "$FINAL" '[.[] | select(.buildstate | IN($final[]) | not)] | length' <<<"$builds")
failed=$(jq '[.[] | select(.buildstate != "Successfully built")] | length' <<<"$builds")
if [ "$count" -eq 0 ] || [ "$pending" -gt 0 ]; then
  state=timeout
elif [ "$failed" -eq 0 ]; then
  state=success
else
  state=failure
fi

# The first build that did not succeed is the one worth linking; with only
# successes, the first build.
pick=$(jq -c 'map(select(.buildstate != "Successfully built"))[0] // .[0] // {}' <<<"$builds")
build_url=$(jq -r '.web_link // empty' <<<"$pick")
log_url=$(jq -r '.build_log_url // empty' <<<"$pick")
[ -n "$build_url" ] || build_url="https://launchpad.net/~${owner}/+archive/ubuntu/${name}/+packages"

output state "$state"
output build_url "$build_url"
output log_url "$log_url"

echo "$SOURCE $VERSION: $state"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Launchpad build: $state"
    echo
    echo "\`$SOURCE\` \`$VERSION\` on \`$PPA\`"
    echo
    if [ "$count" -eq 0 ]; then
      echo "No build was published before the timeout."
    else
      echo "| Build | State | Log |"
      echo "| --- | --- | --- |"
      jq -r '.[] | "| [\(.title)](\(.web_link)) | \(.buildstate) | \(if .build_log_url then "[log](\(.build_log_url))" else "" end) |"' <<<"$builds"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
