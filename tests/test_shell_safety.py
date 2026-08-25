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


def test_active_community_scripts_do_not_assign_reserved_zsh_status():
    reserved_status = re.compile(
        r"^\s*(?:local|typeset)\b[^#]*\bstatus(?:\s*=|\s|$)|^\s*status\s*="
    )
    offenders: list[str] = []
    for path in COMMUNITY_SCRIPTS.glob("*.zsh"):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if reserved_status.search(line) and not line.lstrip().startswith("#"):
                offenders.append(f"{path.name}:{number}")
    assert not offenders, f"reserved zsh status assignment(s): {', '.join(offenders)}"


def test_active_community_scripts_quote_variable_removal_targets():
    unsafe_removal = re.compile(r"(?:^|\s)(?:/bin/)?rm\s+-[Rrf]+\s+\$\{?[A-Za-z_]")
    offenders: list[str] = []
    for path in COMMUNITY_SCRIPTS.glob("*.zsh"):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if unsafe_removal.search(line) and not line.lstrip().startswith("#"):
                offenders.append(f"{path.name}:{number}")
    assert not offenders, f"unquoted variable removal target(s): {', '.join(offenders)}"


def test_repair_failures_do_not_report_success_to_jamf():
    failure_messages = (
        "Package download failed",
        "Downloaded package is malformed",
        "Downloaded package is not signed",
        "Package installation failed",
    )
    offenders: list[str] = []
    for path in COMMUNITY_SCRIPTS.glob("*.zsh"):
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if any(message in line for message in failure_messages):
                if any("exit 0" in candidate for candidate in lines[index + 1 : index + 5]):
                    offenders.append(f"{path.name}:{index + 1}")
    assert not offenders, f"repair failure reports success: {', '.join(offenders)}"


def test_teams_reset_has_one_allowlisted_rm_implementation():
    path = COMMUNITY_SCRIPTS / "MOFA_Community_Microsoft_Teams_Reset.zsh"
    rm_lines = [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if re.search(r"(^|\s)(/bin/)?rm\s", line) and not line.lstrip().startswith("#")
    ]
    assert rm_lines == ['if ! /bin/rm -rf -- "$target"; then']
