"""Generate the Edge channel feed (latest_raw_files/macos_standalone_edge_all.*).

Logging follows the other generators so run_generators.py can tell recoverable
problems from failures: an installer that cannot be hashed, or a channel whose
release data cannot be fetched while its cached entry is kept, logs a WARNING;
a channel with no data and no cached entry logs an ERROR and fails the run. An
unparseable feed file logs an ERROR and exits 1 before any request, leaving
the XML, JSON and YAML feeds unchanged.
"""

import os
from http_client import get as http_get
import plistlib
import xml.etree.ElementTree as ET
from xml.dom import minidom
from datetime import datetime, timezone
import re
import json
import yaml
from collections import defaultdict
import pytz
import hashlib
import logging

# Define the Eastern Time Zone
eastern = pytz.timezone('US/Eastern')
DATE_FORMAT = '%B %d, %Y %I:%M %p %Z'
HASH_CHUNK_SIZE = 1024 * 1024
MISSING_VALUES = (None, "", "N/A")

CHANNELS = {
    "current": "https://edgeupdates.microsoft.com/api/products/stable",
    "canary": "https://edgeupdates.microsoft.com/api/products/canary",
    "dev": "https://edgeupdates.microsoft.com/api/products/dev",
    "beta": "https://edgeupdates.microsoft.com/api/products/beta"
}


def fetch_edge_latest(channel, url):
    response = http_get(url, timeout=30)
    response.raise_for_status()

    xml_content = response.text

    output_dir = "latest_edge_files"
    os.makedirs(output_dir, exist_ok=True)
    logging.info(f"Directory '{output_dir}' created or already exists.")

    output_file = os.path.join(output_dir, f"edge_{channel}_version.xml")
    with open(output_file, "w", encoding="utf-8") as file:
        file.write(xml_content)
    logging.info(f"File '{output_file}' written successfully.")
    return output_file

def extract_info_from_xml(file_path):
    try:
        with open(file_path, 'rb') as file:
            plist_data = plistlib.load(file)

        logging.debug(f"Parsing plist file: {file_path}")
        logging.debug(plist_data)

        date = plist_data[0].get('Date', 'N/A')
        location = plist_data[0].get('Location', 'N/A')
        title = plist_data[0].get('Title', 'N/A')

        # Format the title to only include numbers and special characters
        version = re.sub(r'[^0-9.]+', '', title)

        # Format the date to a user-readable format
        if date != 'N/A':
            date = date.astimezone(eastern).strftime(DATE_FORMAT)

        return {
            "channel": os.path.basename(file_path).split('_')[1],
            "date": date,
            "location": location,
            "version": version
        }
    except Exception as e:
        logging.error(f"Could not parse file {file_path}: {e}")
        return {
            "channel": os.path.basename(file_path).split('_')[1],
            "date": 'N/A',
            "location": 'N/A',
            "version": 'N/A'
        }

def create_summary_xml(info_list, insider_info_list, output_file):
    root = ET.Element("EdgeLatestVersions")

    # Add last_updated element
    last_updated = ET.SubElement(root, "last_updated")
    last_updated.text = datetime.now(eastern).strftime(DATE_FORMAT)

    for info in info_list:
        entry = ET.SubElement(root, "Version")
        ET.SubElement(entry, "Channel").text = info["channel"]
        ET.SubElement(entry, "Date").text = info["date"]
        ET.SubElement(entry, "Location").text = info["location"]
        ET.SubElement(entry, "Version").text = info["version"]

    for info in insider_info_list:
        entry = ET.SubElement(root, "Version")
        ET.SubElement(entry, "Channel").text = f"insider_{info['channel']}"
        ET.SubElement(entry, "Date").text = info["date"]
        ET.SubElement(entry, "Location").text = info["location"]
        ET.SubElement(entry, "Version").text = info["version"]

    xml_str = ET.tostring(root, encoding='utf-8')
    pretty_xml_str = minidom.parseString(xml_str).toprettyxml(indent="  ")

    with open(output_file, "w", encoding="utf-8") as file:
        file.write(pretty_xml_str)
    logging.info(f"Summary file '{output_file}' written successfully.")

def update_last_updated_in_xml(file_path):
    tree = ET.parse(file_path)
    root = tree.getroot()

    # Find or create last_updated element
    last_updated = root.find("last_updated")
    if last_updated is None:
        last_updated = ET.Element("last_updated")
        root.insert(0, last_updated)

    last_updated.text = datetime.now(eastern).strftime(DATE_FORMAT)

    xml_str = ET.tostring(root, encoding='utf-8')
    pretty_xml_str = minidom.parseString(xml_str).toprettyxml(indent="  ")

    # Remove extra newlines and spaces
    pretty_xml_str = "\n".join([line for line in pretty_xml_str.split("\n") if line.strip()])

    with open(file_path, "w", encoding="utf-8") as file:
        file.write(pretty_xml_str)
    logging.info(f"Updated file '{file_path}' with last_updated.")

def format_published_time(value):
    """Format an Edge API PublishedTime (ISO 8601, UTC when no offset) in Eastern time.

    Fractional seconds and a trailing 'Z' are accepted; anything else that is
    not ISO 8601 raises ValueError.
    """
    published = datetime.fromisoformat(value)
    if published.tzinfo is None:
        published = published.replace(tzinfo=timezone.utc)
    return published.astimezone(eastern).strftime(DATE_FORMAT)

def fetch_edge_insider_canary_version(url):
    return fetch_edge_insider_version(url, "canary")

def fetch_edge_insider_version(url, channel):
    """Return the newest macOS release for a channel, or None.

    None means no usable data: the request failed, the payload was not the
    expected shape, or it listed no macOS release. The caller decides whether
    a cached entry covers the gap.
    """
    try:
        response = http_get(url, timeout=30)
        response.raise_for_status()

        releases = response.json()
        macos_releases = [release for release in releases[0]["Releases"] if release["Platform"] == "MacOS"]

        if not macos_releases:
            logging.warning(f"No MacOS releases found for {channel}.")
            return None

        latest_release = max(macos_releases, key=lambda x: x["PublishedTime"])

        artifact = next(
            (artifact for artifact in latest_release.get("Artifacts", []) if artifact.get("ArtifactName") == "pkg"),
            None,
        )
        location = artifact.get("Location", "N/A") if artifact else "N/A"

        return {
            "channel": channel,
            "date": format_published_time(latest_release["PublishedTime"]),
            "location": location,
            "version": latest_release["ProductVersion"]
        }
    except Exception as e:
        logging.warning(f"Could not read Edge {channel} releases from {url}: {e!r}")
        return None

def generate_hashes(location_url):
    if location_url in MISSING_VALUES:
        return "N/A", "N/A"
    try:
        response = http_get(location_url, stream=True, timeout=30)
        try:
            response.raise_for_status()

            sha1 = hashlib.sha1()
            sha256 = hashlib.sha256()

            for chunk in response.iter_content(chunk_size=HASH_CHUNK_SIZE):
                sha1.update(chunk)
                sha256.update(chunk)
        finally:
            response.close()

        return sha1.hexdigest(), sha256.hexdigest()
    except Exception as e:
        # A transient download failure must not abort the run; the channel
        # is re-hashed on the next run because its stored hashes are N/A.
        logging.warning(f"Error computing SHA1/SHA256 for {location_url}: {e}")
        return "N/A", "N/A"

def should_update_file(local_file, new_date):
    if not os.path.exists(local_file):
        logging.info(f"Local file '{local_file}' does not exist. Proceeding with update.")
        return True

    try:
        tree = ET.parse(local_file)
        root = tree.getroot()
        last_updated = root.find("last_updated")
        if last_updated is not None and last_updated.text == new_date:
            logging.info(f"No update needed. Local file '{local_file}' is already up-to-date.")
            return False
        else:
            logging.info(f"Date mismatch detected. Updating file '{local_file}'.")
            return True
    except Exception as e:
        logging.error(f"Could not check local file '{local_file}': {e}. Proceeding with update.")
        return True

def should_update_channel(global_file, channel_name, channel_date):
    logging.info(f"Starting check for channel '{channel_name}' in global file '{global_file}'...")
    if not os.path.isfile(global_file):
        logging.warning(f"Global file '{global_file}' does not exist. Proceeding with update for channel '{channel_name}'.")
        return True

    try:
        logging.info(f"Parsing global file '{global_file}'...")
        tree = ET.parse(global_file)
        root = tree.getroot()

        # Find the specific channel entry
        for version in root.findall("Version"):
            name = version.find("Name")
            last_update = version.find("Last_Update")
            if name is not None and name.text == channel_name:
                logging.info(f"Found channel '{channel_name}' in global file.")
                if last_update is None or last_update.text != channel_date:
                    logging.info(f"Date mismatch detected for channel '{channel_name}'. Updating global file '{global_file}'.")
                    return True
                if any(version.findtext(tag) in MISSING_VALUES for tag in ("Full_Update_Sha1", "Full_Update_Sha256")):
                    logging.info(f"Stored hashes for channel '{channel_name}' are missing. Retrying them.")
                    return True
                logging.info(f"No update needed for channel '{channel_name}'. Global file '{global_file}' is already up-to-date.")
                return False

        logging.info(f"Channel '{channel_name}' not found in global file '{global_file}'. Proceeding with update.")
        return True
    except ET.ParseError as e:
        logging.error(f"XML parsing error for file '{global_file}': {e}. Proceeding with update.")
        return True
    except Exception as e:
        logging.error(f"Could not check global file '{global_file}' for channel '{channel_name}': {e}. Proceeding with update.")
        return True

def cached_channel_names(global_file):
    """Return the channel names already published in the global file.

    Returns an empty set when there is no global file yet, and None (after
    logging an ERROR) when it exists but cannot be read or parsed.
    """
    if not os.path.isfile(global_file):
        return set()
    try:
        root = ET.parse(global_file).getroot()
    except (ET.ParseError, OSError) as e:
        logging.error(f"Could not parse the Edge feed '{global_file}': {e}")
        return None
    return {version.findtext("Name") for version in root.findall("Version")}

def update_global_file(global_file, info_list):
    logging.info(f"Starting update for global file '{global_file}'...")
    if not os.path.isfile(global_file):
        logging.warning(f"Global file '{global_file}' does not exist. Creating a new file.")
        create_insider_versions_xml(info_list, global_file)
    else:
        logging.info(f"Parsing global file '{global_file}' for updates...")
        tree = ET.parse(global_file)
        root = tree.getroot()

        for info in info_list:
            logging.info(f"Processing channel '{info['channel']}'...")
            updated = False
            for version in root.findall("Version"):
                name = version.find("Name")
                if name is not None and name.text == info["channel"]:
                    logging.info(f"Updating existing entry for channel '{info['channel']}'...")
                    version.find("Version").text = info["version"]
                    version.find("Full_Update_Download").text = info["location"]
                    sha1, sha256 = generate_hashes(info["location"])
                    version.find("Full_Update_Sha1").text = sha1
                    version.find("Full_Update_Sha256").text = sha256
                    version.find("Last_Update").text = info["date"]
                    updated = True
                    logging.info(f"Updated channel '{info['channel']}' in global file.")
                    break

            if not updated:
                logging.info(f"Adding new entry for channel '{info['channel']}'...")
                entry = ET.SubElement(root, "Version")
                ET.SubElement(entry, "Name").text = info["channel"]
                ET.SubElement(entry, "Version").text = info["version"]
                ET.SubElement(entry, "Application_ID").text = "EDGE01"
                ET.SubElement(entry, "Application_Name").text = "Microsoft Edge.app"
                ET.SubElement(entry, "CFBundleVersion").text = "com.microsoft.edgemac"
                ET.SubElement(entry, "Full_Update_Download").text = info["location"]
                sha1, sha256 = generate_hashes(info["location"])
                ET.SubElement(entry, "Full_Update_Sha1").text = sha1
                ET.SubElement(entry, "Full_Update_Sha256").text = sha256
                ET.SubElement(entry, "Last_Update").text = info["date"]
                logging.info(f"Added new channel '{info['channel']}' to global file.")

        logging.info("Updating last_updated field in global file...")
        last_updated = root.find("last_updated")
        if last_updated is None:
            last_updated = ET.SubElement(root, "last_updated")
        last_updated.text = datetime.now(eastern).strftime(DATE_FORMAT)

        logging.info(f"Writing updates to global file '{global_file}'...")
        xml_str = ET.tostring(root, encoding='utf-8')
        pretty_xml_str = minidom.parseString(xml_str).toprettyxml(indent="  ")

        # Remove unnecessary newlines and spaces
        pretty_xml_str = "\n".join([line for line in pretty_xml_str.split("\n") if line.strip()])

        with open(global_file, "w", encoding="utf-8") as file:
            file.write(pretty_xml_str)
        logging.info(f"Global file '{global_file}' updated successfully.")

    # Generate JSON and YAML outputs
    json_file = global_file.replace(".xml", ".json")
    yaml_file = global_file.replace(".xml", ".yaml")
    logging.info(f"Generating JSON output at '{json_file}'...")
    convert_xml_to_json(global_file, json_file)
    logging.info(f"Generating YAML output at '{yaml_file}'...")
    convert_xml_to_yaml(global_file, yaml_file)

def create_insider_versions_xml(info_list, output_file):
    root = ET.Element("EdgeInsiderVersions")

    # Add last_updated element
    last_updated = ET.SubElement(root, "last_updated")
    last_updated.text = datetime.now(eastern).strftime(DATE_FORMAT)

    for info in info_list:
        entry = ET.SubElement(root, "Version")
        ET.SubElement(entry, "Name").text = info["channel"]
        ET.SubElement(entry, "Version").text = info["version"]
        ET.SubElement(entry, "Application_ID").text = "EDGE01"
        ET.SubElement(entry, "Application_Name").text = "Microsoft Edge.app"
        ET.SubElement(entry, "CFBundleVersion").text = "com.microsoft.edgemac"
        ET.SubElement(entry, "Full_Update_Download").text = info["location"]

        # Generate hashes for the location URL
        sha1, sha256 = generate_hashes(info["location"])
        ET.SubElement(entry, "Full_Update_Sha1").text = sha1
        ET.SubElement(entry, "Full_Update_Sha256").text = sha256

        ET.SubElement(entry, "Last_Update").text = info["date"]

    xml_str = ET.tostring(root, encoding='utf-8')
    pretty_xml_str = minidom.parseString(xml_str).toprettyxml(indent="  ")

    with open(output_file, "w", encoding="utf-8") as file:
        file.write(pretty_xml_str)
    logging.info(f"Insider versions file '{output_file}' written successfully.")

def _etree_to_dict(t):
    d = {t.tag: {} if t.attrib else None}
    children = list(t)
    if children:
        dd = defaultdict(list)
        for dc in map(_etree_to_dict, children):
            for k, v in dc.items():
                dd[k].append(v)
        d = {t.tag: {k: v[0] if len(v) == 1 else v for k, v in dd.items()}}
    if t.attrib:
        d[t.tag].update(('@' + k, v) for k, v in t.attrib.items())
    if t.text:
        text = t.text.strip()
        if children or t.attrib:
            if text:
                d[t.tag]['#text'] = text
        else:
            d[t.tag] = text
    return d

def convert_xml_to_json(xml_file, json_file):
    tree = ET.parse(xml_file)
    data_dict = _etree_to_dict(tree.getroot())
    with open(json_file, "w", encoding="utf-8") as file:
        json.dump(data_dict, file, indent=4)
    logging.info(f"JSON file '{json_file}' written successfully.")

def convert_xml_to_yaml(xml_file, yaml_file):
    tree = ET.parse(xml_file)
    data_dict = _etree_to_dict(tree.getroot())

    # Create a new dictionary with the desired order
    if "EdgeLatestVersions" in data_dict:
        edge_versions = data_dict["EdgeLatestVersions"]
        ordered_dict = {
            "EdgeLatestVersions": {
                "last_updated": edge_versions.get("last_updated", ""),
                "Version": edge_versions.get("Version", [])
            }
        }
        data_dict = ordered_dict

    with open(yaml_file, "w", encoding="utf-8") as file:
        yaml.dump(data_dict, file, default_flow_style=False, sort_keys=False)
    logging.info(f"YAML file '{yaml_file}' written successfully.")

def convert_plist_to_json(xml_file, json_file):
    try:
        with open(xml_file, 'rb') as file:
            plist_data = plistlib.load(file)

        # Add last_updated field
        output_data = {
            "last_updated": datetime.now(eastern).strftime(DATE_FORMAT),
            "plist_data": plist_data
        }

        with open(json_file, 'w', encoding="utf-8") as f:
            json.dump(output_data, f, indent=2, default=str)
        logging.info(f"JSON file '{json_file}' written successfully.")
    except Exception as e:
        logging.error(f"Could not convert plist to JSON: {e}")

def convert_plist_to_yaml(xml_file, yaml_file):
    try:
        with open(xml_file, 'rb') as file:
            plist_data = plistlib.load(file)

        # Add last_updated field
        output_data = {
            "last_updated": datetime.now(eastern).strftime(DATE_FORMAT),
            "plist_data": plist_data
        }

        with open(yaml_file, 'w', encoding="utf-8") as f:
            yaml.dump(output_data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
        logging.info(f"YAML file '{yaml_file}' written successfully.")
    except Exception as e:
        logging.error(f"Could not convert plist to YAML: {e}")

def main(output_dir=None):
    """Refresh the Edge feed in output_dir (default ./latest_raw_files). Returns an exit code."""
    logging.info("Starting Edge version update process...")
    if output_dir is None:
        output_dir = os.path.join(os.getcwd(), "latest_raw_files")
    os.makedirs(output_dir, exist_ok=True)
    global_file = os.path.join(output_dir, "macos_standalone_edge_all.xml")
    cached_channels = cached_channel_names(global_file)
    if cached_channels is None:
        # Rewriting would drop every cached channel; leave the feed for review.
        logging.error(f"Leaving the Edge feed in '{output_dir}' unchanged.")
        return 1

    info_list = []
    for channel, url in CHANNELS.items():
        logging.info(f"Fetching data for channel: {channel}")
        info = fetch_edge_insider_version(url, channel)
        if info:
            logging.info(f"Checking if update is needed for channel '{channel}'...")
            if should_update_channel(global_file, channel, info["date"]):
                info_list.append(info)
            else:
                logging.info(f"No updates performed for channel: {channel}")
        elif channel in cached_channels:
            logging.warning(f"No data fetched for channel '{channel}'; keeping its cached entry.")
        else:
            logging.error(f"No data fetched for channel '{channel}' and no cached entry; it is missing from the feed.")

    if info_list:
        logging.info("Updating global file with new channel data...")
        update_global_file(global_file, info_list)
    else:
        logging.info("No updates needed for any channel.")
        # Always update last_updated field even if no channel data changed
        if os.path.isfile(global_file):
            update_last_updated_in_xml(global_file)
            # Regenerate JSON and YAML to reflect new last_updated
            json_file = global_file.replace(".xml", ".json")
            yaml_file = global_file.replace(".xml", ".yaml")
            logging.info(f"Regenerating JSON output at '{json_file}'...")
            convert_xml_to_json(global_file, json_file)
            logging.info(f"Regenerating YAML output at '{yaml_file}'...")
            convert_xml_to_yaml(global_file, yaml_file)
    logging.info("Edge version update process completed.")
    return 0

if __name__ == "__main__":
    # Configured here, not at import, so importing this module leaves the
    # importer's logging alone.
    logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
    raise SystemExit(main())
