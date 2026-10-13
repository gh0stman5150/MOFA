"""Fixture tests for generate_macos_standalone_rss.py. No network access is involved."""

from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

import generate_macos_standalone_rss as rss

WORD_CONF = next(pkg for pkg in rss.PACKAGES if pkg["name"] == "Word")
MAU_CONF = next(pkg for pkg in rss.PACKAGES if pkg["name"] == "MAU")


def write_latest(path: Path, packages):
    root = ET.Element("latest")
    ET.SubElement(root, "last_updated").text = "February 01, 2026 09:00 AM EST"
    for name, version, download, updated in packages:
        package = ET.SubElement(root, "package")
        ET.SubElement(package, "name").text = name
        ET.SubElement(package, "short_version").text = version
        ET.SubElement(package, "app_only_update_download").text = download
        ET.SubElement(package, "last_updated").text = updated
    ET.ElementTree(root).write(path, encoding="utf-8")


def items(feed_path: Path):
    channel = ET.parse(feed_path).getroot().find("channel")
    return [
        {child.tag: child.text for child in item}
        for item in channel.findall("item")
    ]


def test_every_package_has_its_own_description_name():
    names = [rss._description_name(pkg) for pkg in rss.PACKAGES]
    assert len(set(names)) == len(rss.PACKAGES)
    assert rss._description_name(MAU_CONF) == "Microsoft AutoUpdate"
    assert rss._description_name(WORD_CONF) == "Microsoft Word"


def test_new_item_description_names_the_package(tmp_path: Path):
    latest = tmp_path / "latest.xml"
    feeds = tmp_path / "rss"
    write_latest(
        latest,
        [
            ("Word", "16.105 (26011018)", "https://cdn.example/word.pkg", "January 13, 2026"),
            ("MAU", "4.80 (26011013)", "https://cdn.example/mau.pkg", "January 13, 2026"),
        ],
    )

    assert rss.main(latest_xml_path=str(latest), feeds_dir=str(feeds)) == 0

    word = items(feeds / WORD_CONF["feed_filename"])
    assert len(word) == 1
    assert word[0]["description"].startswith("Microsoft Word<br>Version: 16.105 (26011018)<br>")
    assert "Microsoft AutoUpdate" not in word[0]["description"]
    assert word[0]["guid"] == "https://cdn.example/word.pkg"
    mau = items(feeds / MAU_CONF["feed_filename"])
    assert mau[0]["description"].startswith("Microsoft AutoUpdate<br>Version: 4.80 (26011013)<br>")
    # Packages missing from latest.xml get no feed file.
    assert sorted(path.name for path in feeds.iterdir()) == sorted(
        [WORD_CONF["feed_filename"], MAU_CONF["feed_filename"]]
    )


def test_existing_items_lose_the_legacy_autoupdate_label(tmp_path: Path):
    latest = tmp_path / "latest.xml"
    feeds = tmp_path / "rss"
    feeds.mkdir()
    legacy = (
        "Microsoft AutoUpdate<br>Version: {}<br>Release Notes: "
        '<a href="https://learn.example/notes">Release Notes</a>'
    )
    rss_root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss_root, "channel")
    for version in ("16.104 (25120910)", "16.103 (25111110)"):
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = WORD_CONF["item_title"]
        ET.SubElement(item, "description").text = legacy.format(version)
    ET.ElementTree(rss_root).write(feeds / WORD_CONF["feed_filename"], encoding="UTF-8", xml_declaration=True)
    write_latest(latest, [("Word", "16.105 (26011018)", "https://cdn.example/word.pkg", "January 13, 2026")])

    rss.main(latest_xml_path=str(latest), feeds_dir=str(feeds))

    descriptions = [item["description"] for item in items(feeds / WORD_CONF["feed_filename"])]
    assert len(descriptions) == 3
    assert all(text.startswith("Microsoft Word<br>Version: ") for text in descriptions)
    assert "Version: 16.103 (25111110)" in descriptions[2]
    assert '<a href="https://learn.example/notes">' in descriptions[2]


def test_rerun_with_same_version_does_not_add_an_item(tmp_path: Path):
    latest = tmp_path / "latest.xml"
    feeds = tmp_path / "rss"
    write_latest(latest, [("Word", "16.105 (26011018)", "https://cdn.example/word.pkg", "January 13, 2026")])

    rss.main(latest_xml_path=str(latest), feeds_dir=str(feeds))
    first = (feeds / WORD_CONF["feed_filename"]).read_bytes()
    rss.main(latest_xml_path=str(latest), feeds_dir=str(feeds))

    assert (feeds / WORD_CONF["feed_filename"]).read_bytes() == first
    assert len(items(feeds / WORD_CONF["feed_filename"])) == 1
