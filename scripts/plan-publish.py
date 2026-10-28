#!/usr/bin/env python3

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Chris <goabonga@pm.me>

"""Process the payload poc-app dispatched to publish.yml.

Reads, from the environment:

    COMPONENT         the poc-app component, a directory of packages/
    VERSION           its upstream version
    SERIES, ARCHS     the Ubuntu series and the architectures asked for, words
                      separated by spaces or commas; empty means the defaults
    DEFAULT_SERIES, DEFAULT_ARCHS
    PPA               the Launchpad PPA, e.g. ppa:goabonga/poc
    GPG_PRIVATE_KEY, GPG_PASSPHRASE

and checks all of it before anything is built: a typo in a series would
otherwise only show as a rejection email, minutes after the upload. Writes to
$GITHUB_OUTPUT

    series       the series, as a JSON array for the upload matrix
    archs        the architectures, separated by spaces
    revision     the Debian revision of this run, shared by every job
    ppa_upload   "true" when the source can be signed and sent to the PPA

and a recap to $GITHUB_STEP_SUMMARY. Exits 1 on an invalid payload.
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

LAUNCHPAD = "https://api.launchpad.net/1.0"
# What a Launchpad PPA can be asked to build.
KNOWN_ARCHS = {"amd64", "arm64", "armhf", "i386", "ppc64el", "riscv64", "s390x"}
SERIES = re.compile(r"[a-z]+")
VERSION = re.compile(r"[0-9][0-9A-Za-z.+~-]*")


def words(text: str) -> list[str]:
    """The words of a space or comma separated list, once each, in order."""
    return list(dict.fromkeys(word for word in re.split(r"[\s,]+", text) if word))


def series_problem(series: str) -> str | None:
    """Why Launchpad would not take uploads for ``series``, or None."""
    if not SERIES.fullmatch(series):
        return f"'{series}' is not a series name"
    try:
        with urllib.request.urlopen(f"{LAUNCHPAD}/ubuntu/{series}", timeout=30) as response:
            details = json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return f"'{series}' is not an Ubuntu series"
        print(f"::warning::could not check '{series}' with Launchpad: {error}")
        return None
    except (urllib.error.URLError, OSError, ValueError) as error:
        print(f"::warning::could not check '{series}' with Launchpad: {error}")
        return None
    if not details.get("active"):
        return f"'{series}' is no longer an active series"
    return None


def plan(env: dict[str, str], packages: Path) -> tuple[dict[str, str], list[str]]:
    """The outputs and the problems of a payload."""
    problems: list[str] = []
    component = env.get("COMPONENT", "")
    if not (packages / component / "debian").is_dir():
        problems.append(f"'{component}' is not a package of this repository")
    if not VERSION.fullmatch(env.get("VERSION", "")):
        problems.append(f"'{env.get('VERSION', '')}' is not a version")
    series = words(env.get("SERIES", "")) or words(env.get("DEFAULT_SERIES", ""))
    archs = words(env.get("ARCHS", "")) or words(env.get("DEFAULT_ARCHS", ""))
    if not series:
        problems.append("no series to publish for")
    problems += [problem for name in series if (problem := series_problem(name))]
    if not archs:
        problems.append("no architecture to build for")
    problems += [f"'{arch}' is not an architecture Launchpad builds" for arch in archs if arch not in KNOWN_ARCHS]
    uploadable = all(env.get(name) for name in ("PPA", "GPG_PRIVATE_KEY", "GPG_PASSPHRASE"))
    if not uploadable:
        print("::warning::GPG secrets or the PPA are unset; built locally only, not uploaded to the PPA")
    outputs = {
        "series": json.dumps(series),
        "archs": " ".join(archs),
        # Launchpad rejects re-uploading a version it already has, so every run
        # of the workflow gets a revision of its own.
        "revision": f"1+test{int(time.time())}",
        "ppa_upload": "true" if uploadable else "false",
    }
    return outputs, problems


def main() -> int:
    outputs, problems = plan(dict(os.environ), Path("packages"))
    for problem in problems:
        print(f"::error::{problem}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with Path(summary).open("a") as stream:
            stream.write(f"## Publish plan: {'invalid' if problems else 'ok'}\n\n")
            stream.write("| | |\n| --- | --- |\n")
            stream.write(f"| Package | `poc-{os.environ.get('COMPONENT', '')}` {os.environ.get('VERSION', '')} |\n")
            stream.write(f"| Series | {', '.join(json.loads(outputs['series'])) or 'none'} |\n")
            stream.write(f"| Architectures | {outputs['archs'] or 'none'} |\n")
            stream.write(f"| Debian revision | `{outputs['revision']}` |\n")
            stream.write(f"| PPA upload | {outputs['ppa_upload']} |\n")
            for problem in problems:
                stream.write(f"| Problem | {problem} |\n")
    if problems:
        return 1
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with Path(output).open("a") as stream:
            for key, value in outputs.items():
                stream.write(f"{key}={value}\n")
    else:
        print(json.dumps(outputs, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
