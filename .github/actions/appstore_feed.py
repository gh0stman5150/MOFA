"""Shared code for the App Store feed generators.

generate_ios_appstore_latest.py and generate_macos_appstore_latest.py each
pass an ordered table of apps to run(). Every app has an iTunes Search API
URL and may pin an exact "bundle_id". For each app:

- The response must be HTTP 2xx JSON with a "results" list. Otherwise the
  cached entry from the previous feed is kept (WARNING), or, with no cached
  entry, the app would be dropped and the run fails (ERROR).
- The first result published by Microsoft is used: sellerName or artistName
  contains "Microsoft", or the bundleId equals the pinned "bundle_id". A free
  text search often ranks another developer's app first, so results[0] is
  never trusted on its own.
- When no result matches, the cached entry is kept and an ERROR is logged so
  run_generators.py fails and an owner corrects the search term, pins a
  bundle_id or removes the app. Nothing is published under a Microsoft name
  without a Microsoft match.

All HTTP goes through ``http_get`` in this module, so a test replaces it once.
"""

from __future__ import annotations

import json
import logging
import os
import xml.etree.ElementTree as ET
from collections import OrderedDict
from datetime import datetime
from xml.dom.minidom import parseString

import pytz
import requests
import yaml

from http_client import get as http_get

LOG_FORMAT = "%(asctime)s - %(levelname)s - %(message)s"
LOG_DATE_FORMAT = "%B %d, %Y %I:%M %p"

# Feed field -> iTunes Search API result key.
COMMON_KEYS = {
    "application_name": "trackName",
    "bundleId": "bundleId",
    "version": "version",
    "currentVersionReleaseDate": "currentVersionReleaseDate",
    "releaseNotes": "releaseNotes",
    "minimumOsVersion": "minimumOsVersion",
    "icon_image": "artworkUrl512",
    "app_store_url": "trackViewUrl",
}

# Order of the fields after <name> in every <package>.
FIELDS = [
    "application_name",
    "bundleId",
    "currentVersionReleaseDate",
    "icon_image",
    "minimumOsVersion",
    "releaseNotes",
    "version",
    "app_store_url",
]

PUBLISHER = "microsoft"


class AppLookupError(Exception):
    """The App Store search response could not be used."""


def configure_logging():
    """Configure the generator log format that run_generators.py scans for ERROR."""
    logging.basicConfig(level=logging.INFO, format=LOG_FORMAT, datefmt=LOG_DATE_FORMAT)


def get_current_date_time():
    """Return the current US Eastern time, e.g. 'December 06, 2024 04:30 PM EST'."""
    eastern_time = datetime.now(pytz.utc).astimezone(pytz.timezone("US/Eastern"))
    return eastern_time.strftime("%B %d, %Y %I:%M %p %Z")


def is_microsoft_result(result, bundle_id=None):
    """True when result is the pinned bundle ID or, without a pin, a Microsoft-published app."""
    if bundle_id:
        return result.get("bundleId") == bundle_id
    for field in ("sellerName", "artistName"):
        value = result.get(field)
        if isinstance(value, str) and PUBLISHER in value.lower():
            return True
    return False


def fetch_app_data(url, bundle_id=None):
    """Return the first Microsoft result of an iTunes search, or None when none matches.

    Raises AppLookupError for an HTTP error, a non-JSON body or a body without
    a "results" list.
    """
    logging.info(f"Fetching data from {url}")
    try:
        response = http_get(url, timeout=30)
        response.raise_for_status()
        data = response.json()
    except (requests.RequestException, ValueError) as e:
        raise AppLookupError(str(e)) from e
    results = data.get("results") if isinstance(data, dict) else None
    if not isinstance(results, list):
        raise AppLookupError("the response has no results list")
    for result in results:
        if isinstance(result, dict) and is_microsoft_result(result, bundle_id):
            return result
    return None


def format_date(date_str):
    """'2026-01-31T08:00:00Z' -> 'January 31, 2026'; anything else is returned unchanged."""
    try:
        date_obj = datetime.strptime(date_str, "%Y-%m-%dT%H:%M:%SZ")
        return date_obj.strftime("%B %d, %Y")
    except (TypeError, ValueError):
        return date_str


def values_from_result(result, keys):
    """Map an iTunes result to feed fields; a missing key gives 'NA'."""
    values = OrderedDict()
    for key in FIELDS:
        value = result.get(keys[key], "NA")
        if key == "currentVersionReleaseDate" and value != "NA":
            value = format_date(value)
        if value is not None and not isinstance(value, str):
            value = str(value)
        values[key] = value
    return values


def read_existing_packages(xml_file):
    """Return {name: field values} from the previously published feed.

    A package without a <name> is skipped with a warning; the rest stay usable.
    """
    if not os.path.exists(xml_file):
        logging.warning(f"File {xml_file} does not exist; no cached App Store entries.")
        return {}
    try:
        root = ET.parse(xml_file).getroot()
    except (ET.ParseError, OSError) as e:
        logging.warning(f"Could not read cached App Store entries from {xml_file}: {e}")
        return {}
    existing = {}
    for index, package in enumerate(root.findall("package"), start=1):
        name = (package.findtext("name") or "").strip()
        if not name:
            logging.warning(f"Skipping cached package #{index} in {xml_file}: it has no <name>.")
            continue
        values = OrderedDict()
        for key in FIELDS:
            element = package.find(key)
            values[key] = "NA" if element is None else element.text
        existing[name] = values
    return existing


def resolve_app(app_name, app_info, existing):
    """Return the field values to publish for one app, or None to drop it (ERROR logged)."""
    cached = existing.get(app_name)
    bundle_id = app_info.get("bundle_id")
    try:
        result = fetch_app_data(app_info["url"], bundle_id)
    except AppLookupError as e:
        if cached is not None:
            logging.warning(f"Could not fetch {app_name} ({e}); keeping the cached entry.")
            return cached
        logging.error(f"Could not fetch {app_name} ({e}) and there is no cached entry; it would be dropped from the feed.")
        return None

    if result is None:
        expected = f"bundle ID {bundle_id}" if bundle_id else "a Microsoft seller"
        if cached is not None:
            logging.error(
                f"No App Store result for {app_name} matches {expected}; keeping the cached entry. "
                "Correct the search term, pin a bundle_id or remove the app."
            )
            return cached
        logging.error(f"No App Store result for {app_name} matches {expected}; it would be dropped from the feed.")
        return None

    values = values_from_result(result, app_info["keys"])
    for key, value in values.items():
        logging.info(f"{key}: {value}")
    return values


def build_feed(apps, existing, timestamp):
    root = ET.Element("latest")
    ET.SubElement(root, "last_updated").text = timestamp
    for app_name, app_info in apps.items():
        logging.info("-" * 50)
        logging.info(f"Processing {app_name}")
        values = resolve_app(app_name, app_info, existing)
        if values is None:
            continue
        package = ET.SubElement(root, "package")
        ET.SubElement(package, "name").text = app_name
        for key in FIELDS:
            ET.SubElement(package, key).text = values.get(key, "NA")
    return root


def write_xml(root, xml_file):
    xml_str = ET.tostring(root, encoding="utf-8")
    pretty_xml_as_string = parseString(xml_str).toprettyxml()
    with open(xml_file, "w", encoding="utf-8") as f:
        f.write(pretty_xml_as_string)
    logging.info("-" * 50)
    logging.info(f"XML output generated at: {xml_file}")


def _element_text(element):
    if element is None:
        return "NA"
    return element.text.strip() if element.text else None


class OrderedDumper(yaml.Dumper):
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


def _dict_representer(dumper, data):
    return dumper.represent_dict(data.items())


OrderedDumper.add_representer(OrderedDict, _dict_representer)


def xml_to_json_and_yaml(xml_file, json_file, yaml_file):
    """Write JSON and YAML copies of the XML feed; a missing field becomes 'NA'."""
    root = ET.parse(xml_file).getroot()
    packages = []
    for package in root.findall("package"):
        package_data = OrderedDict()
        for key in ["name"] + FIELDS:
            package_data[key] = _element_text(package.find(key))
        packages.append(package_data)

    output_data = OrderedDict()
    output_data["last_updated"] = _element_text(root.find("last_updated"))
    output_data["packages"] = packages

    with open(json_file, "w", encoding="utf-8") as f:
        json.dump(output_data, f, indent=4)
    logging.info(f"JSON output generated at: {json_file}")

    with open(yaml_file, "w", encoding="utf-8") as f:
        yaml.dump(output_data, f, Dumper=OrderedDumper, default_flow_style=False, sort_keys=False)
    logging.info(f"YAML output generated at: {yaml_file}")


def run(apps, basename, output_dir="latest_raw_files"):
    """Build output_dir/<basename>.{xml,json,yaml} from apps; returns 0."""
    timestamp = get_current_date_time()
    logging.info(f"Current date and time: {timestamp}")
    os.makedirs(output_dir, exist_ok=True)
    xml_file = os.path.join(output_dir, f"{basename}.xml")
    root = build_feed(apps, read_existing_packages(xml_file), timestamp)
    write_xml(root, xml_file)
    xml_to_json_and_yaml(
        xml_file,
        os.path.join(output_dir, f"{basename}.json"),
        os.path.join(output_dir, f"{basename}.yaml"),
    )
    return 0
