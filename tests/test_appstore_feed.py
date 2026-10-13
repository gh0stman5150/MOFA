"""Fixture tests for appstore_feed.py and the iOS/macOS App Store generators. All HTTP is faked."""

from __future__ import annotations

import json
import logging
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest
import requests
import yaml

import appstore_feed as feed
import generate_ios_appstore_latest as ios
import generate_macos_appstore_latest as macos

SEARCH = "https://itunes.example/search?term=microsoft-word&country=us&entity=software"


def microsoft_word(**overrides):
    result = {
        "trackName": "Microsoft Word",
        "bundleId": "com.microsoft.Office.Word",
        "version": "2.113.3",
        "currentVersionReleaseDate": "2026-01-31T08:00:00Z",
        "releaseNotes": "Bug fixes",
        "minimumOsVersion": "17.0",
        "artworkUrl512": "https://icons.example/word.png",
        "trackViewUrl": "https://apps.example/word",
        "sellerName": "Microsoft Corporation",
        "artistName": "Microsoft Corporation",
    }
    result.update(overrides)
    return result


IMPOSTOR = {
    "trackName": "Word Writer Pro",
    "bundleId": "com.example.wordwriter",
    "version": "9.9",
    "sellerName": "Example Apps LLC",
    "artistName": "Example Apps LLC",
}


class FakeResponse:
    def __init__(self, payload=None, status=200, body_error=None):
        self.payload = payload
        self.status_code = status
        self.body_error = body_error

    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.HTTPError(f"{self.status_code} Server Error")

    def json(self):
        if self.body_error is not None:
            raise self.body_error
        return self.payload


class FakeHttp:
    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def __call__(self, url, **kwargs):
        self.calls.append(url)
        response = self.routes.get(url)
        if response is None:
            raise requests.ConnectionError(f"connection refused: {url}")
        return response


def install_http(monkeypatch, routes):
    fake = FakeHttp(routes)
    monkeypatch.setattr(feed, "http_get", fake)
    return fake


def app_table(url=SEARCH, **extra):
    return {"iOS Microsoft Word": dict({"url": url, "keys": feed.COMMON_KEYS}, **extra)}


def cached_entry(**overrides):
    values = {
        "application_name": "Microsoft Word",
        "bundleId": "com.microsoft.Office.Word",
        "currentVersionReleaseDate": "January 01, 2026",
        "icon_image": "https://icons.example/word.png",
        "minimumOsVersion": "17.0",
        "releaseNotes": "Cached notes",
        "version": "2.100",
        "app_store_url": "https://apps.example/word",
    }
    values.update(overrides)
    return {"iOS Microsoft Word": values}


def published(root, name="iOS Microsoft Word"):
    for package in root.findall("package"):
        if package.findtext("name") == name:
            return {child.tag: child.text for child in package}
    return None


# --- fetch_app_data -------------------------------------------------------


def test_fetch_app_data_skips_results_not_published_by_microsoft(monkeypatch):
    install_http(monkeypatch, {SEARCH: FakeResponse({"resultCount": 2, "results": [IMPOSTOR, microsoft_word()]})})
    assert feed.fetch_app_data(SEARCH)["bundleId"] == "com.microsoft.Office.Word"


def test_fetch_app_data_accepts_microsoft_as_artist_only(monkeypatch):
    result = microsoft_word(sellerName=None, artistName="Microsoft Corporation")
    install_http(monkeypatch, {SEARCH: FakeResponse({"results": [result]})})
    assert feed.fetch_app_data(SEARCH) == result


@pytest.mark.parametrize("payload", [{"resultCount": 0, "results": []}, {"results": [IMPOSTOR]}])
def test_fetch_app_data_returns_none_without_a_microsoft_result(monkeypatch, payload):
    install_http(monkeypatch, {SEARCH: FakeResponse(payload)})
    assert feed.fetch_app_data(SEARCH) is None


def test_fetch_app_data_honours_a_pinned_bundle_id(monkeypatch):
    other_microsoft_app = microsoft_word(trackName="Microsoft To Do", bundleId="com.microsoft.to-do")
    install_http(monkeypatch, {SEARCH: FakeResponse({"results": [other_microsoft_app, microsoft_word()]})})
    assert feed.fetch_app_data(SEARCH, bundle_id="com.microsoft.Office.Word")["trackName"] == "Microsoft Word"
    assert feed.fetch_app_data(SEARCH, bundle_id="com.microsoft.absent") is None


@pytest.mark.parametrize(
    "response",
    [
        FakeResponse({}),
        FakeResponse({"results": None}),
        FakeResponse(["not", "an", "object"]),
        FakeResponse(body_error=json.JSONDecodeError("Expecting value", "<html>", 0)),
        FakeResponse(body_error=requests.exceptions.JSONDecodeError("Expecting value", "<html>", 0)),
        # A failing status is rejected even when the body still parses.
        FakeResponse({"results": [microsoft_word()]}, status=503),
    ],
    ids=["empty-object", "null-results", "array", "non-json", "requests-non-json", "http-503"],
)
def test_fetch_app_data_rejects_unusable_responses(monkeypatch, response):
    install_http(monkeypatch, {SEARCH: response})
    with pytest.raises(feed.AppLookupError):
        feed.fetch_app_data(SEARCH)


def test_fetch_app_data_wraps_connection_errors(monkeypatch):
    install_http(monkeypatch, {})
    with pytest.raises(feed.AppLookupError):
        feed.fetch_app_data(SEARCH)


# --- build_feed: cache and failure policy ---------------------------------


def test_build_feed_publishes_the_microsoft_match(monkeypatch, caplog):
    install_http(monkeypatch, {SEARCH: FakeResponse({"results": [IMPOSTOR, microsoft_word()]})})
    with caplog.at_level(logging.INFO):
        root = feed.build_feed(app_table(), cached_entry(), "now")
    package = published(root)
    assert package["bundleId"] == "com.microsoft.Office.Word"
    assert package["version"] == "2.113.3"
    assert package["currentVersionReleaseDate"] == "January 31, 2026"
    assert [child.tag for child in root.find("package")] == ["name"] + feed.FIELDS
    assert all(record.levelno < logging.ERROR for record in caplog.records)


def test_http_failure_keeps_cached_entry_with_a_warning(monkeypatch, caplog):
    install_http(monkeypatch, {SEARCH: FakeResponse({"results": [microsoft_word(version="9.9")]}, status=503)})
    with caplog.at_level(logging.INFO):
        root = feed.build_feed(app_table(), cached_entry(), "now")
    assert published(root)["version"] == "2.100"
    assert published(root)["releaseNotes"] == "Cached notes"
    assert any(record.levelno == logging.WARNING for record in caplog.records)
    assert all(record.levelno < logging.ERROR for record in caplog.records)


def test_http_failure_without_cache_fails_the_run(monkeypatch, caplog):
    install_http(monkeypatch, {SEARCH: FakeResponse(body_error=ValueError("not json"))})
    with caplog.at_level(logging.INFO):
        root = feed.build_feed(app_table(), {}, "now")
    assert root.findall("package") == []
    assert any(record.levelno == logging.ERROR for record in caplog.records)


@pytest.mark.parametrize("payload", [{"resultCount": 0, "results": []}, {"results": [IMPOSTOR]}])
def test_no_microsoft_match_keeps_cache_and_fails_the_run(monkeypatch, caplog, payload):
    install_http(monkeypatch, {SEARCH: FakeResponse(payload)})
    with caplog.at_level(logging.INFO):
        root = feed.build_feed(app_table(), cached_entry(), "now")
    package = published(root)
    assert package["version"] == "2.100"  # never 'NA', never the impostor
    assert package["bundleId"] == "com.microsoft.Office.Word"
    errors = [record for record in caplog.records if record.levelno == logging.ERROR]
    assert errors and "a Microsoft seller" in errors[0].getMessage()


def test_no_microsoft_match_without_cache_drops_the_app_with_error(monkeypatch, caplog):
    install_http(monkeypatch, {SEARCH: FakeResponse({"results": [IMPOSTOR]})})
    with caplog.at_level(logging.INFO):
        root = feed.build_feed(app_table(), {}, "now")
    assert root.findall("package") == []
    assert any(record.levelno == logging.ERROR for record in caplog.records)


def test_missing_result_fields_become_na(monkeypatch):
    result = microsoft_word()
    del result["trackViewUrl"]
    del result["releaseNotes"]
    install_http(monkeypatch, {SEARCH: FakeResponse({"results": [result]})})
    package = published(feed.build_feed(app_table(), {}, "now"))
    assert package["app_store_url"] == "NA"
    assert package["releaseNotes"] == "NA"


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("2026-01-31T08:00:00Z", "January 31, 2026"),
        ("January 31, 2026", "January 31, 2026"),
        ("", ""),
        (None, None),
    ],
)
def test_format_date(value, expected):
    assert feed.format_date(value) == expected


# --- cached feed and JSON/YAML conversion ---------------------------------


def write_xml(path: Path, packages, last_updated="January 01, 2026 09:00 AM EST"):
    root = ET.Element("latest")
    ET.SubElement(root, "last_updated").text = last_updated
    for values in packages:
        package = ET.SubElement(root, "package")
        for key, value in values.items():
            ET.SubElement(package, key).text = value
    ET.ElementTree(root).write(path, encoding="utf-8")


def test_read_existing_packages_skips_only_nameless_packages(tmp_path: Path, caplog):
    path = tmp_path / "store.xml"
    write_xml(path, [{"version": "1.0"}, {"name": "iOS Microsoft Word", "version": "2.0"}])
    with caplog.at_level(logging.INFO):
        existing = feed.read_existing_packages(str(path))
    assert list(existing) == ["iOS Microsoft Word"]
    assert existing["iOS Microsoft Word"]["version"] == "2.0"
    assert existing["iOS Microsoft Word"]["app_store_url"] == "NA"
    assert any("has no <name>" in record.getMessage() for record in caplog.records)


def test_xml_to_json_and_yaml_fills_missing_fields_with_na(tmp_path: Path):
    xml_file = tmp_path / "store.xml"
    # One package (not a list) without app_store_url or releaseNotes.
    write_xml(
        xml_file,
        [
            {
                "name": "MacOS Microsoft Word",
                "application_name": "Microsoft Word",
                "bundleId": "com.microsoft.Word",
                "currentVersionReleaseDate": "January 31, 2026",
                "icon_image": "https://icons.example/word.png",
                "minimumOsVersion": "14.0",
                "version": "16.113",
            }
        ],
    )
    json_file, yaml_file = tmp_path / "store.json", tmp_path / "store.yaml"

    feed.xml_to_json_and_yaml(str(xml_file), str(json_file), str(yaml_file))

    data = json.loads(json_file.read_text(encoding="utf-8"))
    assert data["last_updated"] == "January 01, 2026 09:00 AM EST"
    package = data["packages"][0]
    assert list(package) == ["name"] + feed.FIELDS
    assert package["app_store_url"] == "NA"
    assert package["releaseNotes"] == "NA"
    assert package["version"] == "16.113"
    assert yaml.safe_load(yaml_file.read_text(encoding="utf-8")) == data
    assert yaml_file.read_text(encoding="utf-8").startswith("last_updated: January 01, 2026")


@pytest.mark.parametrize(
    ("generator", "basename"),
    [(ios, "ios_appstore_latest"), (macos, "macos_appstore_latest")],
    ids=["ios", "macos"],
)
def test_generator_main_round_trip_keeps_cache_on_failures(tmp_path: Path, monkeypatch, caplog, generator, basename):
    good = "https://itunes.example/search?term=good"
    down = "https://itunes.example/search?term=down"
    wrong = "https://itunes.example/search?term=wrong"
    monkeypatch.setattr(
        generator,
        "apps",
        {
            "Good": {"url": good, "keys": generator.common_keys},
            "Down": {"url": down, "keys": generator.common_keys},
            "Wrong": {"url": wrong, "keys": generator.common_keys},
        },
    )
    install_http(
        monkeypatch,
        {
            good: FakeResponse({"results": [microsoft_word(version="3.0")]}),
            wrong: FakeResponse({"results": [IMPOSTOR]}),
        },
    )
    output_dir = tmp_path / "latest_raw_files"
    output_dir.mkdir()
    cached = {key: value for key, value in cached_entry()["iOS Microsoft Word"].items()}
    write_xml(
        output_dir / f"{basename}.xml",
        [dict(cached, name="Good"), dict(cached, name="Down", version="1.1"), dict(cached, name="Wrong", version="1.2")],
    )

    with caplog.at_level(logging.INFO):
        assert generator.main(output_dir=str(output_dir)) == 0

    root = ET.parse(output_dir / f"{basename}.xml").getroot()
    assert [published(root, name)["version"] for name in ("Good", "Down", "Wrong")] == ["3.0", "1.1", "1.2"]
    data = json.loads((output_dir / f"{basename}.json").read_text(encoding="utf-8"))
    assert [package["version"] for package in data["packages"]] == ["3.0", "1.1", "1.2"]
    assert yaml.safe_load((output_dir / f"{basename}.yaml").read_text(encoding="utf-8")) == data
    errors = [record.getMessage() for record in caplog.records if record.levelno == logging.ERROR]
    assert len(errors) == 1 and "Wrong" in errors[0]
