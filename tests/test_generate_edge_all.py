"""Fixture tests for generate_edge_all.py. All HTTP is faked."""

from __future__ import annotations

import json
import logging
import plistlib
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from hashlib import sha1, sha256
from pathlib import Path

import pytest
import yaml

import generate_edge_all as edge
import run_generators

API = "https://edgeupdates.example/api/products/stable"
PKG = "https://msedge.example/filestreamingservice/files/MicrosoftEdge-200.0.1.2.pkg"
PAYLOAD = b"synthetic-edge-installer"
GENERATOR_FORMAT = logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")


class FakeResponse:
    def __init__(self, *, payload=None, content=b"", status=200):
        self.payload = payload
        self.content = content
        self.status_code = status

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    def json(self):
        if isinstance(self.payload, Exception):
            raise self.payload
        return self.payload

    def iter_content(self, chunk_size):
        for start in range(0, len(self.content), 4):
            yield self.content[start : start + 4]

    def close(self):
        pass


class FakeHttp:
    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def __call__(self, url, **kwargs):
        self.calls.append(url)
        if url not in self.routes:
            raise RuntimeError(f"connection refused: {url}")
        return self.routes[url]


def release(platform, published, version, artifacts=None):
    return {
        "Platform": platform,
        "PublishedTime": published,
        "ProductVersion": version,
        "Artifacts": artifacts if artifacts is not None else [
            {"ArtifactName": "pkg", "Location": PKG},
            {"ArtifactName": "plist", "Location": "https://example.test/policy.plist"},
        ],
    }


def releases_payload(*items):
    return [{"Product": "Stable", "Releases": list(items)}]


def expected_date(published_utc: datetime) -> str:
    return published_utc.astimezone(edge.eastern).strftime(edge.DATE_FORMAT)


def no_errors(caplog):
    return all(record.levelno < logging.ERROR for record in caplog.records)


def test_latest_macos_pkg_release_is_selected(monkeypatch):
    payload = releases_payload(
        release("Windows", "2026-09-02T10:00:00", "201.0.0.0", [{"ArtifactName": "msi", "Location": "x"}]),
        release("MacOS", "2026-08-29T19:19:00", "200.0.1.2"),
        release("MacOS", "2026-08-01T08:00:00", "199.0.0.1"),
    )
    monkeypatch.setattr(edge, "http_get", FakeHttp({API: FakeResponse(payload=payload)}))

    info = edge.fetch_edge_insider_version(API, "current")

    assert info == {
        "channel": "current",
        "date": expected_date(datetime(2026, 8, 29, 19, 19, tzinfo=timezone.utc)),
        "location": PKG,
        "version": "200.0.1.2",
    }


@pytest.mark.parametrize(
    "published",
    ["2026-08-29T19:19:00", "2026-08-29T19:19:00Z", "2026-08-29T19:19:00.1234567Z"],
)
def test_published_time_formats_are_tolerated_as_utc(published):
    assert edge.format_published_time(published) == expected_date(
        datetime(2026, 8, 29, 19, 19, tzinfo=timezone.utc)
    )


def test_release_without_pkg_artifact_has_na_location(monkeypatch):
    payload = releases_payload(
        release("MacOS", "2026-08-29T19:19:00", "200.0.1.2", [{"ArtifactName": "plist", "Location": "x"}])
    )
    monkeypatch.setattr(edge, "http_get", FakeHttp({API: FakeResponse(payload=payload)}))
    assert edge.fetch_edge_insider_version(API, "current")["location"] == "N/A"


@pytest.mark.parametrize(
    "response",
    [
        FakeResponse(payload=releases_payload()),  # empty Releases
        FakeResponse(payload=releases_payload(release("Windows", "2026-08-29T19:19:00", "1"))),
        FakeResponse(payload=[]),  # no products
        FakeResponse(payload={"unexpected": "shape"}),
        FakeResponse(payload=releases_payload({"Platform": "MacOS"})),  # missing fields
        FakeResponse(payload=releases_payload(release("MacOS", "yesterday", "1"))),
        FakeResponse(payload=ValueError("not JSON")),
        FakeResponse(status=503),
    ],
)
def test_unusable_release_data_returns_none_with_warning(monkeypatch, caplog, response):
    monkeypatch.setattr(edge, "http_get", FakeHttp({API: response}))
    with caplog.at_level(logging.INFO):
        assert edge.fetch_edge_insider_version(API, "current") is None
    assert any(record.levelno == logging.WARNING for record in caplog.records)
    assert no_errors(caplog)


def test_hashes_are_computed_from_one_download(monkeypatch):
    http = FakeHttp({PKG: FakeResponse(content=PAYLOAD)})
    monkeypatch.setattr(edge, "http_get", http)
    assert edge.generate_hashes(PKG) == (sha1(PAYLOAD).hexdigest(), sha256(PAYLOAD).hexdigest())
    assert http.calls == [PKG]


def test_hash_failure_is_a_warning_the_runner_does_not_treat_as_fatal(monkeypatch, caplog):
    monkeypatch.setattr(edge, "http_get", FakeHttp({}))
    with caplog.at_level(logging.INFO):
        assert edge.generate_hashes(PKG) == ("N/A", "N/A")
    assert caplog.records and no_errors(caplog)
    output = "\n".join(GENERATOR_FORMAT.format(record) for record in caplog.records)
    assert not run_generators.ERROR_PATTERN.search(output)


def write_global(path: Path, *, date="August 29, 2026 03:19 PM EDT", sha="a" * 64, channels=("current",)):
    root = ET.Element("EdgeInsiderVersions")
    ET.SubElement(root, "last_updated").text = "old"
    for channel in channels:
        entry = ET.SubElement(root, "Version")
        for tag, text in (
            ("Name", channel),
            ("Version", "199.0.0.1"),
            ("Application_ID", "EDGE01"),
            ("Application_Name", "Microsoft Edge.app"),
            ("CFBundleVersion", "com.microsoft.edgemac"),
            ("Full_Update_Download", "https://example.test/old.pkg"),
            ("Full_Update_Sha1", "b" * 40),
            ("Full_Update_Sha256", sha),
            ("Last_Update", date),
        ):
            ET.SubElement(entry, tag).text = text
    path.write_bytes(ET.tostring(root, encoding="utf-8"))


def test_should_update_channel(tmp_path: Path):
    global_file = tmp_path / "edge.xml"
    write_global(global_file)
    assert edge.should_update_channel(str(global_file), "current", "August 29, 2026 03:19 PM EDT") is False
    assert edge.should_update_channel(str(global_file), "current", "September 01, 2026 03:19 PM EDT") is True
    assert edge.should_update_channel(str(global_file), "beta", "August 29, 2026 03:19 PM EDT") is True


def test_channel_with_na_hashes_is_retried(tmp_path: Path):
    global_file = tmp_path / "edge.xml"
    write_global(global_file, sha="N/A")
    assert edge.should_update_channel(str(global_file), "current", "August 29, 2026 03:19 PM EDT") is True


def test_unparseable_global_file_is_logged_as_an_error(tmp_path: Path, caplog):
    global_file = tmp_path / "edge.xml"
    global_file.write_text("<EdgeInsiderVersions><Version>", encoding="utf-8")
    with caplog.at_level(logging.INFO):
        edge.should_update_channel(str(global_file), "current", "date")
    output = "\n".join(GENERATOR_FORMAT.format(record) for record in caplog.records)
    assert run_generators.ERROR_PATTERN.search(output)


def test_extract_info_from_plist_fixture_and_invalid_file(tmp_path: Path, caplog):
    plist_path = tmp_path / "edge_current_version.xml"
    plist_path.write_bytes(
        plistlib.dumps(
            [
                {
                    "Date": datetime(2026, 8, 29, 19, 19, tzinfo=timezone.utc),
                    "Location": PKG,
                    "Title": "Microsoft Edge 200.0.1.2",
                }
            ]
        )
    )
    info = edge.extract_info_from_xml(str(plist_path))
    assert info["channel"] == "current"
    assert info["version"] == "200.0.1.2"
    assert info["location"] == PKG
    assert info["date"] != "N/A"

    broken = tmp_path / "edge_beta_version.xml"
    broken.write_text("not a plist", encoding="utf-8")
    with caplog.at_level(logging.INFO):
        info = edge.extract_info_from_xml(str(broken))
    assert info == {"channel": "beta", "date": "N/A", "location": "N/A", "version": "N/A"}
    assert any(record.levelno == logging.ERROR for record in caplog.records)


def test_main_updates_changed_channel_and_keeps_cached_ones(monkeypatch, tmp_path: Path, caplog):
    global_file = tmp_path / "macos_standalone_edge_all.xml"
    write_global(global_file, channels=("current", "canary", "dev", "beta"))
    monkeypatch.setattr(edge, "CHANNELS", {"current": API, "beta": "https://edgeupdates.example/beta"})
    payload = releases_payload(release("MacOS", "2026-09-02T12:00:00.5Z", "200.0.1.2"))
    monkeypatch.setattr(
        edge,
        "http_get",
        FakeHttp({API: FakeResponse(payload=payload), PKG: FakeResponse(content=PAYLOAD)}),
    )

    with caplog.at_level(logging.INFO):
        assert edge.main(str(tmp_path)) == 0

    assert no_errors(caplog)
    root = ET.parse(global_file).getroot()
    entries = {v.findtext("Name"): v for v in root.findall("Version")}
    assert entries["current"].findtext("Version") == "200.0.1.2"
    assert entries["current"].findtext("Full_Update_Download") == PKG
    assert entries["current"].findtext("Full_Update_Sha256") == sha256(PAYLOAD).hexdigest()
    assert entries["beta"].findtext("Version") == "199.0.0.1"
    data = json.loads((tmp_path / "macos_standalone_edge_all.json").read_text(encoding="utf-8"))
    assert yaml.safe_load((tmp_path / "macos_standalone_edge_all.yaml").read_text(encoding="utf-8")) == data


def test_main_logs_error_for_a_channel_with_no_data_and_no_cache(monkeypatch, tmp_path: Path, caplog):
    monkeypatch.setattr(edge, "CHANNELS", {"current": API})
    monkeypatch.setattr(edge, "http_get", FakeHttp({}))
    with caplog.at_level(logging.INFO):
        edge.main(str(tmp_path))
    assert any(record.levelno == logging.ERROR for record in caplog.records)


def test_main_leaves_an_unparseable_feed_unchanged(monkeypatch, tmp_path: Path, caplog):
    global_file = tmp_path / "macos_standalone_edge_all.xml"
    global_file.write_text("<EdgeInsiderVersions><Version>", encoding="utf-8")
    json_file = tmp_path / "macos_standalone_edge_all.json"
    json_file.write_text('{"cached": true}', encoding="utf-8")
    monkeypatch.setattr(edge, "CHANNELS", {"current": API})
    payload = releases_payload(release("MacOS", "2026-09-02T12:00:00", "200.0.1.2"))
    http = FakeHttp({API: FakeResponse(payload=payload), PKG: FakeResponse(content=PAYLOAD)})
    monkeypatch.setattr(edge, "http_get", http)

    with caplog.at_level(logging.INFO):
        assert edge.main(str(tmp_path)) == 1

    assert http.calls == []
    assert global_file.read_text(encoding="utf-8") == "<EdgeInsiderVersions><Version>"
    assert json_file.read_text(encoding="utf-8") == '{"cached": true}'
    assert not (tmp_path / "macos_standalone_edge_all.yaml").exists()
    output = "\n".join(GENERATOR_FORMAT.format(record) for record in caplog.records)
    assert run_generators.ERROR_PATTERN.search(output)


def test_generator_reports_through_logging_only():
    source = Path(edge.__file__).read_text(encoding="utf-8")
    assert "print(" not in source
