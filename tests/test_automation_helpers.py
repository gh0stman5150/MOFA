from __future__ import annotations

import ast
import json
import logging
import xml.etree.ElementTree as ET
from hashlib import sha1, sha256
from pathlib import Path

import has_substantive_changes
import run_generators

ROOT = Path(__file__).resolve().parents[1]
LATEST_GENERATOR = ROOT / ".github" / "actions" / "generate_macos_standalone_latest.py"
PREVIEW_GENERATOR = ROOT / ".github" / "actions" / "generate_macos_standalone_preview.py"
BETA_GENERATOR = ROOT / ".github" / "actions" / "generate_macos_standalone_beta.py"


def load_hash_functions(generator_path: Path):
    module = ast.parse(generator_path.read_text(encoding="utf-8"), filename=str(generator_path))
    functions = [
        node
        for node in module.body
        if isinstance(node, ast.FunctionDef) and node.name in {"compute_sha1", "compute_sha256"}
    ]
    namespace = {"logging": logging, "sha1": sha1, "sha256": sha256}
    exec(compile(ast.Module(body=functions, type_ignores=[]), str(generator_path), "exec"), namespace)
    return namespace["compute_sha1"], namespace["compute_sha256"], namespace


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


def test_latest_generator_skips_hash_requests_for_na_urls(monkeypatch, caplog):
    def fail_http_get(*args, **kwargs):
        raise AssertionError("http_get should not be called for N/A URLs")

    compute_sha1, compute_sha256, namespace = load_hash_functions(LATEST_GENERATOR)
    namespace["http_get"] = fail_http_get

    sentinel_urls = ("N/A", " N/A ", "n/a", "", "   ")

    with caplog.at_level("ERROR"):
        for url in sentinel_urls:
            assert compute_sha1(url) == "N/A"
            assert compute_sha256(url) == "N/A"

    assert "Error computing SHA" not in caplog.text


def test_preview_generator_does_not_log_hash_failures_as_errors(caplog):
    def fail_http_get(*args, **kwargs):
        raise RuntimeError("network failure")

    compute_sha1, compute_sha256, namespace = load_hash_functions(PREVIEW_GENERATOR)
    namespace["http_get"] = fail_http_get

    with caplog.at_level("WARNING"):
        assert compute_sha1("https://example.test/file.pkg") == "N/A"
        assert compute_sha256("https://example.test/file.pkg") == "N/A"

    assert "Error computing SHA1" in caplog.text
    assert "Error computing SHA256" in caplog.text
    assert all(record.levelno < logging.ERROR for record in caplog.records)


def test_beta_generator_does_not_log_hash_failures_as_errors(caplog):
    def fail_http_get(*args, **kwargs):
        raise RuntimeError("network failure")

    compute_sha1, compute_sha256, namespace = load_hash_functions(BETA_GENERATOR)
    namespace["http_get"] = fail_http_get

    with caplog.at_level("WARNING"):
        assert compute_sha1("https://example.test/file.pkg") == "N/A"
        assert compute_sha256("https://example.test/file.pkg") == "N/A"

    assert "Error computing SHA1" in caplog.text
    assert "Error computing SHA256" in caplog.text
    assert all(record.levelno < logging.ERROR for record in caplog.records)
