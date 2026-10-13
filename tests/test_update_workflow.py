"""Generated-data update workflow: change detection, concurrency and PR body."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

import has_substantive_changes

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / ".github" / "actions" / "has_substantive_changes.py"
WORKFLOW = ROOT / ".github" / "workflows" / "workflow_all_xml_updates.yml"
RUN_URL = "${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"

README = "Last Updated: <code>{stamp}</code>\n\n| Word | {version} |\n"
JSON = '{{"last_updated": "{stamp}", "packages": [{{"name": "Word", "version": "{version}"}}]}}\n'
YAML = "last_updated: '{stamp}'\npackages:\n- name: Word\n  version: '{version}'\n"
XML = (
    "<latest><last_updated>{stamp}</last_updated>"
    "<package><name>Word</name><version>{version}</version></package></latest>\n"
)


def _generated(stamp: str = "2026-01-01", version: str = "16.1") -> dict[str, str]:
    values = {"stamp": stamp, "version": version}
    return {
        "README.md": README.format(**values),
        "latest_raw_files/data.json": JSON.format(**values),
        "latest_raw_files/data.yaml": YAML.format(**values),
        "latest_raw_files/data.xml": XML.format(**values),
    }


def _git(root: Path, *args: str) -> None:
    subprocess.run(
        [
            "git",
            "-c", "user.name=MOFA Tests",
            "-c", "user.email=tests@example.invalid",
            "-c", "commit.gpgsign=false",
            *args,
        ],
        cwd=root,
        check=True,
        capture_output=True,
    )


@pytest.fixture
def make_repo(tmp_path: Path, monkeypatch):
    """Build a throwaway Git repository holding a copy of the checker."""
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")

    def build(committed: dict[str, str]) -> Path:
        root = tmp_path / "repo"
        actions = root / ".github" / "actions"
        actions.mkdir(parents=True)
        # The copy resolves ROOT (parents[2]) to this repository, not MOFA.
        shutil.copy2(CHECKER, actions / CHECKER.name)
        _write(root, committed)
        _git(root, "init", "-q")
        _git(root, "add", "-A")
        _git(root, "commit", "-q", "-m", "fixture")
        return root

    return build


def _write(root: Path, files: dict[str, str]) -> None:
    for relative, text in files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


def _check(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(root / ".github" / "actions" / CHECKER.name)],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
        timeout=60,
    )


def test_exit_codes_are_distinct():
    assert (
        has_substantive_changes.EXIT_SUBSTANTIVE,
        has_substantive_changes.EXIT_TIMESTAMPS_ONLY,
        has_substantive_changes.EXIT_ERROR,
    ) == (0, 1, 2)


def test_timestamp_only_changes_exit_1(make_repo):
    root = make_repo(_generated())
    _write(root, _generated(stamp="2026-02-02"))

    result = _check(root)

    assert result.returncode == 1, result.stderr
    assert "Only generated timestamps changed" in result.stderr


@pytest.mark.parametrize("changed", ["README.md", "latest_raw_files/data.json", "latest_raw_files/data.yaml", "latest_raw_files/data.xml"])
def test_content_change_exits_0(make_repo, changed):
    root = make_repo(_generated())
    _write(root, {changed: _generated(stamp="2026-02-02", version="16.2")[changed]})

    result = _check(root)

    assert result.returncode == 0, result.stderr
    assert f"Substantive change: {changed}" in result.stderr


def test_deleted_file_exits_0(make_repo):
    root = make_repo(_generated())
    (root / "latest_raw_files" / "data.xml").unlink()

    assert _check(root).returncode == 0


@pytest.mark.parametrize(
    "path, broken",
    [
        ("latest_raw_files/data.json", '{"packages": ['),
        ("latest_raw_files/data.yaml", "packages: [unterminated\n"),
        ("latest_raw_files/data.xml", "<latest><package>"),
    ],
)
def test_unparsable_generated_file_exits_2_not_timestamps_only(make_repo, path, broken):
    root = make_repo(_generated())
    _write(root, {path: broken})

    result = _check(root)

    assert result.returncode == 2, result.stderr
    assert "Could not compare generated files with HEAD" in result.stderr


def test_unparsable_head_version_is_substantive(make_repo):
    committed = _generated()
    committed["latest_raw_files/data.json"] = '{"packages": ['
    root = make_repo(committed)
    _write(root, {"latest_raw_files/data.json": _generated()["latest_raw_files/data.json"]})

    result = _check(root)

    assert result.returncode == 0, result.stderr
    assert "cannot be parsed" in result.stderr


def test_git_failure_exits_2(monkeypatch):
    def failing_git():
        raise subprocess.CalledProcessError(128, ["git", "diff", "--name-only"])

    monkeypatch.setattr(has_substantive_changes, "changed_paths", failing_git)

    assert has_substantive_changes.main() == has_substantive_changes.EXIT_ERROR


# --- workflow ---------------------------------------------------------------


def _workflow() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def _detect_step_script() -> str:
    steps = _workflow()["jobs"]["update"]["steps"]
    return next(step["run"] for step in steps if step.get("id") == "substantive")


def _stub(directory: Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(0o755)


def _run_detect_step(tmp_path: Path, git_diff_rc: int, checker_rc: int):
    """Run the workflow step under GitHub's default run shell, git and python stubbed."""
    stubs = tmp_path / "bin"
    stubs.mkdir()
    _stub(
        stubs,
        "git",
        'printf "git %s\\n" "$*" >> "$CALLS"\n'
        'case "$1" in\n'
        '  diff) exit "$FAKE_GIT_DIFF_RC" ;;\n'
        "  restore) exit 0 ;;\n"
        "esac\n"
        "exit 99\n",
    )
    _stub(stubs, "python", 'printf "python %s\\n" "$*" >> "$CALLS"\nexit "$FAKE_CHECKER_RC"\n')
    script = tmp_path / "step.sh"
    script.write_text(_detect_step_script(), encoding="utf-8")
    calls = tmp_path / "calls.log"
    output = tmp_path / "github_output"
    calls.touch()
    output.touch()
    env = {
        **os.environ,
        "PATH": f"{stubs}{os.pathsep}{os.environ.get('PATH', '')}",
        "CALLS": str(calls),
        "GITHUB_OUTPUT": str(output),
        "FAKE_GIT_DIFF_RC": str(git_diff_rc),
        "FAKE_CHECKER_RC": str(checker_rc),
    }
    # Linux runners execute `run:` steps as `bash --noprofile --norc -eo pipefail {0}`.
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)],
        cwd=tmp_path,
        env=env,
        text=True,
        capture_output=True,
        check=False,
        timeout=60,
    )
    return result, output.read_text(encoding="utf-8"), calls.read_text(encoding="utf-8")


needs_bash = pytest.mark.skipif(shutil.which("bash") is None, reason="bash is required")


@needs_bash
def test_detect_step_without_generated_changes_skips_checker(tmp_path: Path):
    result, output, calls = _run_detect_step(tmp_path, git_diff_rc=0, checker_rc=0)

    assert result.returncode == 0, result.stderr
    assert output.strip() == "has_changes=false"
    assert "python" not in calls


@needs_bash
def test_detect_step_opens_pull_request_for_substantive_changes(tmp_path: Path):
    result, output, calls = _run_detect_step(tmp_path, git_diff_rc=1, checker_rc=0)

    assert result.returncode == 0, result.stderr
    assert output.strip() == "has_changes=true"
    assert "git restore" not in calls


@needs_bash
def test_detect_step_restores_timestamp_only_changes(tmp_path: Path):
    result, output, calls = _run_detect_step(tmp_path, git_diff_rc=1, checker_rc=1)

    assert result.returncode == 0, result.stderr
    assert output.strip() == "has_changes=false"
    assert "git restore -- README.md latest_raw_files" in calls


@needs_bash
@pytest.mark.parametrize("checker_rc", [2, 3, 127])
def test_detect_step_fails_on_checker_error_without_discarding(tmp_path: Path, checker_rc):
    result, output, calls = _run_detect_step(tmp_path, git_diff_rc=1, checker_rc=checker_rc)

    assert result.returncode != 0
    assert output == ""
    assert "git restore" not in calls
    assert f"exit code {checker_rc}" in result.stdout


def test_only_the_update_job_is_serialized():
    """Hourly refreshes must not queue or cancel push and pull request validation."""
    workflow = _workflow()
    assert "concurrency" not in workflow, "workflow-level concurrency would include validation runs"

    jobs = workflow["jobs"]
    update = jobs["update"]
    assert update["concurrency"] == {"group": "mofa-generated-data", "cancel-in-progress": False}
    assert "github.event_name == 'schedule'" in update["if"]
    assert "github.event_name == 'workflow_dispatch'" in update["if"]
    assert "push" not in update["if"] and "pull_request" not in update["if"]
    for name, job in jobs.items():
        if name != "update":
            assert "mofa-generated-data" not in str(job.get("concurrency", "")), name


def test_generated_data_pull_request_links_its_validation_run():
    steps = _workflow()["jobs"]["update"]["steps"]
    step = next(s for s in steps if s.get("uses", "").startswith("peter-evans/create-pull-request@"))
    inputs = step["with"]
    body = inputs["body"]

    assert RUN_URL in body
    assert "Validation ran in that run" in body
    if "token" not in inputs:
        # GITHUB_TOKEN-created pull requests start no workflows.
        assert "no status checks" in body
