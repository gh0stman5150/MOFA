"""Return success only when generated content changed beyond run timestamps."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[2]
README_TIMESTAMP = re.compile(
    rb"(Last Updated:\s*<code[^>]*>).*?(</code>)",
    flags=re.IGNORECASE,
)


def from_head(path: Path) -> bytes | None:
    relative = path.relative_to(ROOT).as_posix()
    result = subprocess.run(
        ["git", "show", f"HEAD:{relative}"],
        cwd=ROOT,
        capture_output=True,
        check=False,
    )
    return result.stdout if result.returncode == 0 else None


def canonical_data(value: Any) -> bytes:
    if isinstance(value, dict):
        value = dict(value)
        value.pop("last_updated", None)
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
        direct_timestamp = root.find("last_updated")
        if direct_timestamp is not None:
            root.remove(direct_timestamp)
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


def main() -> int:
    for path in changed_paths():
        old = from_head(path)
        if old is None or not path.exists():
            return 0
        if normalize(path, old) != normalize(path, path.read_bytes()):
            return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
