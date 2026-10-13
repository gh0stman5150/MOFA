"""Report whether generated content changed beyond run timestamps.

Compares the working-tree README.md and latest_raw_files/ against HEAD after
the generators ran. Exit codes, which the update workflow branches on:

  0  substantive change: at least one file differs beyond generated timestamps
  1  timestamps only: every changed file differs only in generated timestamps
  2  error: the comparison failed (git failure, unreadable or unparsable
     generated file); the workflow fails instead of discarding the data

A HEAD version that cannot be parsed counts as substantive, so a generator
that repairs a broken committed file is proposed for review.
"""

from __future__ import annotations

import json
import logging
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[2]
EXIT_SUBSTANTIVE = 0
EXIT_TIMESTAMPS_ONLY = 1
EXIT_ERROR = 2
# Keys and XML elements that only record when a generator ran. The history
# generators stamp last_scan_date on every hourly run.
GENERATED_TIMESTAMP_KEYS = {"last_updated", "lastUpdated", "last_scan_date"}
README_TIMESTAMP = re.compile(
    rb"(Last Updated:\s*<code[^>]*>).*?(</code>)",
    flags=re.IGNORECASE,
)

logger = logging.getLogger(__name__)


def from_head(path: Path) -> bytes | None:
    relative = path.relative_to(ROOT).as_posix()
    result = subprocess.run(
        ["git", "show", f"HEAD:{relative}"],
        cwd=ROOT,
        capture_output=True,
        check=False,
    )
    return result.stdout if result.returncode == 0 else None


def strip_generated_timestamps(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: strip_generated_timestamps(item)
            for key, item in value.items()
            if key not in GENERATED_TIMESTAMP_KEYS
        }
    if isinstance(value, list):
        return [strip_generated_timestamps(item) for item in value]
    return value


def canonical_data(value: Any) -> bytes:
    value = strip_generated_timestamps(value)
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def normalize(path: Path, content: bytes) -> bytes:
    suffix = path.suffix.lower()
    if path.name == "README.md":
        return README_TIMESTAMP.sub(rb"\1<TIMESTAMP>\2", content)
    if suffix == ".json":
        return canonical_data(json.loads(content))
    if suffix in {".yaml", ".yml"}:
        return canonical_data(yaml.safe_load(content))
    if suffix == ".xml":
        root = ET.fromstring(content)
        for parent in root.iter():
            for child in list(parent):
                if child.tag in GENERATED_TIMESTAMP_KEYS:
                    parent.remove(child)
        return ET.tostring(root, encoding="utf-8")
    return content


def changed_paths() -> list[Path]:
    result = subprocess.run(
        ["git", "diff", "--name-only", "--", "README.md", "latest_raw_files"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    )
    return [ROOT / line for line in result.stdout.splitlines() if line]


def is_substantive(path: Path) -> bool:
    """Compare one changed file with HEAD; errors on the new version propagate."""
    old = from_head(path)
    if old is None or not path.exists():
        return True
    new = normalize(path, path.read_bytes())
    try:
        old = normalize(path, old)
    except Exception as exc:  # malformed committed content
        logger.warning(
            "HEAD version of %s cannot be parsed (%s); treating as substantive",
            path.relative_to(ROOT).as_posix(),
            exc,
        )
        return True
    return old != new


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        for path in changed_paths():
            if is_substantive(path):
                logger.info("Substantive change: %s", path.relative_to(ROOT).as_posix())
                return EXIT_SUBSTANTIVE
    except Exception:  # every failure, so it never reads as exit 1
        logger.exception("Could not compare generated files with HEAD")
        return EXIT_ERROR
    logger.info("Only generated timestamps changed")
    return EXIT_TIMESTAMPS_ONLY


if __name__ == "__main__":
    raise SystemExit(main())
