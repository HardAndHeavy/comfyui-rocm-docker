#!/usr/bin/env python3
"""Resolve a published base image tag to its index digest and record it.

`versions.json` pins the base image by digest, not by tag: a tag can be moved
under the build. This script asks the registry what the tag currently points at
and writes the answer into `versions.json`, so the pin is produced by the
registry instead of being copied by hand from a command's output.

Both the versioned tag and `latest` are expected to point at the same manifest
list after `make publish` in the base repository; a mismatch almost always means
the base repository is halfway through a release, so it is reported and refused.

Usage:
    python3 tools/pin_base.py                # resolve versions.json's base tag
    python3 tools/pin_base.py --check        # fail if the pin is stale
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSIONS_FILE = ROOT / "versions.json"
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")


def load() -> dict:
    with VERSIONS_FILE.open(encoding="utf-8") as handle:
        return json.load(handle)


def resolve(reference: str) -> str:
    """Ask the registry for the digest behind a tag or digest reference."""
    result = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", "--format", "{{.Manifest.Digest}}", reference],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"Could not resolve {reference}:\n{result.stderr.strip()}\n"
            "Is the image published and are you logged in to the registry?"
        )
    digest = result.stdout.strip()
    if not DIGEST_RE.match(digest):
        raise SystemExit(f"Registry returned an unusable digest for {reference}: {digest!r}")
    return digest


def main(argv: list[str]) -> int:
    check_only = "--check" in argv[1:]

    data = load()
    image = data["image"]
    versioned = f'{image["base_image"]}:{image["base_version"]}'
    latest = f'{image["base_image"]}:latest'

    versioned_digest = resolve(versioned)
    latest_digest = resolve(latest)
    if versioned_digest != latest_digest:
        raise SystemExit(
            f"{versioned} and {latest} point at different manifests:\n"
            f"  {versioned}: {versioned_digest}\n"
            f"  {latest}: {latest_digest}\n"
            "The base repository is probably mid-release; finish publishing it first."
        )

    recorded = image["base_digest"]
    if recorded == versioned_digest:
        print(f"{versioned} is already pinned to {recorded}")
        return 0

    if check_only:
        print(
            f"stale pin for {versioned}:\n  recorded: {recorded}\n  registry: {versioned_digest}\n"
            "Run `make pin-base`, then `make versions`.",
            file=sys.stderr,
        )
        return 1

    image["base_digest"] = versioned_digest
    VERSIONS_FILE.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"pinned {versioned} to {versioned_digest}")
    print("Run `make versions` to propagate the digest into the Dockerfile and README.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
