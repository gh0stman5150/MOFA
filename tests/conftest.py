from __future__ import annotations

import sys
from pathlib import Path

ACTIONS_DIR = Path(__file__).resolve().parents[1] / ".github" / "actions"
sys.path.insert(0, str(ACTIONS_DIR))
