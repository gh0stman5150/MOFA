"""Generate the OneDrive ring feed (latest_raw_files/macos_standalone_onedrive_all.*).

Every network lookup goes through http_client (bounded timeouts and retries).
A ring whose version, manifest, installer URL or hashes cannot be fetched keeps
its cached feed entry and logs a WARNING; a ring with no cached entry to fall
back to logs at ERROR, which run_generators.py treats as a failed run.
"""

from http_client import get as http_get
import hashlib
import re
import xml.etree.ElementTree as ET
from datetime import datetime
from xml.dom.minidom import parseString
import logging
import os
import json
import yaml
from collections import OrderedDict
from urllib.parse import urljoin
import pytz

# Rings published through go.microsoft.com fwlinks. The version is read from
# the installer URL the fwlink redirects to; the fwlink itself is published as
# the download link.
LINKID_RINGS = (
    {"name": "Deferred Ring", "url": "https://go.microsoft.com/fwlink/?linkid=861009"},
    {"name": "Upcoming Deferred  Ring", "url": "https://go.microsoft.com/fwlink/?linkid=861010"},
    {"name": "Rolling Out (Unknown Use)", "url": "https://go.microsoft.com/fwlink/?linkid=861011"},
    {"name": "App New Version (Unknown Use)", "url": "https://go.microsoft.com/fwlink/?linkid=823060"},
)

# Rings described by a plist manifest. Rings that share a manifest URL fetch
# it (and hash its installer) only once per run. The Upcoming Production Ring
# reads the Production Ring's manifest, so the two entries are identical until
# a separate upcoming manifest is confirmed (see AGENTS.md, Known gaps).
MANIFEST_RINGS = (
    {
        "name": "Insider Ring",
        "url": "https://g.live.com/0USSDMC_W5T/MacODSUInsiders",
        "version_key": "CFBundleShortVersionString",
        "binary_url_key": "UniversalPkgBinaryURL",
    },
    {
        "name": "Upcoming Production Ring",
        "url": "https://g.live.com/0USSDMC_W5T/StandaloneProductManifest",
        "version_key": "CFBundleShortVersionString",
        "binary_url_key": "UniversalPkgBinaryURL",
    },
    {
        "name": "Production Ring",
        "url": "https://g.live.com/0USSDMC_W5T/StandaloneProductManifest",
        "version_key": "CFBundleShortVersionString",
        "binary_url_key": "UniversalPkgBinaryURL",
    },
)

# OneDrive installers live under .../Installers/<major>.<build>.<date>.<rev>/...
# The published short version is the first three components.
INSTALLER_VERSION_PATTERN = re.compile(r"/Installers/(\d+\.\d+\.\d+)(?:\.\d+)*/", re.IGNORECASE)

HASH_CHUNK_SIZE = 1024 * 1024
MISSING_VALUES = (None, "", "N/A")

# Per-run caches: rings that share a manifest or an installer URL must not
# trigger a second download of a multi-hundred-megabyte package.
_MANIFEST_CACHE = {}
_HASH_CACHE = {}


def parse_installer_version(url):
    """Return the short version encoded in an installer URL, or None."""
    if not url:
        return None
    match = INSTALLER_VERSION_PATTERN.search(url)
    return match.group(1) if match else None


def resolve_linked_package(url):
    """Follow an fwlink and return (short_version, installer_url).

    Only the response headers are read; the installer body is not downloaded.
    Returns (None, None) when the redirect cannot be followed or no hop in the
    redirect chain carries a recognisable installer version.
    """
    try:
        response = http_get(url, allow_redirects=True, stream=True)
        try:
            response.raise_for_status()
            # Prefer the final URL, then the most recent Location header.
            candidates = [response.url]
            for hop in reversed(response.history or []):
                location = hop.headers.get("Location")
                if location:
                    candidates.append(urljoin(hop.url, location))
        finally:
            response.close()
    except Exception as e:
        logging.warning(f"Error resolving fwlink {url}: {e}")
        return None, None

    for candidate in candidates:
        version = parse_installer_version(candidate)
        if version:
            logging.info(f"Fetched version '{version}' for URL: {url}")
            return version, candidate
    logging.warning(f"No installer version found in the redirect chain for {url}")
    return None, None


def fetch_manifest(url):
    """Fetch and parse a plist manifest once per run; None on failure."""
    if url in _MANIFEST_CACHE:
        return _MANIFEST_CACHE[url]
    try:
        response = http_get(url, timeout=30)
        response.raise_for_status()
        manifest = ET.fromstring(response.content)
    except Exception as e:
        logging.warning(f"Error fetching manifest {url}: {e}")
        manifest = None
    _MANIFEST_CACHE[url] = manifest
    return manifest


def extract_from_xml(manifest, key):
    """Return the <string> value that follows <key>key</key> in a plist, or None."""
    if manifest is None:
        return None
    for parent in manifest.iter():
        children = list(parent)
        for index, element in enumerate(children[:-1]):
            if element.tag == "key" and element.text == key:
                value = children[index + 1]
                if value.tag == "string" and value.text and value.text.strip():
                    logging.info(f"Found value for key '{key}': {value.text.strip()}")
                    return value.text.strip()
    logging.warning(f"Key '{key}' not found in manifest")
    return None


def compute_hashes(url):
    """Stream an installer once and return (sha1, sha256), or None on failure."""
    if url in _HASH_CACHE:
        return _HASH_CACHE[url]
    try:
        logging.info(f"Computing SHA1 and SHA256 for {url}")
        response = http_get(url, stream=True, allow_redirects=True)
        try:
            response.raise_for_status()
            sha1 = hashlib.sha1()
            sha256 = hashlib.sha256()
            for chunk in response.iter_content(chunk_size=HASH_CHUNK_SIZE):
                sha1.update(chunk)
                sha256.update(chunk)
        finally:
            response.close()
        result = (sha1.hexdigest(), sha256.hexdigest())
    except Exception as e:
        logging.warning(f"Error computing SHA1/SHA256 for {url}: {e}")
        result = None
    _HASH_CACHE[url] = result
    return result


def load_existing_data(file_path):
    """Load existing data from the output XML file."""
    try:
        tree = ET.parse(file_path)
        root = tree.getroot()
        existing_data = {}
        for package in root.findall("package"):
            name_element = package.find("name")
            short_version_element = package.find("short_version")
            last_updated_element = package.find("last_updated")
            download_element = package.find("full_update_download")
            sha1_element = package.find("full_update_sha1")
            sha256_element = package.find("full_update_sha256")

            # Ensure elements exist before accessing their text
            name = name_element.text if name_element is not None else None
            short_version = short_version_element.text if short_version_element is not None else None
            last_updated = last_updated_element.text if last_updated_element is not None else None
            download_url = download_element.text if download_element is not None else None
            sha1 = sha1_element.text if sha1_element is not None else "N/A"
            sha256 = sha256_element.text if sha256_element is not None else "N/A"

            if name:
                existing_data[name] = {
                    "short_version": short_version,
                    "last_updated": last_updated,
                    "full_update_download": download_url,
                    "full_update_sha1": sha1,
                    "full_update_sha256": sha256
                }
        return existing_data
    except FileNotFoundError:
        logging.warning(f"{file_path} not found. Starting fresh.")
        return {}
    except Exception as e:
        logging.warning(f"Error loading existing data: {e}")
        return {}


def has_version_changed(package_name, new_version, existing_data):
    """Check if the version has changed compared to local data."""
    if package_name not in existing_data:
        logging.info(f"New package detected: '{package_name}'")
        return True

    old_version = existing_data[package_name]["short_version"]
    if old_version != new_version:
        logging.info(f"Version change for '{package_name}': {old_version} -> {new_version}")
        return True

    logging.info(f"No version change for '{package_name}': still {old_version}")
    return False


def generate_package_xml(package_data, existing_data, now):
    package = ET.Element("package")

    package_name = package_data.get("name", "")
    # If we're using existing data (no version change), use all the old data
    if not package_data.get("version_changed", True) and package_name in existing_data:
        existing_package = existing_data[package_name]

        # Add elements in the specified order
        name = ET.SubElement(package, "name")
        name.text = package_name

        short_version = ET.SubElement(package, "short_version")
        short_version.text = existing_package["short_version"]

        application_id = ET.SubElement(package, "application_id")
        application_id.text = "ONDR18"

        application_name = ET.SubElement(package, "application_name")
        application_name.text = "OneDrive.app"

        cf_bundle_version = ET.SubElement(package, "CFBundleVersion")
        cf_bundle_version.text = "com.microsoft.onedrive"

        full_update_download = ET.SubElement(package, "full_update_download")
        full_update_download.text = existing_package["full_update_download"]

        full_update_sha1 = ET.SubElement(package, "full_update_sha1")
        full_update_sha1.text = existing_package["full_update_sha1"]

        full_update_sha256 = ET.SubElement(package, "full_update_sha256")
        full_update_sha256.text = existing_package["full_update_sha256"]

        last_updated = ET.SubElement(package, "last_updated")
        last_updated.text = existing_package["last_updated"]  # Keep the original timestamp
    else:
        # Add elements with new data
        name = ET.SubElement(package, "name")
        name.text = package_name

        short_version = ET.SubElement(package, "short_version")
        short_version.text = package_data.get("short_version", "N/A")

        application_id = ET.SubElement(package, "application_id")
        application_id.text = "ONDR18"

        application_name = ET.SubElement(package, "application_name")
        application_name.text = "OneDrive.app"

        cf_bundle_version = ET.SubElement(package, "CFBundleVersion")
        cf_bundle_version.text = "com.microsoft.onedrive"

        full_update_download = ET.SubElement(package, "full_update_download")
        full_update_download.text = package_data.get("full_update_download", "")

        full_update_sha1 = ET.SubElement(package, "full_update_sha1")
        full_update_sha1.text = package_data.get("full_update_sha1", "N/A")

        full_update_sha256 = ET.SubElement(package, "full_update_sha256")
        full_update_sha256.text = package_data.get("full_update_sha256", "N/A")

        last_updated = ET.SubElement(package, "last_updated")
        last_updated.text = now

    return package


def skip_sha_checks():
    # Function to determine if SHA checks should be skipped
    # This can be controlled via an environment variable or a configuration flag
    return False  # Set to True to skip SHA checks


def keep_cached_entry(name, existing_data, reason):
    """Reuse a ring's cached entry, or log at ERROR when there is none."""
    if name in existing_data:
        logging.warning(f"{reason}; keeping the cached entry for '{name}'.")
        return {"name": name, "version_changed": False, **existing_data[name]}
    logging.error(f"{reason}; no cached entry for '{name}', so it would be dropped from the feed.")
    return None


def build_package(name, version, download_url, hash_url, existing_data):
    """Return feed data for a ring whose current version and installer are known."""
    version_changed = has_version_changed(name, version, existing_data)
    cached = existing_data.get(name)
    if cached is None or version_changed:
        needs_refresh = True
    elif cached.get("full_update_download") != download_url:
        logging.info(f"Download URL change for '{name}': {cached.get('full_update_download')} -> {download_url}")
        needs_refresh = True
    else:
        # A previous run that could not hash the installer is retried.
        needs_refresh = not skip_sha_checks() and any(
            cached.get(key) in MISSING_VALUES for key in ("full_update_sha1", "full_update_sha256")
        )
    if not needs_refresh:
        return {"name": name, "version_changed": False, **cached}

    if skip_sha_checks():
        sha1 = sha256 = "N/A"
    else:
        hashes = compute_hashes(hash_url)
        if hashes is None:
            return keep_cached_entry(name, existing_data, f"Could not hash {hash_url}")
        sha1, sha256 = hashes

    return {
        "name": name,
        "short_version": version,
        "full_update_download": download_url,
        "full_update_sha1": sha1,
        "full_update_sha256": sha256,
        "version_changed": True,
    }


def fetch_package_data(existing_data):
    packages = []

    for entry in LINKID_RINGS:
        version, installer_url = resolve_linked_package(entry["url"])
        if not version:
            package = keep_cached_entry(entry["name"], existing_data, f"Version lookup failed for {entry['url']}")
        else:
            package = build_package(entry["name"], version, entry["url"], installer_url, existing_data)
        if package:
            packages.append(package)

    for entry in MANIFEST_RINGS:
        manifest = fetch_manifest(entry["url"])
        if manifest is None:
            package = keep_cached_entry(entry["name"], existing_data, f"Manifest unavailable at {entry['url']}")
        else:
            version = extract_from_xml(manifest, entry["version_key"])
            binary_url = extract_from_xml(manifest, entry["binary_url_key"])
            if not version:
                package = keep_cached_entry(entry["name"], existing_data, f"Version not found in {entry['url']}")
            elif not binary_url:
                package = keep_cached_entry(entry["name"], existing_data, f"Binary URL not found in {entry['url']}")
            else:
                package = build_package(entry["name"], version, binary_url, binary_url, existing_data)
        if package:
            packages.append(package)

    return packages


def xml_to_dict(element):
    """Convert XML element to ordered dictionary for JSON/YAML conversion."""
    result = OrderedDict()
    for child in element:
        # Handle nested elements
        if len(child):
            child_dict = xml_to_dict(child)
            if child.tag in result:
                # If the tag already exists, convert to list or append
                if not isinstance(result[child.tag], list):
                    result[child.tag] = [result[child.tag]]
                result[child.tag].append(child_dict)
            else:
                result[child.tag] = child_dict
        else:
            # Handle text elements
            result[child.tag] = child.text or ""
    return result


def convert_to_json_yaml(xml_file):
    """Convert XML file to JSON and YAML formats."""
    try:
        tree = ET.parse(xml_file)
        root = tree.getroot()

        # Convert XML to ordered dictionary
        data = OrderedDict()
        data[root.tag] = xml_to_dict(root)

        # Generate file paths
        base_path = os.path.splitext(xml_file)[0]
        json_file = f"{base_path}.json"
        yaml_file = f"{base_path}.yaml"

        # Write JSON file
        with open(json_file, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        logging.info(f"Generated JSON file: {json_file}")

        # Set up YAML to preserve dictionary order
        class OrderedDumper(yaml.SafeDumper):
            pass

        def _dict_representer(dumper, data):
            return dumper.represent_mapping(
                yaml.resolver.Resolver.DEFAULT_MAPPING_TAG,
                data.items())

        OrderedDumper.add_representer(OrderedDict, _dict_representer)

        # Write YAML file with order preserved
        with open(yaml_file, 'w', encoding='utf-8') as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True,
                     Dumper=OrderedDumper)
        logging.info(f"Generated YAML file: {yaml_file}")

        return True
    except Exception as e:
        logging.warning(f"Error converting XML to JSON/YAML: {e}")
        return False


def get_package_order_priority(package_name):
    """
    Returns a numeric priority for package ordering.
    Lower numbers will appear first in the sorted list.
    """
    order_map = {
        "Production Ring": 1,
        "Upcoming Production Ring": 2,
        "Deferred Ring": 3,
        "Upcoming Deferred  Ring": 4,
        "Insider Ring": 5,
        "Rolling Out (Unknown Use)": 6,
        "App New Version (Unknown Use)": 7,
    }
    return order_map.get(package_name, 999)  # Default high number for unknown packages


def get_current_date_time():
    """
    Get the current date and time in Eastern Time.

    Returns:
        str: The formatted date and time.
    """
    # Get current UTC time and convert it to Eastern Time (or any other timezone)
    utc_now = datetime.now(pytz.utc)  # Get current UTC time with tz info
    eastern_time = utc_now.astimezone(pytz.timezone('US/Eastern'))  # Convert to Eastern Time

    # Format the date and time as needed (e.g., 12/06/2024 04:30 PM Eastern)
    formatted_date_time = eastern_time.strftime('%B %d, %Y %I:%M %p %Z')  # 'December 06, 2024 04:30 PM Eastern'

    return formatted_date_time


def main(output_file="latest_raw_files/macos_standalone_onedrive_all.xml"):
    now = get_current_date_time()  # Use the new function to get the current date and time

    # Load existing data if available
    existing_data = load_existing_data(output_file)

    # Fetch package data, reusing existing data where possible
    packages = fetch_package_data(existing_data)
    if not packages:
        logging.error(f"No OneDrive ring data could be fetched or reused; leaving {output_file} unchanged.")
        return 1

    # Sort packages in the specified order
    packages.sort(key=lambda pkg: get_package_order_priority(pkg["name"]))

    # Check if any package has changed
    any_changes = any(package.get("version_changed", True) for package in packages)

    # Always generate a new XML file to update the global last_updated timestamp
    # Generate new XML
    root = ET.Element("latest")
    global_last_updated = ET.SubElement(root, "last_updated")
    global_last_updated.text = now  # Always update the global last_updated field

    for package_data in packages:
        package_xml = generate_package_xml(package_data, existing_data, now)
        root.append(package_xml)

    # Convert to string and pretty-print
    rough_string = ET.tostring(root, encoding="utf-8")
    reparsed = parseString(rough_string)
    pretty_xml = reparsed.toprettyxml(indent="  ")

    # Write to file
    with open(output_file, "w", encoding="utf-8") as f:
        f.write(pretty_xml)

    if any_changes:
        logging.info(f"Updated {output_file} with {len(packages)} packages - some packages were updated")
    else:
        logging.info(f"Updated {output_file} with {len(packages)} packages - only global timestamp was updated")

    # Convert XML to JSON and YAML formats
    convert_to_json_yaml(output_file)
    return 0


if __name__ == "__main__":
    # Configured here, not at import, so importing this module leaves the
    # importer's logging alone.
    logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
    raise SystemExit(main())
