"""Run every generator in dependency order and fail on logged errors."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GENERATORS = (
    "generate_macos_standalone_latest.py",
    "generate_macos_standalone_update_history.py",
    "generate_macos_standalone_cve_history.py",
    "generate_macos_appstore_latest.py",
    "generate_ios_appstore_latest.py",
    "generate_onedrive_all.py",
    "generate_macos_standalone_preview.py",
    "generate_macos_standalone_beta.py",
    "generate_edge_all.py",
    "generate_macos_standalone_rss.py",
    "update_readme.py",
)
ERROR_PATTERN = re.compile(
    r"(?mi)^Traceback\b|^Error\b|^Critical\b| - (?:ERROR|CRITICAL) - "
)


def main() -> int:
    actions_dir = ROOT / ".github" / "actions"
    for generator in GENERATORS:
        print(f"::group::{generator}", flush=True)
        result = subprocess.run(
            [sys.executable, str(actions_dir / generator)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        if result.stdout:
            print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
        print("::endgroup::", flush=True)
        combined = result.stdout + "\n" + result.stderr
        if result.returncode != 0 or ERROR_PATTERN.search(combined):
            print(f"Generator failed or logged an error: {generator}", file=sys.stderr)
            return result.returncode or 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
