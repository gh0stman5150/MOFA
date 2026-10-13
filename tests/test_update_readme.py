"""Fixture tests for update_readme.py, rendered into tmp_path."""

from __future__ import annotations

import ast
import logging
import re
import xml.etree.ElementTree as ET
from hashlib import sha256
from pathlib import Path

import pytest

import update_readme

ACTIONS = Path(update_readme.__file__).resolve().parent

# Every standalone package name the README template renders.
STANDALONE_NAMES = (
    "Microsoft Office Suite",
    "Microsoft BusinessPro Suite",
    "Word",
    "Excel",
    "PowerPoint",
    "Outlook",
    "OneNote",
    "Skype",
    "Teams",
    "Intune",
    "Defender For Endpoint",
    "Defender For Consumers",
    "Defender Shim",
    "Windows App",
    "Visual",
    "Copilot",
    "MAU",
    "Licensing Helper Tool",
    "Quick Assist",
    "Remote Help",
)


def slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def digest(text: str) -> str:
    return sha256(text.encode()).hexdigest()


def standalone_values(index: int, name: str) -> dict[str, str]:
    s = slug(name)
    return {
        "name": name,
        "application_id": f"APP{index:02d}",
        "application_name": f"{name}.app",
        "CFBundleVersion": f"com.example.{s}",
        "short_version": f"16.{index}",
        "full_version": f"16.{index}.26010100",
        "last_updated": f"January {index + 1:02d}, 2026 01:00 AM EST",
        "min_os": "14.0",
        "app_only_update_download": f"https://download.example/{s}/app.pkg",
        "app_update_sha1": f"{index:040x}",
        "app_update_sha256": digest(f"{s}-app"),
        "full_update_download": f"https://download.example/{s}/full.pkg",
        "full_update_sha1": f"{index + 100:040x}",
        "full_update_sha256": digest(f"{s}-full"),
    }


def write_xml(path: Path, root: ET.Element) -> None:
    path.write_bytes(ET.tostring(root, encoding="utf-8"))


def add_children(parent: ET.Element, tag: str, values: dict[str, str]) -> ET.Element:
    element = ET.SubElement(parent, tag)
    for key, value in values.items():
        ET.SubElement(element, key).text = value
    return element


ONEDRIVE_RINGS = {
    "Production Ring": "https://oneclient.example/Installers/26.1.1.0001/universal/OneDrive.pkg",
    "App New Version (Unknown Use)": "https://go.example/fwlink/onedrive-new",
}
EDGE_CURRENT = "https://edge.example/files/MicrosoftEdge-200.0.1.2.pkg"


def build_feeds(root: Path, *, standalone=None) -> Path:
    data = root / "latest_raw_files"
    data.mkdir(parents=True)

    latest = ET.Element("latest")
    ET.SubElement(latest, "last_updated").text = "February 01, 2026 09:00 AM EST"
    packages = standalone if standalone is not None else [
        standalone_values(i, name) for i, name in enumerate(STANDALONE_NAMES)
    ]
    for values in packages:
        add_children(latest, "package", values)
    write_xml(data / "macos_standalone_latest.xml", latest)

    for prefix, filename in (("iOS", "ios_appstore_latest.xml"), ("MacOS", "macos_appstore_latest.xml")):
        store = ET.Element("latest")
        ET.SubElement(store, "last_updated").text = f"{prefix} store timestamp"
        add_children(
            store,
            "package",
            {
                "name": f"{prefix} Microsoft Word",
                "application_name": "Microsoft Word",
                "bundleId": f"com.example.{prefix.lower()}.word",
                "currentVersionReleaseDate": "2026-01-01",
                "icon_image": "https://icons.example/word.png",
                "minimumOsVersion": "17.0",
                "releaseNotes": "Bug fixes",
                "version": "2.100",
            },
        )
        write_xml(data / filename, store)

    onedrive = ET.Element("latest")
    ET.SubElement(onedrive, "last_updated").text = "OneDrive timestamp"
    for index, (ring, url) in enumerate(ONEDRIVE_RINGS.items()):
        add_children(
            onedrive,
            "package",
            {
                "name": ring,
                "short_version": f"26.{index}.1",
                "application_id": "ONDR18",
                "application_name": "OneDrive.app",
                "CFBundleVersion": "com.microsoft.onedrive",
                "full_update_download": url,
                "full_update_sha1": f"{index + 200:040x}",
                "full_update_sha256": digest(f"onedrive-{index}"),
                "last_updated": f"OneDrive ring {index} timestamp",
            },
        )
    write_xml(data / "macos_standalone_onedrive_all.xml", onedrive)

    edge = ET.Element("EdgeInsiderVersions")
    ET.SubElement(edge, "last_updated").text = "Edge timestamp"
    for channel, url in (("beta", "https://edge.example/beta.pkg"), ("current", EDGE_CURRENT)):
        add_children(
            edge,
            "Version",
            {
                "Name": channel,
                "Version": f"200.0.1.{len(channel)}",
                "Application_ID": "EDGE01",
                "Application_Name": "Microsoft Edge.app",
                "CFBundleVersion": "com.microsoft.edgemac",
                "Full_Update_Download": url,
                "Full_Update_Sha1": f"{len(channel):040x}",
                "Full_Update_Sha256": digest(f"edge-{channel}"),
                "Last_Update": f"Edge {channel} date",
            },
        )
    write_xml(data / "macos_standalone_edge_all.xml", edge)
    return data


def expected_link_hashes() -> dict[str, str]:
    """Map every published download URL to the SHA256 of that download."""
    mapping = {}
    for index, name in enumerate(STANDALONE_NAMES):
        values = standalone_values(index, name)
        mapping[values["full_update_download"]] = values["full_update_sha256"]
        mapping[values["app_only_update_download"]] = values["app_update_sha256"]
    for index, url in enumerate(ONEDRIVE_RINGS.values()):
        mapping[url] = digest(f"onedrive-{index}")
    mapping[EDGE_CURRENT] = digest("edge-current")
    return mapping


def sha256_table_rows(readme: str):
    section = readme.split("### SHA256 Information Table", 1)[1].split("\n\n<sup>", 1)[0]
    rows = re.findall(r'^\| \*\*(.+?)\*\* \| <a href="([^"]+)">.*?\| `([^`]*)` \|$', section, re.M)
    assert len(rows) == 29
    return rows


def render(tmp_path: Path) -> str:
    assert update_readme.main(tmp_path) == 0
    return (tmp_path / "README.md").read_text(encoding="utf-8")


def test_parse_latest_xml_fixture(tmp_path: Path):
    data = build_feeds(tmp_path)
    last_updated, packages = update_readme.parse_latest_xml(data / "macos_standalone_latest.xml")
    assert last_updated == "February 01, 2026 09:00 AM EST"
    word = standalone_values(STANDALONE_NAMES.index("Word"), "Word")
    assert packages["word"]["short_version"] == word["short_version"]
    assert packages["word"]["full_update_sha256"] == word["full_update_sha256"]
    assert packages["word"]["min_os"] == "14.0"


def test_empty_or_missing_fields_render_na_instead_of_crashing(tmp_path: Path):
    word = standalone_values(0, "Word")
    word["min_os"] = ""
    del word["full_version"]
    data = build_feeds(tmp_path, standalone=[word])
    _, packages = update_readme.parse_latest_xml(data / "macos_standalone_latest.xml")
    assert packages["word"]["min_os"] == "N/A"
    assert packages["word"]["full_version"] == "N/A"


def test_rendered_readme_has_values_and_no_none(tmp_path: Path):
    build_feeds(tmp_path)
    readme = render(tmp_path)
    word = standalone_values(STANDALONE_NAMES.index("Word"), "Word")
    assert f"`{word['short_version']}`" in readme
    assert word["full_update_sha256"] in readme
    assert "February 01, 2026 09:00 AM EST" in readme
    assert "iOS store timestamp" in readme and "MacOS store timestamp" in readme
    assert "None" not in readme
    assert "`N/A`" not in readme


def test_every_sha256_row_links_the_download_it_hashes(tmp_path: Path):
    build_feeds(tmp_path)
    readme = render(tmp_path)
    mapping = expected_link_hashes()
    for label, href, shown_hash in sha256_table_rows(readme):
        assert href in mapping, f"{label} links {href}, which is not a feed download"
        assert mapping[href] == shown_hash, f"{label} shows a hash for a different download"


def test_standalone_links_come_from_the_feed(tmp_path: Path):
    build_feeds(tmp_path)
    readme = render(tmp_path)
    assert "go.microsoft.com/fwlink" not in readme
    outlook = standalone_values(STANDALONE_NAMES.index("Outlook"), "Outlook")
    assert f'<a href="{outlook["full_update_download"]}">' in readme
    assert f'<a href="{ONEDRIVE_RINGS["Production Ring"]}">' in readme
    assert ONEDRIVE_RINGS["App New Version (Unknown Use)"] not in readme
    assert f'<a href="{EDGE_CURRENT}">' in readme


def test_missing_standalone_package_renders_na(tmp_path: Path):
    packages = [standalone_values(i, name) for i, name in enumerate(STANDALONE_NAMES) if name != "Copilot"]
    build_feeds(tmp_path, standalone=packages)
    readme = render(tmp_path)
    assert "None" not in readme
    assert "`N/A`" in readme


def break_edge_unparseable(data: Path):
    (data / "macos_standalone_edge_all.xml").write_text("<EdgeInsiderVersions><Version>", encoding="utf-8")


def break_edge_without_current(data: Path):
    root = ET.parse(data / "macos_standalone_edge_all.xml").getroot()
    for version in root.findall("Version"):
        if version.findtext("Name") == "current":
            root.remove(version)
    write_xml(data / "macos_standalone_edge_all.xml", root)


def break_onedrive_unparseable(data: Path):
    (data / "macos_standalone_onedrive_all.xml").write_text("not xml", encoding="utf-8")


def break_onedrive_without_production(data: Path):
    root = ET.parse(data / "macos_standalone_onedrive_all.xml").getroot()
    for package in root.findall("package"):
        if package.findtext("name") == "Production Ring":
            root.remove(package)
    write_xml(data / "macos_standalone_onedrive_all.xml", root)


def break_onedrive_missing(data: Path):
    (data / "macos_standalone_onedrive_all.xml").unlink()


def break_standalone_unparseable(data: Path):
    (data / "macos_standalone_latest.xml").write_text("<latest>", encoding="utf-8")


@pytest.mark.parametrize(
    "breaker",
    [
        break_edge_unparseable,
        break_edge_without_current,
        break_onedrive_unparseable,
        break_onedrive_without_production,
        break_onedrive_missing,
        break_standalone_unparseable,
    ],
)
def test_unusable_feed_is_fatal_and_leaves_readme_untouched(tmp_path: Path, caplog, breaker):
    data = build_feeds(tmp_path)
    breaker(data)
    readme = tmp_path / "README.md"
    readme.write_text("previous README\n", encoding="utf-8")

    with caplog.at_level(logging.INFO):
        assert update_readme.main(tmp_path) == 1

    assert readme.read_text(encoding="utf-8") == "previous README\n"
    assert any(record.levelno == logging.ERROR for record in caplog.records)


def test_readme_is_written_as_utf8(tmp_path: Path):
    target = tmp_path / "README.md"
    update_readme.overwrite_readme(target, "MOFA ⭐ — \U0001f310\n")
    assert target.read_bytes() == "MOFA ⭐ — \U0001f310\n".encode("utf-8")


@pytest.mark.parametrize(
    "script",
    ["update_readme.py", "generate_edge_all.py", "generate_onedrive_all.py", "generate_macos_standalone_cve_history.py"],
)
def test_text_files_are_opened_with_explicit_encoding(script):
    tree = ast.parse((ACTIONS / script).read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "open"):
            continue
        mode = node.args[1].value if len(node.args) > 1 and isinstance(node.args[1], ast.Constant) else "r"
        for keyword in node.keywords:
            if keyword.arg == "mode" and isinstance(keyword.value, ast.Constant):
                mode = keyword.value.value
        if "b" in mode:
            continue
        assert any(keyword.arg == "encoding" for keyword in node.keywords), (
            f"{script}:{node.lineno} opens a text file without encoding="
        )
