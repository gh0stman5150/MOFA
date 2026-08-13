from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMMUNITY_SCRIPTS = ROOT / "office_reset_tools" / "mofa_community_maintained" / "scripts"


def test_active_community_scripts_do_not_evaluate_arguments():
    offenders: list[str] = []
    for path in COMMUNITY_SCRIPTS.glob("*.zsh"):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if re.search(r"(^|\s)eval\s", line) and not line.lstrip().startswith("#"):
                offenders.append(f"{path.name}:{number}")
    assert not offenders, f"unsafe eval invocation(s): {', '.join(offenders)}"


def test_teams_reset_has_one_allowlisted_rm_implementation():
    path = COMMUNITY_SCRIPTS / "MOFA_Community_Microsoft_Teams_Reset.zsh"
    rm_lines = [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if re.search(r"(^|\s)(/bin/)?rm\s", line) and not line.lstrip().startswith("#")
    ]
    assert rm_lines == ['if ! /bin/rm -rf -- "$target"; then']
