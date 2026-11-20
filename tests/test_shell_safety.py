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


def test_teams_script_removes_only_through_allowlisted_rm_calls():
    path = COMMUNITY_SCRIPTS / "MOFA_Community_Microsoft_Teams_Removal_Reinstall.zsh"
    rm_lines = [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if re.search(r"(^|\s)(/bin/)?rm\s", line) and not line.lstrip().startswith("#")
    ]
    assert rm_lines == [
        '/bin/rm -rf -- "$TEMP_DIR" >/dev/null 2>&1 || true',
        '/bin/rm -rf -- "$BACKGROUND_BACKUP_DIR" >/dev/null 2>&1 || true',
    ]


def _code_lines(path: Path):
    """Yields (number, stripped line) for every line of a script that is not a comment."""
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            yield number, stripped


def test_active_community_scripts_remove_only_through_reviewed_calls():
    # A user can plant symbolic links in their own home and temp folder, so root removes those
    # paths only through removeTarget (Teams: remove_path), which deletes with zsh's zf_rm in
    # paranoid mode (-s): it refuses links above and below the target, even ones swapped in while
    # it runs. /bin/rm only deletes the scripts' own private work folders. Any new deletion must
    # be reviewed and added here.
    allowed_rm = {
        '/bin/rm -rf -- "$WORK_DIR"',
        '/bin/rm -rf -- "$TEMP_DIR" >/dev/null 2>&1 || true',
        '/bin/rm -rf -- "$BACKGROUND_BACKUP_DIR" >/dev/null 2>&1 || true',
    }
    allowed_zf_rm = {
        'if ! zmodload -F zsh/files b:zf_rm 2>/dev/null; then',
        'zf_output="$( ( zf_rm "${1//f/}s" -- "$physical_target" ) </dev/null 2>&1 )"',
        'zf_output="$( ( zf_rm -rs -- "$physical_target" ) </dev/null 2>&1 )"',
    }
    command_rm = re.compile(
        r"(?:^|[;&|(!]|\b(?:then|do|else|if|while|until|command|builtin|exec|sudo|xargs))\s*"
        r"(?:/bin/)?\"?rm\b"
    )
    other_deletion = re.compile(
        r"(?:^|[\s;&|(!\"'])(?:/bin/rmdir|rmdir|/usr/bin/unlink|unlink|srm|zf_rmdir)\b|\s-delete\b"
    )
    offenders: list[str] = []
    for path in COMMUNITY_SCRIPTS.glob("*.zsh"):
        for number, line in _code_lines(path):
            if ("/bin/rm" in line or command_rm.search(line)) and line not in allowed_rm:
                offenders.append(f"{path.name}:{number}: {line}")
            if "zf_rm" in line and line not in allowed_zf_rm:
                offenders.append(f"{path.name}:{number}: {line}")
            if other_deletion.search(line):
                offenders.append(f"{path.name}:{number}: {line}")
    assert not offenders, "unreviewed deletion(s):\n" + "\n".join(offenders)


def test_active_community_scripts_never_let_curl_read_a_config_file():
    # SetHomeFolder points HOME at the console user's home, and curl reads $HOME/.curlrc unless
    # -q (--disable) is its first argument. A .curlrc can make root write any file.
    call = re.compile(r"/usr/bin/curl(?:[ \t]|\\\n)+(?P<first>\S+)")
    bare_call = re.compile(r"(?:^|[;&|(!]|\b(?:then|do|else|if|command|builtin|exec|sudo|env))\s*curl\b")
    offenders: list[str] = []
    checked = 0
    for path in COMMUNITY_SCRIPTS.glob("*.zsh"):
        text = path.read_text(encoding="utf-8")
        for match in call.finditer(text):
            line_start = text.rfind("\n", 0, match.start()) + 1
            if text[line_start : match.start()].lstrip().startswith("#"):
                continue
            checked += 1
            if match.group("first") not in ("-q", "--disable"):
                offenders.append(f"{path.name}:{text.count(chr(10), 0, match.start()) + 1}")
        for number, line in _code_lines(path):
            if bare_call.search(line):
                offenders.append(f"{path.name}:{number}: curl without its absolute path")
    assert checked > 0, "no curl call found; update this test if downloads moved"
    assert not offenders, f"curl may read a config file: {', '.join(offenders)}"


def test_active_community_scripts_keep_the_console_users_home_out_of_child_processes():
    # HOME holds the console user's home for the path lists; exported, it would make root's child
    # processes read that user's configuration files. SetHomeFolder must unexport it first.
    reexport = re.compile(r"\bexport\b[^#]*\bHOME\b|\b(?:typeset|declare|local)\s+(?:-\w+\s+)*-\w*x\w*\b[^#]*\bHOME\b")
    offenders: list[str] = []
    for path in COMMUNITY_SCRIPTS.glob("*.zsh"):
        for number, line in _code_lines(path):
            if reexport.search(line):
                offenders.append(f"{path.name}:{number}: exports HOME")
        text = path.read_text(encoding="utf-8")
        match = re.search(r"^SetHomeFolder\(\) \{\n(?P<body>.*?)^\}", text, re.S | re.M)
        if match is None:
            offenders.append(f"{path.name}: no SetHomeFolder")
            continue
        body = match.group("body")
        unexport = re.search(r"^\s*typeset -g \+x HOME\s*$", body, re.M)
        first_assignment = re.search(r"^\s*HOME=", body, re.M)
        if unexport is None or first_assignment is None or first_assignment.start() < unexport.start():
            offenders.append(f"{path.name}: SetHomeFolder assigns HOME before unexporting it")
    assert not offenders, "; ".join(offenders)


def test_retired_community_scripts_stay_removed():
    retired = (
        "MOFA_Community_Microsoft_License_Reset.zsh",
        "MOFA_Community_Microsoft_SkypeForBusiness_Removal.zsh",
        "MOFA_Community_Microsoft_Teams_Reset.zsh",
        "MOFA_Community_WebExPT_Removal.zsh",
        "MOFA_Community_ZoomPlugin_Removal.zsh",
    )
    present = [name for name in retired if (COMMUNITY_SCRIPTS / name).exists()]
    assert not present, f"retired script(s) reintroduced: {', '.join(present)}"
