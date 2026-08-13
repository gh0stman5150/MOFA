from __future__ import annotations

import json
import xml.etree.ElementTree as ET
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "latest_raw_files"


def generated_triples():
    for json_path in sorted(DATA.glob("*.json")):
        stem = json_path.stem
        yaml_path = DATA / f"{stem}.yaml"
        xml_path = DATA / f"{stem}.xml"
        if yaml_path.exists() and xml_path.exists():
            yield stem, json_path, yaml_path, xml_path


def test_generated_triples_exist():
    triples = list(generated_triples())
    assert len(triples) >= 9


def test_yaml_and_json_are_equivalent_and_xml_is_well_formed():
    for stem, json_path, yaml_path, xml_path in generated_triples():
        json_data = json.loads(json_path.read_text(encoding="utf-8"))
        yaml_data = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
        assert yaml_data == json_data, stem
        xml_root = ET.parse(xml_path).getroot()
        assert len(xml_root) > 0, stem
        if isinstance(json_data, dict) and "last_updated" in json_data:
            xml_timestamp = xml_root.findtext("last_updated")
            assert xml_timestamp == str(json_data["last_updated"]), stem
