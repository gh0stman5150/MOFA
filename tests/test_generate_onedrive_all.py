"""Fixture tests for generate_onedrive_all.py. All HTTP is faked."""

from __future__ import annotations

import logging
import xml.etree.ElementTree as ET
from hashlib import sha1, sha256
from pathlib import Path

import pytest

import generate_onedrive_all as onedrive

FWLINK = "https://go.microsoft.com/fwlink/?linkid=900001"
INSTALLER = "https://oneclient.sfx.ms/Mac/Installers/26.200.1010.0004/universal/OneDrive.pkg"
MANIFEST = "https://g.live.example/StandaloneProductManifest"
PAYLOAD = b"synthetic-onedrive-installer-bytes"

MANIFEST_XML = f"""<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><array><dict>
  <key>CFBundleShortVersionString</key><string>26.200.1010</string>
  <key>UniversalPkgBinaryURL</key><string>{INSTALLER}</string>
</dict></array></plist>""".encode()

MANIFEST_WITHOUT_BINARY = b"""<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><array><dict>
  <key>CFBundleShortVersionString</key><string>26.200.1010</string>
</dict></array></plist>"""


class FakeResponse:
    def __init__(self, url, *, status=200, content=b"", history=(), headers=None):
        self.url = url
        self.status_code = status
        self.content = content
        self.history = list(history)
        self.headers = headers or {}
        self.closed = False
        self.body_read = False

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code} for {self.url}")

    def iter_content(self, chunk_size):
        self.body_read = True
        for start in range(0, len(self.content), 5):
            yield self.content[start : start + 5]

    def close(self):
        self.closed = True


class FakeHttp:
    """Route fake GETs by URL and record every call."""

    def __init__(self, routes):
        self.routes = routes
        self.calls = []
        self.responses = []

    def __call__(self, url, **kwargs):
        self.calls.append(url)
        route = self.routes.get(url)
        if route is None:
            raise RuntimeError(f"connection refused: {url}")
        response = route() if callable(route) else route
        self.responses.append(response)
        return response


def redirect_to(final_url, content=PAYLOAD):
    hop = FakeResponse(FWLINK, status=302, headers={"Location": final_url})
    return lambda: FakeResponse(final_url, content=content, history=[hop])


@pytest.fixture(autouse=True)
def clear_caches():
    onedrive._MANIFEST_CACHE.clear()
    onedrive._HASH_CACHE.clear()
    yield
    onedrive._MANIFEST_CACHE.clear()
    onedrive._HASH_CACHE.clear()


def use_rings(monkeypatch, linkid=(), manifest=()):
    monkeypatch.setattr(onedrive, "LINKID_RINGS", tuple(linkid))
    monkeypatch.setattr(onedrive, "MANIFEST_RINGS", tuple(manifest))


def manifest_ring(name):
    return {
        "name": name,
        "url": MANIFEST,
        "version_key": "CFBundleShortVersionString",
        "binary_url_key": "UniversalPkgBinaryURL",
    }


def cached_entry(version="26.100.0101", download=FWLINK):
    return {
        "short_version": version,
        "last_updated": "January 01, 2026 01:00 AM EST",
        "full_update_download": download,
        "full_update_sha1": "cached-sha1",
        "full_update_sha256": "cached-sha256",
    }


def no_errors(caplog):
    return all(record.levelno < logging.ERROR for record in caplog.records)


def test_parse_installer_version():
    assert onedrive.parse_installer_version(INSTALLER) == "26.200.1010"
    assert (
        onedrive.parse_installer_version("https://oneclient.sfx.ms/Mac/Installers/26.1.2/OneDrive.pkg")
        == "26.1.2"
    )
    assert onedrive.parse_installer_version("https://cdn.example/other/OneDrive.pkg") is None
    assert onedrive.parse_installer_version(None) is None


def test_resolve_reads_version_from_final_url_without_downloading(monkeypatch):
    http = FakeHttp({FWLINK: redirect_to(INSTALLER)})
    monkeypatch.setattr(onedrive, "http_get", http)

    assert onedrive.resolve_linked_package(FWLINK) == ("26.200.1010", INSTALLER)
    response = http.responses[0]
    assert response.closed and not response.body_read


def test_resolve_uses_redirect_location_and_returns_a_single_version(monkeypatch):
    # Two hops: the version is only in the first Location; the final CDN URL
    # has no version. curl -I | grep location used to emit one line per hop.
    hop1 = FakeResponse(FWLINK, status=302, headers={"Location": "/Mac/Installers/26.200.1010.0004/OneDrive.pkg"})
    hop1.url = "https://oneclient.sfx.ms/start"
    hop2 = FakeResponse("https://oneclient.sfx.ms/Mac/Installers/26.200.1010.0004/OneDrive.pkg", status=302,
                        headers={"Location": "https://edge.cdn.example/blob/abc"})
    final = FakeResponse("https://edge.cdn.example/blob/abc", history=[hop1, hop2])
    monkeypatch.setattr(onedrive, "http_get", FakeHttp({FWLINK: final}))

    version, installer_url = onedrive.resolve_linked_package(FWLINK)
    assert version == "26.200.1010"
    assert "\n" not in version
    assert installer_url == "https://oneclient.sfx.ms/Mac/Installers/26.200.1010.0004/OneDrive.pkg"


@pytest.mark.parametrize(
    "routes",
    [
        {},  # connection failure
        {FWLINK: FakeResponse(FWLINK, status=404)},
        {FWLINK: FakeResponse("https://cdn.example/unversioned/OneDrive.pkg")},
    ],
)
def test_resolve_failure_returns_none_and_warns(monkeypatch, caplog, routes):
    monkeypatch.setattr(onedrive, "http_get", FakeHttp(routes))
    with caplog.at_level(logging.INFO):
        assert onedrive.resolve_linked_package(FWLINK) == (None, None)
    assert any(record.levelno == logging.WARNING for record in caplog.records)
    assert no_errors(caplog)


def test_failed_version_lookup_keeps_cached_entry(monkeypatch, caplog):
    use_rings(monkeypatch, linkid=[{"name": "Deferred Ring", "url": FWLINK}])
    monkeypatch.setattr(onedrive, "http_get", FakeHttp({}))
    existing = {"Deferred Ring": cached_entry()}

    with caplog.at_level(logging.INFO):
        packages = onedrive.fetch_package_data(existing)

    assert packages == [{"name": "Deferred Ring", "version_changed": False, **existing["Deferred Ring"]}]
    assert no_errors(caplog)
    xml = onedrive.generate_package_xml(packages[0], existing, "now")
    assert xml.findtext("short_version") == "26.100.0101"
    assert xml.findtext("full_update_sha256") == "cached-sha256"
    assert xml.findtext("last_updated") == "January 01, 2026 01:00 AM EST"


def test_failed_version_lookup_without_cache_logs_error(monkeypatch, caplog):
    use_rings(monkeypatch, linkid=[{"name": "Deferred Ring", "url": FWLINK}])
    monkeypatch.setattr(onedrive, "http_get", FakeHttp({}))
    with caplog.at_level(logging.INFO):
        assert onedrive.fetch_package_data({}) == []
    assert any(record.levelno == logging.ERROR for record in caplog.records)


def test_changed_fwlink_version_hashes_resolved_installer_once(monkeypatch, caplog):
    use_rings(monkeypatch, linkid=[{"name": "Deferred Ring", "url": FWLINK}])
    http = FakeHttp({FWLINK: redirect_to(INSTALLER), INSTALLER: lambda: FakeResponse(INSTALLER, content=PAYLOAD)})
    monkeypatch.setattr(onedrive, "http_get", http)

    with caplog.at_level(logging.INFO):
        packages = onedrive.fetch_package_data({"Deferred Ring": cached_entry()})

    assert packages == [
        {
            "name": "Deferred Ring",
            "short_version": "26.200.1010",
            "full_update_download": FWLINK,
            "full_update_sha1": sha1(PAYLOAD).hexdigest(),
            "full_update_sha256": sha256(PAYLOAD).hexdigest(),
            "version_changed": True,
        }
    ]
    # One header-only resolve of the fwlink, then one streamed download of
    # the resolved installer for both digests.
    assert http.calls == [FWLINK, INSTALLER]
    assert no_errors(caplog)


def test_unchanged_version_reuses_cache_without_download(monkeypatch):
    use_rings(monkeypatch, linkid=[{"name": "Deferred Ring", "url": FWLINK}])
    http = FakeHttp({FWLINK: redirect_to(INSTALLER)})
    monkeypatch.setattr(onedrive, "http_get", http)
    existing = {"Deferred Ring": cached_entry(version="26.200.1010")}

    packages = onedrive.fetch_package_data(existing)

    assert packages[0]["version_changed"] is False
    assert http.calls == [FWLINK]


def test_cached_na_hashes_are_retried(monkeypatch):
    use_rings(monkeypatch, linkid=[{"name": "Deferred Ring", "url": FWLINK}])
    http = FakeHttp({FWLINK: redirect_to(INSTALLER), INSTALLER: lambda: FakeResponse(INSTALLER, content=PAYLOAD)})
    monkeypatch.setattr(onedrive, "http_get", http)
    entry = cached_entry(version="26.200.1010")
    entry["full_update_sha256"] = "N/A"

    packages = onedrive.fetch_package_data({"Deferred Ring": entry})

    assert packages[0]["full_update_sha256"] == sha256(PAYLOAD).hexdigest()
    assert packages[0]["version_changed"] is True


def test_hash_failure_keeps_cached_entry(monkeypatch, caplog):
    use_rings(monkeypatch, linkid=[{"name": "Deferred Ring", "url": FWLINK}])
    http = FakeHttp({FWLINK: redirect_to(INSTALLER), INSTALLER: lambda: FakeResponse(INSTALLER, status=503)})
    monkeypatch.setattr(onedrive, "http_get", http)
    existing = {"Deferred Ring": cached_entry()}

    with caplog.at_level(logging.INFO):
        packages = onedrive.fetch_package_data(existing)

    assert packages[0]["version_changed"] is False
    assert packages[0]["short_version"] == "26.100.0101"
    assert no_errors(caplog)


def test_missing_binary_url_falls_back_to_cache(monkeypatch, caplog):
    use_rings(monkeypatch, manifest=[manifest_ring("Production Ring")])
    monkeypatch.setattr(
        onedrive, "http_get", FakeHttp({MANIFEST: FakeResponse(MANIFEST, content=MANIFEST_WITHOUT_BINARY)})
    )
    existing = {"Production Ring": cached_entry(download=INSTALLER)}

    with caplog.at_level(logging.INFO):
        packages = onedrive.fetch_package_data(existing)

    assert [package["name"] for package in packages] == ["Production Ring"]
    assert packages[0]["version_changed"] is False
    assert no_errors(caplog)


def test_missing_binary_url_without_cache_logs_error(monkeypatch, caplog):
    use_rings(monkeypatch, manifest=[manifest_ring("Production Ring")])
    monkeypatch.setattr(
        onedrive, "http_get", FakeHttp({MANIFEST: FakeResponse(MANIFEST, content=MANIFEST_WITHOUT_BINARY)})
    )
    with caplog.at_level(logging.INFO):
        assert onedrive.fetch_package_data({}) == []
    assert any(record.levelno == logging.ERROR for record in caplog.records)


def test_rings_sharing_a_manifest_fetch_and_hash_once(monkeypatch):
    use_rings(
        monkeypatch,
        manifest=[manifest_ring("Upcoming Production Ring"), manifest_ring("Production Ring")],
    )
    http = FakeHttp(
        {
            MANIFEST: lambda: FakeResponse(MANIFEST, content=MANIFEST_XML),
            INSTALLER: lambda: FakeResponse(INSTALLER, content=PAYLOAD),
        }
    )
    monkeypatch.setattr(onedrive, "http_get", http)

    packages = onedrive.fetch_package_data({})

    assert [package["name"] for package in packages] == ["Upcoming Production Ring", "Production Ring"]
    for package in packages:
        assert package["short_version"] == "26.200.1010"
        assert package["full_update_download"] == INSTALLER
        assert package["full_update_sha256"] == sha256(PAYLOAD).hexdigest()
    assert http.calls == [MANIFEST, INSTALLER]


def test_extract_from_xml_handles_missing_key():
    manifest = ET.fromstring(MANIFEST_XML)
    assert onedrive.extract_from_xml(manifest, "UniversalPkgBinaryURL") == INSTALLER
    assert onedrive.extract_from_xml(manifest, "NoSuchKey") is None
    assert onedrive.extract_from_xml(None, "UniversalPkgBinaryURL") is None


def test_has_version_changed():
    existing = {"Deferred Ring": cached_entry(version="1.2.3")}
    assert onedrive.has_version_changed("Deferred Ring", "1.2.3", existing) is False
    assert onedrive.has_version_changed("Deferred Ring", "1.2.4", existing) is True
    assert onedrive.has_version_changed("Insider Ring", "1.2.3", existing) is True


def test_load_existing_data_missing_and_corrupt(tmp_path: Path):
    assert onedrive.load_existing_data(str(tmp_path / "missing.xml")) == {}
    corrupt = tmp_path / "corrupt.xml"
    corrupt.write_text("<latest><package>", encoding="utf-8")
    assert onedrive.load_existing_data(str(corrupt)) == {}


def test_main_keeps_cached_feed_when_every_lookup_fails(monkeypatch, tmp_path: Path, caplog):
    use_rings(
        monkeypatch,
        linkid=[{"name": "Deferred Ring", "url": FWLINK}],
        manifest=[manifest_ring("Production Ring")],
    )
    output = tmp_path / "macos_standalone_onedrive_all.xml"
    root = ET.Element("latest")
    ET.SubElement(root, "last_updated").text = "old"
    for name, entry in (("Production Ring", cached_entry("26.1.1", INSTALLER)), ("Deferred Ring", cached_entry())):
        package = onedrive.generate_package_xml({"name": name, "version_changed": False}, {name: entry}, "unused")
        root.append(package)
    output.write_bytes(ET.tostring(root, encoding="utf-8"))
    monkeypatch.setattr(onedrive, "http_get", FakeHttp({}))

    with caplog.at_level(logging.INFO):
        assert onedrive.main(str(output)) == 0

    written = ET.parse(output).getroot()
    versions = {p.findtext("name"): p.findtext("short_version") for p in written.findall("package")}
    assert versions == {"Production Ring": "26.1.1", "Deferred Ring": "26.100.0101"}
    assert "N/A" not in output.read_text(encoding="utf-8")
    assert (tmp_path / "macos_standalone_onedrive_all.json").exists()
    assert (tmp_path / "macos_standalone_onedrive_all.yaml").exists()
    assert no_errors(caplog)


def test_main_refuses_to_write_an_empty_feed(monkeypatch, tmp_path: Path, caplog):
    use_rings(monkeypatch, linkid=[{"name": "Deferred Ring", "url": FWLINK}])
    monkeypatch.setattr(onedrive, "http_get", FakeHttp({}))
    output = tmp_path / "macos_standalone_onedrive_all.xml"

    with caplog.at_level(logging.INFO):
        assert onedrive.main(str(output)) == 1

    assert not output.exists()
    assert any(record.levelno == logging.ERROR for record in caplog.records)


def test_generator_does_not_shell_out():
    source = (Path(onedrive.__file__)).read_text(encoding="utf-8")
    assert "subprocess" not in source
    assert "curl" not in source
