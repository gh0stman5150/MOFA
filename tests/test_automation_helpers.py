from __future__ import annotations

import importlib.util
import json
import logging
import subprocess
import xml.etree.ElementTree as ET
from hashlib import sha1, sha256
from pathlib import Path

import pytest
import requests

import generate_macos_standalone_beta as beta
import generate_macos_standalone_latest as latest
import generate_macos_standalone_preview as preview
import has_substantive_changes
import http_client
import run_generators
import standalone_feed

ROOT = Path(__file__).resolve().parents[1]
ACTIONS = ROOT / ".github" / "actions"
STANDALONE_GENERATORS = (latest, preview, beta)


@pytest.fixture(autouse=True)
def fresh_hash_cache(monkeypatch):
    monkeypatch.setattr(standalone_feed, "_HASH_CACHE", {})


def test_json_timestamp_is_not_substantive(tmp_path: Path):
    path = tmp_path / "data.json"
    old = json.dumps({"last_updated": "old", "packages": [{"version": "1"}]}).encode()
    new = json.dumps({"last_updated": "new", "packages": [{"version": "1"}]}).encode()
    assert has_substantive_changes.normalize(path, old) == has_substantive_changes.normalize(
        path, new
    )


def test_json_content_change_is_substantive(tmp_path: Path):
    path = tmp_path / "data.json"
    old = json.dumps({"last_updated": "old", "packages": [{"version": "1"}]}).encode()
    new = json.dumps({"last_updated": "new", "packages": [{"version": "2"}]}).encode()
    assert has_substantive_changes.normalize(path, old) != has_substantive_changes.normalize(
        path, new
    )


def test_nested_json_timestamp_is_not_substantive(tmp_path: Path):
    path = tmp_path / "data.json"
    old = json.dumps({"packages": [{"version": "1", "last_updated": "old"}]}).encode()
    new = json.dumps({"packages": [{"version": "1", "last_updated": "new"}]}).encode()
    assert has_substantive_changes.normalize(path, old) == has_substantive_changes.normalize(
        path, new
    )


def test_xml_root_timestamp_is_not_substantive(tmp_path: Path):
    path = tmp_path / "data.xml"
    old = b"<latest><last_updated>old</last_updated><package><version>1</version></package></latest>"
    new = b"<latest><last_updated>new</last_updated><package><version>1</version></package></latest>"
    assert has_substantive_changes.normalize(path, old) == has_substantive_changes.normalize(
        path, new
    )
    ET.fromstring(has_substantive_changes.normalize(path, new))


def test_nested_xml_timestamp_is_not_substantive(tmp_path: Path):
    path = tmp_path / "data.xml"
    old = b"<latest><package><version>1</version><last_updated>old</last_updated></package></latest>"
    new = b"<latest><package><version>1</version><last_updated>new</last_updated></package></latest>"
    assert has_substantive_changes.normalize(path, old) == has_substantive_changes.normalize(
        path, new
    )


def test_runner_detects_generator_errors():
    assert run_generators.ERROR_PATTERN.search("Error processing remote feed: timeout")
    assert run_generators.ERROR_PATTERN.search("error processing remote feed: timeout")
    assert run_generators.ERROR_PATTERN.search("2026-08-13 - ERROR - request failed")
    assert not run_generators.ERROR_PATTERN.search(
        "2026-08-13 - INFO - Error computing SHA256 for https://example.test: timeout"
    )
    assert not run_generators.ERROR_PATTERN.search("Completed without errors")


def test_standalone_generators_share_one_implementation():
    for generator in STANDALONE_GENERATORS:
        assert generator.feed is standalone_feed, generator.__name__
        for name in ("read_existing_xml", "compute_hashes", "_HASH_CACHE", "process_xml_data"):
            assert name not in vars(generator), f"{generator.__name__} redefines {name}"


def test_hash_requests_are_skipped_for_na_urls(monkeypatch, caplog):
    def fail_http_get(*args, **kwargs):
        raise AssertionError("http_get should not be called for N/A URLs")

    monkeypatch.setattr(standalone_feed, "http_get", fail_http_get)

    with caplog.at_level("ERROR"):
        for url in ("N/A", " N/A ", "n/a", "", "   ", None):
            assert standalone_feed.compute_sha1(url) == "N/A"
            assert standalone_feed.compute_sha256(url) == "N/A"

    assert "Error computing SHA" not in caplog.text


def test_hash_failures_are_warnings_not_errors(monkeypatch, caplog):
    def fail_http_get(*args, **kwargs):
        raise RuntimeError("network failure")

    monkeypatch.setattr(standalone_feed, "http_get", fail_http_get)

    with caplog.at_level("WARNING"):
        assert standalone_feed.compute_sha1("https://example.test/file.pkg") == "N/A"
        assert standalone_feed.compute_sha256("https://example.test/file.pkg") == "N/A"

    assert "Error computing SHA1/SHA256" in caplog.text
    assert all(record.levelno < logging.ERROR for record in caplog.records)


class _FakeResponse:
    def __init__(self, payload: bytes):
        self.payload = payload
        self.content = payload
        self.headers = {}
        self.status_code = 200

    def raise_for_status(self):
        return None

    def iter_content(self, chunk_size):
        for start in range(0, len(self.payload), 3):
            yield self.payload[start : start + 3]


def _counting_http(monkeypatch, payload, routes=None):
    calls = []

    def fake_http_get(url, **kwargs):
        calls.append(url)
        return _FakeResponse((routes or {}).get(url, payload))

    monkeypatch.setattr(standalone_feed, "http_get", fake_http_get)
    return calls


def test_latest_generator_downloads_each_installer_once_for_both_hashes(monkeypatch):
    payload = b"installer-bytes-for-hashing"
    calls = _counting_http(monkeypatch, payload)
    url = "https://example.test/full.pkg"
    data = {"full_update_download": url, "app_only_update_download": url}

    latest.add_hashes(data)

    assert data["full_update_sha1"] == data["app_update_sha1"] == sha1(payload).hexdigest()
    assert data["full_update_sha256"] == data["app_update_sha256"] == sha256(payload).hexdigest()
    assert calls == [url]


@pytest.mark.parametrize("generator", (preview, beta), ids=lambda module: module.__name__)
def test_channel_generators_download_each_installer_once_for_both_hashes(monkeypatch, generator):
    payload = b"installer-bytes-for-hashing"
    manifest = "https://example.test/manifest.xml"
    url = "https://example.test/latest.pkg"
    plist = (
        "<plist><array><dict><key>Title</key><string>App 1.0</string>"
        f"<key>Location</key><string>{url}</string></dict></array></plist>"
    ).encode()
    calls = _counting_http(monkeypatch, payload, routes={manifest: plist})
    config = {"url": manifest, "manual_entries": {}, "keys": {"short_version": "Title", "latest_download": "Location"}}
    run = standalone_feed.FeedRun({}, generator.FIELD_ORDER, "now")

    generator.fetch_and_process("App", config, run)

    package = run.root.find("package")
    assert package.findtext("short_version") == "1.0"
    assert package.findtext("sha1") == sha1(payload).hexdigest()
    assert package.findtext("sha256") == sha256(payload).hexdigest()
    assert calls == [manifest, url]


@pytest.mark.parametrize("generator", STANDALONE_GENERATORS, ids=lambda module: module.__name__)
def test_fetch_failures_revert_to_cache_or_fail_the_run(monkeypatch, caplog, generator):
    def failing_http_get(*args, **kwargs):
        raise RuntimeError("network failure")

    monkeypatch.setattr(standalone_feed, "http_get", failing_http_get)
    config = {"url": "https://example.test/feed.xml", "manual_entries": {}, "keys": {}}

    cached = {"Word": {"last_updated": "January 01, 2026", "data": {"short_version": "16.1"}}}
    run = standalone_feed.FeedRun(cached, generator.FIELD_ORDER, "now")
    with caplog.at_level("INFO"):
        generator.fetch_and_process("Word", config, run)
    packages = run.root.findall("package")
    assert [p.findtext("name") for p in packages] == ["Word"]
    assert packages[0].findtext("short_version") == "16.1"
    assert all(record.levelno < logging.ERROR for record in caplog.records)

    caplog.clear()
    run = standalone_feed.FeedRun({}, generator.FIELD_ORDER, "now")
    with caplog.at_level("INFO"):
        generator.fetch_and_process("NewApp", config, run)
    assert run.root.findall("package") == []
    assert any(record.levelno == logging.ERROR for record in caplog.records)


def _snapshot(directory: Path):
    return {
        path.relative_to(directory): path.stat().st_mtime_ns
        for path in directory.rglob("*")
        if path.is_file() and "__pycache__" not in path.parts
    }


def test_every_generator_imports_without_side_effects(tmp_path: Path, monkeypatch):
    """Importing a generator must not fetch, run commands, write files or configure logging; only main() does."""

    def forbidden(*args, **kwargs):
        raise AssertionError(f"side effect at import time: {args[:1]} {kwargs}")

    monkeypatch.setattr(http_client, "get", forbidden)
    monkeypatch.setattr(requests.Session, "request", forbidden)
    for name in ("run", "Popen", "check_output", "call"):
        monkeypatch.setattr(subprocess, name, forbidden)
    # basicConfig is a no-op under pytest (the root logger already has
    # handlers), so forbid the call itself: an import must not reconfigure
    # the importer's logging (update_readme.py used to set DEBUG).
    monkeypatch.setattr(logging, "basicConfig", forbidden)
    monkeypatch.chdir(tmp_path)
    before = _snapshot(ROOT / "latest_raw_files")

    for generator in run_generators.GENERATORS:
        spec = importlib.util.spec_from_file_location(f"_smoke_{Path(generator).stem}", ACTIONS / generator)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        assert callable(getattr(module, "main", None)), f"{generator} has no main()"

    assert list(tmp_path.iterdir()) == []
    assert _snapshot(ROOT / "latest_raw_files") == before
