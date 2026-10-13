"""Fail-closed tests for the update-history and CVE-history generators. All HTTP is faked."""

from __future__ import annotations

import json
import logging
from pathlib import Path

import pytest
import requests
import yaml

import generate_macos_standalone_cve_history as cve_history
import generate_macos_standalone_update_history as update_history
import run_generators

HEADERS = "<tr><th>Release date</th><th>Version</th><th>Install package</th><th>Update packages</th></tr>"
HISTORY_ROW = (
    "<tr><td>January 13, 2026</td><td>16.105 (Build 26011018)</td>"
    '<td><a href="https://cdn.example/suite_with_teams.pkg">Office suite (with Teams)</a>'
    '<a href="https://cdn.example/suite.pkg">Office suite (without Teams)</a></td>'
    '<td><a href="https://cdn.example/word.pkg">Word</a><a href="https://cdn.example/excel.pkg">Excel</a></td></tr>'
    "<tr><td>December 9, 2025</td><td>16.104</td><td>Office suite</td><td>None</td></tr>"
)
CVE_PAGE = """<html><body>
<h2 id="january-13-2026">January 13, 2026</h2><p><em>Version 16.105 (Build 26011018)</em></p>
<h3>Security updates</h3>
<h3>Excel</h3><ul><li><a href="https://msrc.example/CVE-2026-0001">CVE-2026-0001</a></li></ul>
<h2 id="december-9-2025">December 9, 2025</h2><p><em>Version 16.104</em></p>
<h3>Word</h3><ul><li>Feature work</li></ul>
<h2 id="december-10-2019">December 10, 2019</h2><p><em>Version 16.32</em></p>
</body></html>"""


class FakePage:
    def __init__(self, text, status=200):
        self.text = text
        self.status_code = status

    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.HTTPError(f"{self.status_code} Server Error: Service Unavailable")


def serve(monkeypatch, module, page):
    calls = []

    def fake_get(url, **kwargs):
        calls.append(url)
        if isinstance(page, Exception):
            raise page
        return page

    monkeypatch.setattr(module, "http_get", fake_get)
    return calls


def generator_log(caplog):
    return "\n".join(f"x - {record.levelname} - {record.getMessage()}" for record in caplog.records)


@pytest.fixture
def output_dir(tmp_path: Path) -> Path:
    path = tmp_path / "latest_raw_files"
    path.mkdir()
    return path


# --- update history -------------------------------------------------------


@pytest.mark.parametrize(
    "page",
    [
        FakePage(f"<html><table><tr><th>Date</th><th>Build</th></tr>{HISTORY_ROW}</table></html>"),
        FakePage(f"<html><table>{HEADERS}</table></html>"),
        FakePage("<html><h1>Service Unavailable</h1></html>", status=503),
        requests.ConnectionError("connection reset"),
        FakePage(f"<html><table>{HEADERS}<tr><td>1</td><td>2</td><td>3</td><td>4</td><td>extra</td></tr></table></html>"),
    ],
    ids=["headers-differ", "no-rows", "http-503", "connection-error", "malformed-row"],
)
def test_update_history_fails_closed_and_writes_nothing(monkeypatch, caplog, output_dir, page):
    serve(monkeypatch, update_history, page)

    with caplog.at_level(logging.INFO):
        assert update_history.main(output_dir=str(output_dir)) == 1

    assert list(output_dir.iterdir()) == []
    assert any(record.levelno == logging.ERROR for record in caplog.records)
    assert run_generators.ERROR_PATTERN.search(generator_log(caplog))


def test_update_history_rejects_an_http_error_even_with_a_usable_table(monkeypatch, caplog, output_dir):
    # A 5xx whose body still holds a valid table (a stale cache or error page
    # that embeds the old content) is caught only by raise_for_status().
    serve(monkeypatch, update_history, FakePage(f"<html><table>{HEADERS}{HISTORY_ROW}</table></html>", status=503))

    with caplog.at_level(logging.INFO):
        assert update_history.main(output_dir=str(output_dir)) == 1

    assert list(output_dir.iterdir()) == []
    errors = [record.getMessage() for record in caplog.records if record.levelno == logging.ERROR]
    assert len(errors) == 1 and "Could not fetch" in errors[0] and "503" in errors[0]


def test_update_history_writes_matching_files(monkeypatch, caplog, output_dir):
    serve(monkeypatch, update_history, FakePage(f"<html><table>{HEADERS}{HISTORY_ROW}</table></html>"))

    with caplog.at_level(logging.INFO):
        assert update_history.main(output_dir=str(output_dir)) == 0

    data = json.loads((output_dir / "macos_standalone_update_history.json").read_text(encoding="utf-8"))
    assert yaml.safe_load((output_dir / "macos_standalone_update_history.yaml").read_text(encoding="utf-8")) == data
    first, second = data["releases"]
    assert first["version"] == "16.105 (Build 26011018)"
    assert first["businesspro_suite_download"] == "https://cdn.example/suite_with_teams.pkg"
    assert first["suite_download"] == "https://cdn.example/suite.pkg"
    assert first["word_update"] == "https://cdn.example/word.pkg"
    assert first["archive"] == "false"
    assert second["archive"] == "true"
    assert all(record.levelno < logging.ERROR for record in caplog.records)


# --- CVE history ----------------------------------------------------------


@pytest.mark.parametrize(
    "page",
    [
        FakePage("<html><body><h1>Maintenance</h1></body></html>"),
        FakePage(CVE_PAGE, status=503),
        requests.Timeout("read timed out"),
    ],
    ids=["no-sections", "http-503", "timeout"],
)
def test_cve_history_fails_closed_and_writes_nothing(monkeypatch, caplog, output_dir, page):
    serve(monkeypatch, cve_history, page)

    with caplog.at_level(logging.INFO):
        assert cve_history.main(output_dir=str(output_dir)) == 1

    assert list(output_dir.iterdir()) == []
    assert any(record.levelno == logging.ERROR for record in caplog.records)
    assert run_generators.ERROR_PATTERN.search(generator_log(caplog))


def test_cve_history_script_exits_nonzero_on_http_error(monkeypatch, output_dir):
    import runpy
    import sys
    import types

    fake_client = types.ModuleType("http_client")
    fake_client.get = lambda *args, **kwargs: FakePage("", status=503)
    monkeypatch.setitem(sys.modules, "http_client", fake_client)
    monkeypatch.chdir(output_dir.parent)

    generator = Path(cve_history.__file__)
    with pytest.raises(SystemExit) as exit_info:
        runpy.run_path(str(generator), run_name="__main__")
    assert exit_info.value.code == 1
    assert list(output_dir.iterdir()) == []


def test_cve_history_parses_sections_until_the_stop_date(monkeypatch, caplog, output_dir):
    serve(monkeypatch, cve_history, FakePage(CVE_PAGE))

    with caplog.at_level(logging.INFO):
        assert cve_history.main(output_dir=str(output_dir)) == 0

    data = json.loads((output_dir / "mac_standalone_cve_history.json").read_text(encoding="utf-8"))
    assert yaml.safe_load((output_dir / "mac_standalone_cve_history.yaml").read_text(encoding="utf-8")) == data
    assert [update["date_text"] for update in data["updates"]] == ["January 13, 2026", "December 9, 2025"]
    assert data["updates"][0]["security_updates"] == {
        "Excel": [{"cve_name": "CVE-2026-0001", "url": "https://msrc.example/CVE-2026-0001"}]
    }
    assert data["updates"][1]["security_updates"] == {"N/A": [{"cve_name": "N/A", "url": None}]}
    assert (output_dir / "mac_standalone_cve_history.xml").read_text(encoding="utf-8").count("<Update>") == 2
    assert all(record.levelno < logging.ERROR for record in caplog.records)
