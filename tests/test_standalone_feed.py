"""Fixture tests for standalone_feed.py and the latest/preview/beta generators. All HTTP is faked."""

from __future__ import annotations

import json
import logging
import xml.etree.ElementTree as ET
from hashlib import sha1, sha256
from pathlib import Path

import pytest
import yaml

import generate_macos_standalone_beta as beta
import generate_macos_standalone_latest as latest
import generate_macos_standalone_preview as preview
import standalone_feed as feed

MANIFEST = "https://officecdn.example/MacAutoupdate/0409MSWD2019.xml"
APP_PKG = "https://officecdn.example/Microsoft_Word_16.90_Updater.pkg"
FULL_PKG = "https://officecdn.example/Microsoft_Word_16.90_Installer.pkg"
APP_PAYLOAD = b"synthetic-app-only-update"
FULL_PAYLOAD = b"synthetic-full-installer"

WORD_CONFIG = {
    "url": MANIFEST,
    "manual_entries": {"CFBundleVersion": "com.microsoft.word", "full_update_download": FULL_PKG},
    "keys": {
        "application_id": "Application ID",
        "application_name": "Application Name",
        "short_version": "Title",
        "full_version": "Update Version",
        "app_only_update_download": "FullUpdaterLocation",
        "last_updated": "Date",
        "min_os": "Minimum OS",
    },
}

WORD_PLIST_VALUES = {
    "Application ID": "com.microsoft.Word",
    "Application Name": "Microsoft Word",
    "Title": "Microsoft Word 16.90",
    "Update Version": "16.90.24121212",
    "FullUpdaterLocation": APP_PKG,
    "Date": "2026-01-31T08:00:00Z",
    "Minimum OS": "13.0",
}

# What WORD_CONFIG extracts from WORD_PLIST_VALUES.
WORD_EXTRACTED = {
    "application_id": "com.microsoft.Word",
    "application_name": "Microsoft Word",
    "CFBundleVersion": "com.microsoft.word",
    "short_version": "16.90",
    "full_version": "16.90.24121212",
    "last_updated": "January 31, 2026",
    "min_os": "13.0",
    "app_only_update_download": APP_PKG,
    "full_update_download": FULL_PKG,
}


def plist(values: dict) -> bytes:
    inner = "".join(f"<key>{key}</key><string>{value}</string>" for key, value in values.items())
    return f'<?xml version="1.0"?><plist version="1.0"><array><dict>{inner}</dict></array></plist>'.encode()


class FakeResponse:
    def __init__(self, content=b"", headers=None, status=200, payload=None):
        self.content = content
        self.headers = {} if headers is None else headers
        self.status_code = status
        self.payload = payload

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    def json(self):
        if self.payload is not None:
            return self.payload
        return json.loads(self.content)

    def iter_content(self, chunk_size):
        for start in range(0, len(self.content), 5):
            yield self.content[start : start + 5]


class FakeHttp:
    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def __call__(self, url, **kwargs):
        self.calls.append(url)
        if url not in self.routes:
            raise RuntimeError(f"connection refused: {url}")
        return self.routes[url]


@pytest.fixture(autouse=True)
def fresh_hash_cache(monkeypatch):
    monkeypatch.setattr(feed, "_HASH_CACHE", {})


def install_http(monkeypatch, routes):
    fake = FakeHttp(routes)
    monkeypatch.setattr(feed, "http_get", fake)
    return fake


def word_routes(**overrides):
    values = dict(WORD_PLIST_VALUES, **overrides)
    return {
        MANIFEST: FakeResponse(plist(values), headers={"Content-Type": "text/xml"}),
        APP_PKG: FakeResponse(APP_PAYLOAD),
        FULL_PKG: FakeResponse(FULL_PAYLOAD),
    }


def cached_word(**overrides):
    data = dict(
        WORD_EXTRACTED,
        name="Word",
        app_update_sha1="cached-app-sha1",
        app_update_sha256="cached-app-sha256",
        full_update_sha1="cached-full-sha1",
        full_update_sha256="cached-full-sha256",
    )
    data.update(overrides)
    return {"Word": {"last_updated": data["last_updated"], "data": data}}


def package_dict(run, name):
    for package in run.root.findall("package"):
        if package.findtext("name") == name:
            return {child.tag: child.text for child in package}
    return None


def write_feed(path: Path, packages: list[dict]):
    root = ET.Element("latest")
    ET.SubElement(root, "last_updated").text = "January 01, 2026 09:00 AM EST"
    for values in packages:
        package = ET.SubElement(root, "package")
        for key, value in values.items():
            ET.SubElement(package, key).text = value
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(path, encoding="utf-8")


# --- read_existing_xml ----------------------------------------------------


def test_read_existing_xml_skips_only_the_malformed_package(tmp_path: Path, caplog):
    cache = tmp_path / "latest_raw_files" / "feed.xml"
    write_feed(
        cache,
        [
            {"name": "Excel", "short_version": "16.1"},  # no <last_updated>
            {"short_version": "16.2", "last_updated": "January 02, 2026"},  # no <name>
            {"name": "Word", "short_version": "16.3", "last_updated": "January 03, 2026"},
            {"name": "PowerPoint", "short_version": "16.4", "last_updated": "January 04, 2026"},
        ],
    )

    with caplog.at_level(logging.INFO):
        existing = feed.read_existing_xml(str(cache))

    assert sorted(existing) == ["PowerPoint", "Word"]
    assert existing["Word"]["data"]["short_version"] == "16.3"
    assert existing["Word"]["last_updated"] == "January 03, 2026"
    skipped = [record for record in caplog.records if "Skipping malformed cached package" in record.getMessage()]
    assert len(skipped) == 2
    assert all(record.levelno == logging.WARNING for record in skipped)


def test_read_existing_xml_tolerates_missing_or_unparseable_files(tmp_path: Path, caplog):
    broken = tmp_path / "broken.xml"
    broken.write_text("<latest><package>", encoding="utf-8")
    with caplog.at_level(logging.INFO):
        assert feed.read_existing_xml(str(tmp_path / "missing.xml")) == {}
        assert feed.read_existing_xml(str(broken)) == {}
    assert all(record.levelno < logging.ERROR for record in caplog.records)


def test_one_malformed_cached_package_does_not_drop_the_others(tmp_path: Path, monkeypatch, caplog):
    cache = tmp_path / "feed.xml"
    write_feed(
        cache,
        [
            {"name": "Excel", "short_version": "16.1"},  # malformed: no <last_updated>
            {"name": "Word", "short_version": "16.3", "last_updated": "January 03, 2026"},
        ],
    )
    install_http(monkeypatch, {})  # every fetch fails
    run = feed.FeedRun(feed.read_existing_xml(str(cache)), latest.FIELD_ORDER, "now")

    with caplog.at_level(logging.INFO):
        latest.fetch_and_process("Word", WORD_CONFIG, run)

    assert package_dict(run, "Word")["short_version"] == "16.3"
    assert all(record.levelno < logging.ERROR for record in caplog.records)


# --- manifest parsing -----------------------------------------------------


def test_process_xml_data_gives_na_for_missing_configured_keys():
    values = dict(WORD_PLIST_VALUES)
    del values["Title"]
    del values["Minimum OS"]
    app_data = ET.fromstring(plist(values)).find(".//dict")

    extracted = feed.process_xml_data(app_data, WORD_CONFIG)

    assert extracted["short_version"] == "N/A"
    assert extracted["min_os"] == "N/A"
    assert extracted["full_version"] == "16.90.24121212"
    assert extracted["last_updated"] == "January 31, 2026"


def test_find_key_value_searches_nested_dicts_and_arrays():
    root = ET.fromstring(
        b"<plist><array><dict><key>Other</key><string>x</string>"
        b"<key>Nested</key><array><dict><key>Title</key><string>Word 16.1</string></dict></array>"
        b"</dict></array></plist>"
    )
    assert feed.find_key_value(root.find(".//dict"), "Title") == "Word 16.1"
    assert feed.find_key_value(root.find(".//dict"), "Missing") == "N/A"


def test_process_json_data_gives_na_for_missing_keys_and_text_for_numbers():
    config = {
        "keys": {
            "short_version": "name",
            "full_version": "productVersion",
            "app_only_update_download": "url",
            "last_updated": "timestamp",
            "min_os": "Minimum OS",
            "build": "build",
        }
    }
    extracted = feed.process_json_data(
        {"name": "1.135.0", "url": "https://example.test/vscode.zip", "timestamp": 1769846400000, "build": 42},
        config,
    )
    assert extracted["short_version"] == "1.135.0"
    assert extracted["full_version"] == "N/A"
    assert extracted["min_os"] == "N/A"
    assert extracted["last_updated"] == "January 31, 2026"
    assert extracted["build"] == "42"


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("not a date", "N/A"),
        ("", "N/A"),
        ("N/A", "N/A"),
        (None, "N/A"),
        ("2026-01-31T08:00:00Z", "January 31, 2026"),
        ("2026-01-31", "January 31, 2026"),
        (1769846400000, "January 31, 2026"),
        ("1769846400000", "January 31, 2026"),
    ],
)
def test_convert_last_updated(value, expected):
    assert feed.convert_last_updated(value) == expected


def test_manifest_without_content_type_is_sniffed(monkeypatch):
    json_config = {"url": "https://example.test/api", "keys": {"short_version": "name", "last_updated": "timestamp"}}
    install_http(
        monkeypatch,
        {
            MANIFEST: FakeResponse(plist(WORD_PLIST_VALUES)),  # no Content-Type header
            "https://example.test/api": FakeResponse(b'  {"name": "1.2.3", "timestamp": "2026-01-31T00:00:00Z"}'),
        },
    )

    assert feed.fetch_update_data("Word", WORD_CONFIG)["short_version"] == "16.90"
    extracted = feed.fetch_update_data("Code", json_config)
    assert extracted == {"short_version": "1.2.3", "last_updated": "January 31, 2026"}


def test_declared_json_content_type_is_case_insensitive(monkeypatch):
    config = {"url": "https://example.test/api", "keys": {"short_version": "name"}}
    install_http(
        monkeypatch,
        {"https://example.test/api": FakeResponse(b'{"name": "1.2.3"}', headers={"Content-Type": "Application/JSON; charset=utf-8"})},
    )
    assert feed.fetch_update_data("Code", config)["short_version"] == "1.2.3"


def test_manifest_without_a_dict_is_a_fetch_failure(monkeypatch, caplog):
    install_http(monkeypatch, {MANIFEST: FakeResponse(b"<html><body>Maintenance</body></html>", headers={"Content-Type": "text/html"})})
    run = feed.FeedRun(cached_word(), latest.FIELD_ORDER, "now")

    with caplog.at_level(logging.INFO):
        latest.fetch_and_process("Word", WORD_CONFIG, run)

    assert package_dict(run, "Word")["full_update_sha1"] == "cached-full-sha1"
    assert "has no <dict> element" in caplog.text
    assert all(record.levelno < logging.ERROR for record in caplog.records)


# --- fetch_and_process success paths ---------------------------------------


def test_unchanged_app_reuses_cached_hashes_without_downloading(monkeypatch):
    http = install_http(monkeypatch, word_routes())

    def no_hashing(url):
        raise AssertionError(f"compute_hashes must not run for an unchanged app: {url}")

    monkeypatch.setattr(feed, "compute_hashes", no_hashing)
    run = feed.FeedRun(cached_word(), latest.FIELD_ORDER, "now")

    latest.fetch_and_process("Word", WORD_CONFIG, run)

    published = package_dict(run, "Word")
    assert published["app_update_sha1"] == "cached-app-sha1"
    assert published["full_update_sha256"] == "cached-full-sha256"
    assert http.calls == [MANIFEST]


def test_changed_version_downloads_and_hashes_each_installer_once(monkeypatch):
    http = install_http(monkeypatch, word_routes())
    run = feed.FeedRun(cached_word(short_version="16.89"), latest.FIELD_ORDER, "now")

    latest.fetch_and_process("Word", WORD_CONFIG, run)

    published = package_dict(run, "Word")
    assert published["short_version"] == "16.90"
    assert published["app_update_sha1"] == sha1(APP_PAYLOAD).hexdigest()
    assert published["app_update_sha256"] == sha256(APP_PAYLOAD).hexdigest()
    assert published["full_update_sha1"] == sha1(FULL_PAYLOAD).hexdigest()
    assert published["full_update_sha256"] == sha256(FULL_PAYLOAD).hexdigest()
    assert sorted(http.calls) == sorted([MANIFEST, APP_PKG, FULL_PKG])


def test_new_app_is_hashed_and_published_in_field_order(monkeypatch):
    install_http(monkeypatch, word_routes())
    run = feed.FeedRun({}, latest.FIELD_ORDER, "now")

    latest.fetch_and_process("Word", WORD_CONFIG, run)

    package = run.root.find("package")
    assert [child.tag for child in package] == latest.FIELD_ORDER
    assert package.findtext("full_update_sha256") == sha256(FULL_PAYLOAD).hexdigest()


def test_skip_sha_checks_publishes_na_hashes_without_downloading(monkeypatch):
    http = install_http(monkeypatch, word_routes())
    monkeypatch.setattr(latest, "skip_sha_checks", True)
    run = feed.FeedRun({}, latest.FIELD_ORDER, "now")

    latest.fetch_and_process("Word", WORD_CONFIG, run)

    published = package_dict(run, "Word")
    for key in ("app_update_sha1", "app_update_sha256", "full_update_sha1", "full_update_sha256"):
        assert published[key] == "N/A"
    assert http.calls == [MANIFEST]


def test_onedrive_and_copilot_special_cases(monkeypatch):
    copilot_manifest = "https://officecdn.example/MacAutoupdate/0409MSCP10.xml"
    install_http(
        monkeypatch,
        {
            MANIFEST: FakeResponse(plist(WORD_PLIST_VALUES)),
            copilot_manifest: FakeResponse(plist({"Title": "365 - 1.2.3"})),
        },
    )
    run = feed.FeedRun({}, preview.FIELD_ORDER, "February 01, 2026 09:00 AM EST")

    preview.fetch_and_process("OneDrive", dict(WORD_CONFIG), run)
    preview.fetch_and_process("Copilot", {"url": copilot_manifest, "manual_entries": {}, "keys": {"short_version": "Title"}}, run)

    assert package_dict(run, "OneDrive")["last_updated"] == "February 01, 2026 09:00 AM EST"
    assert package_dict(run, "Copilot")["short_version"] == "1.2.3"


# --- beta App Center path -------------------------------------------------

APPCENTER_BASE = "https://install.appcenter.example/api/v0.1/apps/owner/app/distribution_groups/all"
APPCENTER_CONFIG = {
    "type": "appcenter",
    "base": APPCENTER_BASE,
    "manual_entries": {"CFBundleVersion": "com.microsoft.windows.app", "application_id": "N/A", "min_os": "N/A"},
    "keys": {
        "short_version": "short_version",
        "full_version": "short_version",
        "last_updated": "uploaded_at",
        "update_download": "download_url",
        "latest_download": "download_url",
    },
}


def appcenter_routes(download_url="https://appcenter.example/windowsapp-11.2.zip"):
    return {
        f"{APPCENTER_BASE}/public_releases": FakeResponse(payload=[{"id": 7}, {"id": 6}]),
        f"{APPCENTER_BASE}/releases/7": FakeResponse(
            payload={"short_version": "11.2.0", "uploaded_at": "2026-01-31T10:00:00Z", "download_url": download_url}
        ),
        download_url: FakeResponse(b"windows-app-zip"),
    }


def test_beta_appcenter_new_app_is_hashed(monkeypatch):
    install_http(monkeypatch, appcenter_routes())
    run = feed.FeedRun({}, beta.FIELD_ORDER, "now")

    beta.fetch_and_process("Windows App Beta", APPCENTER_CONFIG, run)

    published = package_dict(run, "Windows App Beta")
    assert published["short_version"] == "11.2.0"
    assert published["last_updated"] == "January 31, 2026"
    assert published["sha256"] == sha256(b"windows-app-zip").hexdigest()


def test_beta_appcenter_compares_only_short_version(monkeypatch):
    # A new signed download URL alone is not an update.
    http = install_http(monkeypatch, appcenter_routes(download_url="https://appcenter.example/new-token.zip"))
    cached = {
        "Windows App Beta": {
            "last_updated": "January 30, 2026",
            "data": {"name": "Windows App Beta", "short_version": "11.2.0", "latest_download": "old", "sha1": "s1", "sha256": "s256"},
        }
    }
    run = feed.FeedRun(cached, beta.FIELD_ORDER, "now")

    beta.fetch_and_process("Windows App Beta", APPCENTER_CONFIG, run)

    assert package_dict(run, "Windows App Beta")["sha256"] == "s256"
    assert "https://appcenter.example/new-token.zip" not in http.calls


def test_beta_appcenter_without_releases_keeps_cache_or_fails(monkeypatch, caplog):
    routes = {f"{APPCENTER_BASE}/public_releases": FakeResponse(payload=[])}
    install_http(monkeypatch, routes)
    with caplog.at_level(logging.INFO):
        run = feed.FeedRun({}, beta.FIELD_ORDER, "now")
        beta.fetch_and_process("Windows App Beta", APPCENTER_CONFIG, run)
    assert run.root.findall("package") == []
    assert any(record.levelno == logging.ERROR for record in caplog.records)


# --- end to end -----------------------------------------------------------


@pytest.mark.parametrize("generator", (latest, preview, beta), ids=lambda module: module.__name__)
def test_main_writes_matching_xml_yaml_and_json(tmp_path: Path, monkeypatch, caplog, generator):
    output = tmp_path / "latest_raw_files" / "feed.xml"
    write_feed(output, [{"name": "Stale", "short_version": "1", "last_updated": "January 01, 2025"}])
    config = dict(WORD_CONFIG)
    if generator is not latest:
        config["keys"] = dict(WORD_CONFIG["keys"], latest_download="FullUpdaterLocation", update_download="FullUpdaterLocation")
    monkeypatch.setattr(generator, "apps", {"Word": config, "Missing": dict(WORD_CONFIG, url="https://down.example/x.xml")})
    install_http(monkeypatch, word_routes())

    with caplog.at_level(logging.INFO):
        assert generator.main(output_file=str(output)) == 0

    root = ET.parse(output).getroot()
    assert [p.findtext("name") for p in root.findall("package")] == ["Word"]
    data = json.loads(output.with_suffix(".json").read_text(encoding="utf-8"))
    assert yaml.safe_load(output.with_suffix(".yaml").read_text(encoding="utf-8")) == data
    assert data["last_updated"] == root.findtext("last_updated")
    assert list(data["packages"][0]) == generator.FIELD_ORDER
    assert data["packages"][0]["short_version"] == "16.90"
    # "Missing" has no cached entry, so dropping it must fail run_generators.py.
    assert any(
        record.levelno == logging.ERROR and "Missing" in record.getMessage() for record in caplog.records
    )
