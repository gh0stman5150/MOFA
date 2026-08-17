from __future__ import annotations

import json
import xml.etree.ElementTree as ET
from pathlib import Path

import has_substantive_changes
import run_generators


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
    assert run_generators.ERROR_PATTERN.search("2026-08-13 - ERROR - request failed")
    assert not run_generators.ERROR_PATTERN.search(
        "2026-08-13 - INFO - Error computing SHA256 for https://example.test: timeout"
    )
    assert not run_generators.ERROR_PATTERN.search("Completed without errors")
