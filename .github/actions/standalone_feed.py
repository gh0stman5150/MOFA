"""Shared code for the macOS standalone feed generators.

generate_macos_standalone_latest.py, generate_macos_standalone_preview.py and
generate_macos_standalone_beta.py publish the same feed shape from different
Microsoft AutoUpdate channels. This module holds what they share: reading the
cached feed, fetching and parsing one update manifest, keeping the cached
entry (or failing the run) when a fetch fails, hashing installers and writing
the XML, YAML and JSON outputs. Each generator keeps its app table, its field
order and how it fills its hash fields.

All HTTP goes through ``http_get`` in this module, so a test replaces it once.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
import xml.etree.ElementTree as ET
from datetime import datetime
from hashlib import sha1, sha256
from xml.dom import minidom

import pytz
import yaml

from http_client import get as http_get

LOG_FORMAT = "%(asctime)s - %(levelname)s - %(message)s"
LOG_DATE_FORMAT = "%B %d, %Y %I:%M %p"


def configure_logging():
    """Configure the generator log format that run_generators.py scans for ERROR."""
    logging.basicConfig(level=logging.INFO, format=LOG_FORMAT, datefmt=LOG_DATE_FORMAT)


def get_current_date_time():
    """Return the current US Eastern time, e.g. 'December 06, 2024 04:30 PM EST'."""
    eastern_time = datetime.now(pytz.utc).astimezone(pytz.timezone("US/Eastern"))
    return eastern_time.strftime("%B %d, %Y %I:%M %p %Z")


def read_existing_xml(filename):
    """Return the packages of the previously published feed, keyed by name.

    A package without a <name> or <last_updated> is skipped with a warning and
    the rest of the cache stays usable, so one malformed entry cannot turn
    every later fetch failure into a dropped package.
    """
    if not os.path.exists(filename):
        logging.warning("File %s does not exist.", filename)
        return {}
    try:
        logging.info("Reading existing XML data from %s...", filename)
        root = ET.parse(filename).getroot()
    except (ET.ParseError, OSError) as e:
        logging.warning("Could not read existing XML from %s: %s", filename, e)
        return {}

    existing_data = {}
    for index, package in enumerate(root.findall("package"), start=1):
        app_name = (package.findtext("name") or "").strip()
        last_updated = package.find("last_updated")
        if not app_name or last_updated is None:
            logging.warning(
                "Skipping malformed cached package #%d in %s: it has no <name> or <last_updated>.",
                index,
                filename,
            )
            continue
        existing_data[app_name] = {
            "last_updated": last_updated.text,
            "data": {child.tag: child.text for child in package},
        }
    logging.info("Read %d cached packages from %s.", len(existing_data), filename)
    return existing_data


def find_key_value(element, key_name):
    """Return the plist value that follows <key>key_name</key>, or 'N/A'."""
    if element.tag == "dict":
        found = False
        for child in element:
            if found:
                logging.info(f"Found value for key {key_name}: {child.text}")
                return child.text if child.text else "N/A"
            if child.tag == "key" and child.text == key_name:
                found = True
    elif element.tag == "array":
        for item in element:
            value = find_key_value(item, key_name)
            if value != "N/A":
                return value
    # Recursively search nested dicts and arrays
    for child in element:
        if child.tag in ["dict", "array"]:
            value = find_key_value(child, key_name)
            if value != "N/A":
                return value
    return "N/A"


def convert_last_updated(last_updated):
    """Render an epoch-milliseconds or ISO 8601 date as 'Month DD, YYYY'; else 'N/A'."""
    if isinstance(last_updated, int) or (last_updated.isdigit() if isinstance(last_updated, str) else False):
        return time.strftime("%B %d, %Y", time.gmtime(int(last_updated) / 1000))
    elif isinstance(last_updated, str):
        try:
            date_obj = datetime.fromisoformat(last_updated.replace("Z", "+00:00"))
            return date_obj.strftime("%B %d, %Y")
        except ValueError:
            pass
    return "N/A"


def _strip_version_letters(extracted_data):
    # 'Microsoft Word 16.90' -> '16.90'; a missing value stays 'N/A' (it used
    # to become '/').
    short_version = extracted_data.get("short_version")
    if isinstance(short_version, str) and short_version != "N/A":
        extracted_data["short_version"] = re.sub(r"[a-zA-Z]", "", short_version).lstrip()


def process_xml_data(app_data, config):
    """Extract the configured fields from a MAU plist <dict>; missing keys give 'N/A'."""
    logging.info("Processing XML data...")
    extracted_data = {}
    for field, key in config["keys"].items():
        extracted_data[field] = find_key_value(app_data, key)

    extracted_data["last_updated"] = convert_last_updated(extracted_data.get("last_updated", "N/A"))
    _strip_version_letters(extracted_data)

    logging.info("Successfully processed XML data.")
    return extracted_data


def _json_text(value):
    if value is None:
        return "N/A"
    if isinstance(value, (int, str)) and not isinstance(value, bool):
        return value  # epoch-millisecond integers are converted by convert_last_updated
    return str(value)


def process_json_data(app_data, config):
    """Extract the configured fields from a JSON manifest; missing keys give 'N/A'."""
    extracted_data = {}
    for field, key in config["keys"].items():
        extracted_data[field] = _json_text(app_data.get(key, "N/A"))

    extracted_data["last_updated"] = convert_last_updated(extracted_data.get("last_updated", "N/A"))
    for field, value in extracted_data.items():
        if isinstance(value, int):
            # ElementTree cannot serialize integers; keep every field text.
            extracted_data[field] = str(value)
    _strip_version_letters(extracted_data)
    return extracted_data


def is_json_response(response):
    """Use the declared Content-Type; when the header is missing, sniff the body.

    A missing header used to raise KeyError and was reported as a fetch failure.
    """
    headers = getattr(response, "headers", None) or {}
    content_type = headers.get("Content-Type") or ""
    if content_type:
        return content_type.lower().startswith("application/json")
    return response.content.lstrip()[:1] in (b"{", b"[")


def fetch_update_data(app_name, config):
    """Fetch one app's update manifest (plist XML or JSON) and extract its fields."""
    logging.info(f"Fetching data for {app_name} from {config['url']}...")
    response = http_get(config["url"], allow_redirects=True, timeout=30)
    response.raise_for_status()
    logging.info(f"Response status code: {response.status_code}")

    if is_json_response(response):
        app_data = response.json()
        logging.info(f"JSON data: {app_data}")
        return process_json_data(app_data, config)

    app_root = ET.fromstring(response.content)
    app_data = app_root.find(".//dict")
    if app_data is None:
        raise ValueError("the update manifest has no <dict> element")
    return process_xml_data(app_data, config)


# Installers are multi-gigabyte; each URL is streamed once and both digests
# are computed from that single pass. Results are cached per URL so the
# separate SHA1 and SHA256 lookups (and identical full/app-only URLs) never
# trigger a second download.
_HASH_CACHE = {}


def compute_hashes(url):
    """Return (sha1, sha256) for url, or ('N/A', 'N/A') for a sentinel URL or a failure."""
    if not isinstance(url, str) or not url.strip() or url.strip().upper() == "N/A":
        return "N/A", "N/A"
    if url in _HASH_CACHE:
        return _HASH_CACHE[url]
    try:
        logging.info(f"Computing SHA1 and SHA256 for {url}...")
        response = http_get(url, stream=True, allow_redirects=True, timeout=30)
        response.raise_for_status()
        sha1_hasher = sha1()
        sha256_hasher = sha256()
        for chunk in response.iter_content(chunk_size=1024 * 1024):
            sha1_hasher.update(chunk)
            sha256_hasher.update(chunk)
        result = (sha1_hasher.hexdigest(), sha256_hasher.hexdigest())
        logging.info(f"SHA1 for {url}: {result[0]}")
        logging.info(f"SHA256 for {url}: {result[1]}")
    except Exception as e:
        logging.warning(f"Error computing SHA1/SHA256 for {url}: {e}")
        result = ("N/A", "N/A")
    _HASH_CACHE[url] = result
    return result


def compute_sha1(url):
    return compute_hashes(url)[0]


def compute_sha256(url):
    return compute_hashes(url)[1]


def add_download_hashes(extracted_data, url_key="latest_download"):
    """Fill sha1/sha256 from url_key (preview and beta feed shape)."""
    download_url = extracted_data.get(url_key)
    if extracted_data.get("sha1", "N/A") == "N/A":
        logging.info(f"Download URL for SHA1: {download_url}")
        extracted_data["sha1"] = compute_sha1(download_url) if download_url else "N/A"
    if extracted_data.get("sha256", "N/A") == "N/A":
        logging.info(f"Download URL for SHA256: {download_url}")
        extracted_data["sha256"] = compute_sha256(download_url) if download_url else "N/A"


class FeedRun:
    """One generator run: the cached feed, the run timestamp and the packages built so far."""

    def __init__(self, existing_data, field_order, timestamp):
        self.existing_data = existing_data
        self.field_order = list(field_order)
        self.timestamp = timestamp
        self.root = ET.Element("latest")
        ET.SubElement(self.root, "last_updated").text = timestamp

    def cached(self, app_name):
        """Return the cached field values for app_name, or None."""
        entry = self.existing_data.get(app_name)
        return entry["data"] if entry is not None else None

    def add(self, app_name, data):
        logging.info(f"Adding {app_name} to combined XML...")
        package = ET.SubElement(self.root, "package")
        for key in self.field_order:
            if key == "name":
                ET.SubElement(package, key).text = app_name
            elif key in data:
                ET.SubElement(package, key).text = data[key]
        logging.info(f"Successfully added {app_name} to combined XML.")

    def keep_cached_or_drop(self, app_name, error):
        """After a failed fetch, publish the cached entry (WARNING) or fail the run (ERROR)."""
        logging.warning(f"Error processing {app_name}: {error}")
        cached = self.cached(app_name)
        if cached is not None:
            logging.info(f"Reverting to existing data for {app_name}.")
            self.add(app_name, cached)
        else:
            # Without cached data the package would silently vanish from the
            # published feed; log at ERROR so run_generators.py fails the run.
            logging.error(f"No cached data for {app_name}; it would be dropped from the feed.")


def has_changed(extracted_data, cached_data, compare_keys=None):
    keys = list(extracted_data) if compare_keys is None else compare_keys
    return any(extracted_data.get(key, "N/A") != cached_data.get(key, "N/A") for key in keys)


def fetch_and_process(app_name, config, run, add_hashes, fetch=fetch_update_data, compare_keys=None):
    """Add one app to run from a fresh manifest, or from the cache when the fetch fails.

    An app whose compared fields match the cache reuses the cached entry,
    hashes included, without downloading anything. A new or changed app gets
    add_hashes(extracted_data) before it is added.
    """
    try:
        logging.info("-" * 50)
        extracted_data = fetch(app_name, config)
        extracted_data.update(config.get("manual_entries", {}))

        # Special handling for Copilot short_version: remove leading "365"
        if app_name == "Copilot":
            sv = extracted_data.get("short_version", "")
            if isinstance(sv, str):
                extracted_data["short_version"] = re.sub(r"^\s*365[\s\-–—]*", "", sv).strip()

        logging.info(f"Extracted data: {extracted_data}")

        # OneDrive manifests carry no usable date; publish the run time.
        if app_name == "OneDrive":
            extracted_data["last_updated"] = run.timestamp

        cached = run.cached(app_name)
        if cached is not None:
            if not has_changed(extracted_data, cached, compare_keys):
                logging.info(f"No update for {app_name}. Skipping SHA checks.")
                run.add(app_name, cached)
                return
            logging.info(f"Update detected for {app_name}.")
        else:
            logging.info(f"New app {app_name} detected.")
        add_hashes(extracted_data)
        run.add(app_name, extracted_data)
    except Exception as e:
        run.keep_cached_or_drop(app_name, e)


def pretty_print_xml(element):
    rough_string = ET.tostring(element, "utf-8")
    return minidom.parseString(rough_string).toprettyxml(indent="    ")


def write_outputs(run, xml_file):
    """Write the XML feed, then YAML and JSON copies read back from that XML."""
    pretty_xml = pretty_print_xml(run.root)
    os.makedirs(os.path.dirname(xml_file) or ".", exist_ok=True)
    with open(xml_file, "w", encoding="utf-8") as f:
        f.write(pretty_xml)
    logging.info("-" * 50)
    logging.info(f"XML output generated at: {xml_file}")

    data = {"last_updated": run.timestamp, "packages": []}
    for package in ET.parse(xml_file).getroot().findall("package"):
        package_data = {"name": package.find("name").text}
        for field in run.field_order:
            if field != "name":
                element = package.find(field)
                package_data[field] = element.text if element is not None else "N/A"
        data["packages"].append(package_data)

    base = os.path.splitext(xml_file)[0]
    yaml_output_file = base + ".yaml"
    if os.path.exists(yaml_output_file):
        os.remove(yaml_output_file)
    with open(yaml_output_file, "w", encoding="utf-8") as yaml_file:
        yaml.dump(data, yaml_file, default_flow_style=False, sort_keys=False)
    logging.info(f"YAML output generated at: {yaml_output_file}")

    json_output_file = base + ".json"
    if os.path.exists(json_output_file):
        os.remove(json_output_file)
    with open(json_output_file, "w", encoding="utf-8") as json_file:
        json.dump(data, json_file, indent=4)
    logging.info(f"JSON output generated at: {json_output_file}")


def run_generator(apps, field_order, output_file, fetch_and_process_app):
    """Build and write one standalone feed; fetch_and_process_app(name, config, run) adds each app."""
    timestamp = get_current_date_time()
    logging.info(f"Current date and time: {timestamp}")
    run = FeedRun(read_existing_xml(output_file), field_order, timestamp)
    for app_name, config in apps.items():
        fetch_and_process_app(app_name, config, run)
    write_outputs(run, output_file)
    return run
