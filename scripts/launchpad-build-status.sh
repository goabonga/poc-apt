#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Chris <goabonga@pm.me>

# Wait for the Launchpad builds of the uploaded source packages and report how
# they ended.
#
# Usage (through the environment, set by publish.yml):
#   PPA       the PPA the sources were uploaded to, e.g. ppa:goabonga/poc
#   SOURCE    the source package name, e.g. poc-hello
#   VERSIONS  the full Debian versions uploaded, one per series, separated by
#             spaces, e.g. "0.3.0-1+t1~noble1 0.3.0-1+t1~jammy1"
#             (VERSION, a single one, is accepted too)
#
# Uses the public Launchpad API, so it needs no credentials: each published
# source is looked up first (an upload takes a few minutes to be accepted and
# published), then the builds of all of them - one per series and
# architecture - are polled until every one reached a final state.
#
# Besides the state, it writes the builds themselves, one entry per series and
# architecture, as {arch, state, url, log_url}, to
#   builds=<JSON array>
# so that what failed, and where its log is, can be reported.

set -euo pipefail

: "${PPA:?PPA is required, e.g. ppa:goabonga/poc}"
: "${SOURCE:?SOURCE is required}"
read -ra versions <<<"${VERSIONS:-${VERSION:-}}"
if [ "${#versions[@]}" -eq 0 ]; then
  echo "VERSIONS (or VERSION) is required" >&2
  exit 2
fi
INTERVAL="${INTERVAL:-30}"
LIMIT="${LIMIT:-5400}"
# An upload takes a few minutes to be accepted and published. One that is not
# after this long was most likely rejected, which Launchpad only tells by
# email: it is reported as such and no longer waited for.
PUBLISH_LIMIT="${PUBLISH_LIMIT:-900}"

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

started=$(date +%s)
deadline=$((started + LIMIT))
declare -A links=()
rejected=()
builds='[]'
ready=0

while [ "$(date +%s)" -lt "$deadline" ]; do
  builds='[]'
  ready=1
  for version in "${versions[@]}"; do
    if [ -z "${links[$version]:-}" ]; then
      # The version holds a "+" and a "~", so it has to be URL-encoded.
      links[$version]=$(curl -fsS -G "$archive" \
        --data-urlencode "ws.op=getPublishedSources" \
        --data-urlencode "source_name=$SOURCE" \
        --data-urlencode "exact_match=true" \
        --data-urlencode "version=$version" \
        | jq -r '.entries[0].self_link // empty')
    fi
    if [ -z "${links[$version]}" ]; then
      if [ $(($(date +%s) - started)) -ge "$PUBLISH_LIMIT" ]; then
        case " ${rejected[*]:-} " in
          *" $version "*) ;;
          *) echo "::warning::$SOURCE $version was not published after $((PUBLISH_LIMIT / 60)) minutes, the upload was probably rejected"
             rejected+=("$version") ;;
        esac
      else
        echo "waiting for $SOURCE $version to be published"
        ready=0
      fi
      continue
    fi
    found=$(curl -fsS "${links[$version]}?ws.op=getBuilds" | jq -c '.entries')
    [ "$(jq length <<<"$found")" -gt 0 ] || ready=0
    builds=$(jq -c -s 'add' <<<"$builds $found")
  done
  states=$(jq -r '.[].buildstate' <<<"$builds" | sort | uniq -c | tr '\n' ';')
  echo "builds: ${states:-none yet}"
  pending=$(jq --argjson final "$FINAL" '[.[] | select(.buildstate | IN($final[]) | not)] | length' <<<"$builds")
  if [ "$ready" -eq 1 ] && [ "$pending" -eq 0 ]; then
    break
  fi
  sleep "$INTERVAL"
done

count=$(jq length <<<"$builds")
pending=$(jq --argjson final "$FINAL" '[.[] | select(.buildstate | IN($final[]) | not)] | length' <<<"$builds")
failed=$(jq '[.[] | select(.buildstate != "Successfully built")] | length' <<<"$builds")
if [ "$ready" -ne 1 ] || [ "$pending" -gt 0 ] || { [ "$count" -eq 0 ] && [ "${#rejected[@]}" -eq 0 ]; }; then
  state=timeout
elif [ "$failed" -eq 0 ] && [ "${#rejected[@]}" -eq 0 ]; then
  state=success
else
  state=failure
fi

# The first build that did not succeed is the one worth linking; with only
# successes, the first build.
pick=$(jq -c 'map(select(.buildstate != "Successfully built"))[0] // .[0] // {}' <<<"$builds")
build_url=$(jq -r '.web_link // empty' <<<"$pick")
log_url=$(jq -r '.build_log_url // empty' <<<"$pick")
# Only rejected uploads: no build to point at, the PPA is the place to look.
if [ "$failed" -eq 0 ] && [ "${#rejected[@]}" -gt 0 ]; then
  build_url=""
  log_url=""
fi
[ -n "$build_url" ] || build_url="https://launchpad.net/~${owner}/+archive/ubuntu/${name}/+packages"

output state "$state"
output build_url "$build_url"
output log_url "$log_url"
output builds "$(jq -c 'map({arch: .arch_tag, state: .buildstate, url: .web_link, log_url: (.build_log_url // "")})' <<<"$builds")"

echo "$SOURCE ${versions[*]}: $state"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  listed=""
  for version in "${versions[@]}"; do listed+="\`$version\` "; done
  missing=""
  for version in "${rejected[@]}"; do missing+="\`$version\` "; done
  # What the builds are doing, for a snapshot: "3 Currently building".
  progress=$(jq -r 'group_by(.buildstate) | map("\(length) \(.[0].buildstate)") | join(", ")' <<<"$builds")
  {
    echo "## Launchpad build: $state"
    echo
    [ -z "$progress" ] || echo "Builds: $progress"
    [ -z "$progress" ] || echo
    echo "\`$SOURCE\` on \`$PPA\`: ${listed% }"
    echo
    if [ "${#rejected[@]}" -gt 0 ]; then
      echo "Not published by Launchpad, the upload was probably rejected (see the email it sent): ${missing% }"
      echo
    fi
    if [ "$count" -eq 0 ]; then
      echo "No build was published before the timeout."
    else
      echo "| Build | State | Log |"
      echo "| --- | --- | --- |"
      jq -r '.[] | "| [\(.title)](\(.web_link)) | \(.buildstate) | \(if .build_log_url then "[log](\(.build_log_url))" else "" end) |"' <<<"$builds"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
