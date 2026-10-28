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
# A step's job summary is uploaded when the step ends and cannot be edited
# afterwards, so to show progress the wait is cut in slices, one step each:
#   SLICE       seconds to follow the builds for in this step before writing a
#               snapshot of them to the summary and returning (0: until they
#               are all over)
#   STATE_FILE  where the steps pass what they know to the next one (the time
#               the wait started, and once the builds are over, the outcome);
#               a step that finds the outcome there does nothing
# The state is "pending" after a slice that did not see the end. Never fails on a failed build: it writes
#   state=success|failure|timeout
#   build_url=<Launchpad build page>
#   log_url=<build log>
# to $GITHUB_OUTPUT and a table to $GITHUB_STEP_SUMMARY, and the workflow
# decides what to do with them.

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
SLICE="${SLICE:-0}"
STATE_FILE="${STATE_FILE:-}"
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

# What an earlier slice settled or started: nothing to do once the builds are
# over, and the wait keeps its own clock across the slices.
if [ -n "$STATE_FILE" ] && grep -qx 'done=true' "$STATE_FILE" 2>/dev/null; then
  echo "the builds are over already: $(grep '^state=' "$STATE_FILE")"
  exit 0
fi
started=$(date +%s)
if [ -n "$STATE_FILE" ] && grep -q '^started=' "$STATE_FILE" 2>/dev/null; then
  started=$(grep '^started=' "$STATE_FILE" | cut -d= -f2)
fi
slice_end=$(($(date +%s) + SLICE))
deadline=$((started + LIMIT))
sliced=0
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
  if [ "$SLICE" -gt 0 ] && [ "$(date +%s)" -ge "$slice_end" ]; then
    sliced=1
    break
  fi
  sleep "$INTERVAL"
done

count=$(jq length <<<"$builds")
pending=$(jq --argjson final "$FINAL" '[.[] | select(.buildstate | IN($final[]) | not)] | length' <<<"$builds")
failed=$(jq '[.[] | select(.buildstate != "Successfully built")] | length' <<<"$builds")
if [ "$ready" -ne 1 ] || [ "$pending" -gt 0 ] || { [ "$count" -eq 0 ] && [ "${#rejected[@]}" -eq 0 ]; }; then
  # Not over: another slice follows, or the time is up.
  if [ "$sliced" -eq 1 ]; then state=pending; else state=timeout; fi
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
if [ -n "$STATE_FILE" ]; then
  {
    echo "started=$started"
    echo "state=$state"
    echo "build_url=$build_url"
    echo "log_url=$log_url"
    [ "$state" = pending ] && echo "done=false" || echo "done=true"
  } > "$STATE_FILE"
fi

echo "$SOURCE ${versions[*]}: $state"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  listed=""
  for version in "${versions[@]}"; do listed+="\`$version\` "; done
  missing=""
  for version in "${rejected[@]}"; do missing+="\`$version\` "; done
  # What the builds are doing, for a snapshot: "3 Currently building".
  progress=$(jq -r 'group_by(.buildstate) | map("\(length) \(.[0].buildstate)") | join(", ")' <<<"$builds")
  {
    if [ "$state" = pending ]; then
      echo "## Launchpad builds: in progress ($(date -u +%H:%M) UTC)"
    else
      echo "## Launchpad build: $state"
    fi
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
