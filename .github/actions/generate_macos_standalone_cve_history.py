"""Generate latest_raw_files/mac_standalone_cve_history.{xml,json,yaml}.

Scrapes the Office for Mac release notes on Microsoft Learn for each release
date, version and the CVEs listed under its security updates. The page is the
only source for the whole feed, so an HTTP error (after http_client's
retries) or a page with no release sections logs ERROR, writes nothing and
exits 1, which fails run_generators.py.

Run from the repository root: python .github/actions/generate_macos_standalone_cve_history.py
"""

from bs4 import BeautifulSoup
from http_client import get as http_get
import xml.etree.ElementTree as ET
from xml.dom import minidom
import logging
from datetime import datetime
import pytz
import json
import requests
import yaml
import os

URL = 'https://learn.microsoft.com/en-us/officeupdates/release-notes-office-for-mac'  # URL to fetch HTML data
OUTPUT_DIR = 'latest_raw_files'
STOP_DATE = "December 10, 2019"
NO_UPDATES = {'N/A': [{'cve_name': 'N/A', 'url': None}]}


def fetch_html(url):
    """Return the page HTML, or None (ERROR logged) for an HTTP error."""
    logging.info('Fetching HTML content from URL: %s', url)
    try:
        response = http_get(url, timeout=30)
        # An error or maintenance page must fail the run, not be parsed into an
        # empty feed that would replace the published CVE history.
        response.raise_for_status()
    except requests.RequestException as e:
        logging.error('Could not fetch %s: %s; keeping the existing CVE history files.', url, e)
        return None
    logging.info('HTML content fetched successfully')
    return response.text


def parse_cve_sections(html_data):
    """Return one dict per dated release section, newest first, down to STOP_DATE."""
    logging.info('Parsing HTML content')
    soup = BeautifulSoup(html_data, 'html.parser')

    # Initialize an empty list to store parsed data
    parsed_data = []

    # Loop through each <h2> to get the date and version info
    for h2 in soup.find_all('h2'):
        date_text = h2.get_text(strip=True)

        # Skip if the date is not a valid date
        try:
            datetime.strptime(date_text, '%B %d, %Y')
        except ValueError:
            logging.warning('Skipping invalid date: %s', date_text)
            continue

        # Stop at the oldest release this feed covers
        if date_text == STOP_DATE:
            logging.info('Reached the stopping date: %s', date_text)
            break

        # Get the version (inside <em> tag after h2)
        em_tag = h2.find_next('em')
        version = em_tag.get_text(strip=True) if em_tag else None

        # Initialize a dictionary to store data for this section
        section_data = {
            'date_text': date_text,
            'version': version,
            'security_updates': {}
        }

        # Loop through all subsequent h3 tags after h2
        for h3 in h2.find_all_next('h3'):
            # Stop if we reach another <h2> (this means the current section ends)
            if h3.find_previous('h2') != h2:
                break

            # Check if the <h3> contains 'security updates' in the title (not the id)
            if 'security updates' in h3.get_text(strip=True).lower():
                # Loop through the next h3 tags for application names
                next_h3 = h3.find_next_siblings('h3')
                for app_h3 in next_h3:
                    # Stop at the next "security updates" or another <h2>
                    if 'security updates' in app_h3.get_text(strip=True).lower() or app_h3.find_previous('h2') != h2:
                        break

                    # Extract the application name (e.g., Excel, Word)
                    app_name = app_h3.get_text(strip=True)

                    # Find the <ul> element containing the CVE links for this app
                    ul_tag = app_h3.find_next('ul')
                    if ul_tag:
                        for link in ul_tag.find_all('a'):
                            # Store CVE updates grouped by application
                            section_data['security_updates'].setdefault(app_name, []).append({
                                'cve_name': link.get_text(strip=True),
                                'url': link['href']
                            })

        # If no security updates were found, add a placeholder
        if not section_data['security_updates']:
            section_data['security_updates'] = {'N/A': [{'cve_name': 'N/A', 'url': None}]}

        parsed_data.append(section_data)
        logging.info('Parsed data for date: %s', date_text)

    return parsed_data


def build_xml(parsed_data, last_scan_date):
    # Create the root element for the XML, with the last scan date at the top
    root = ET.Element('Updates')
    ET.SubElement(root, 'last_scan_date').text = last_scan_date

    # Loop through each section and build the XML structure
    for section in parsed_data:
        update_elem = ET.SubElement(root, 'Update')
        ET.SubElement(update_elem, 'Date').text = section['date_text']
        ET.SubElement(update_elem, 'Version').text = section['version']

        security_updates_elem = ET.SubElement(update_elem, 'SecurityUpdates')
        if section['security_updates'] == NO_UPDATES:
            application_elem = ET.SubElement(security_updates_elem, 'Application')
            ET.SubElement(application_elem, 'Name').text = 'N/A'
            ET.SubElement(application_elem, 'CVE').text = 'N/A'
            ET.SubElement(application_elem, 'URL').text = 'N/A'
        else:
            for app_name, updates in section['security_updates'].items():
                application_elem = ET.SubElement(security_updates_elem, 'Application')
                ET.SubElement(application_elem, 'Name').text = app_name
                for update in updates:
                    ET.SubElement(application_elem, 'CVE').text = update['cve_name']
                    ET.SubElement(application_elem, 'URL').text = update['url'] if update['url'] else 'N/A'
    return root


def write_outputs(parsed_data, output_dir=OUTPUT_DIR):
    last_scan_date = datetime.now(pytz.timezone('US/Eastern')).strftime('%B %d, %Y %I:%M %p %Z')
    parsed_data_with_date = {
        'last_scan_date': last_scan_date,
        'updates': parsed_data
    }

    # Pretty print the XML
    xml_str = ET.tostring(build_xml(parsed_data, last_scan_date), encoding='utf-8')
    pretty_xml_str = minidom.parseString(xml_str).toprettyxml(indent="    ")

    # Write the pretty XML to a file
    output_file = os.path.join(output_dir, 'mac_standalone_cve_history.xml')
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(pretty_xml_str)
    logging.info('XML data written to file: %s', output_file)

    # Ensure the JSON file is deleted before writing new data
    json_output_file = os.path.join(output_dir, 'mac_standalone_cve_history.json')
    if os.path.exists(json_output_file):
        os.remove(json_output_file)
    with open(json_output_file, 'w', encoding='utf-8') as f:
        json.dump(parsed_data_with_date, f, indent=4)
    logging.info('JSON data written to file: %s', json_output_file)

    # Ensure the YAML file is deleted before writing new data
    yaml_output_file = os.path.join(output_dir, 'mac_standalone_cve_history.yaml')
    if os.path.exists(yaml_output_file):
        os.remove(yaml_output_file)
    with open(yaml_output_file, 'w', encoding='utf-8') as f:
        yaml.dump(parsed_data_with_date, f, default_flow_style=False)
    logging.info('YAML data written to file: %s', yaml_output_file)


def main(url=URL, output_dir=OUTPUT_DIR):
    html_data = fetch_html(url)
    if html_data is None:
        return 1
    parsed_data = parse_cve_sections(html_data)
    if not parsed_data:
        logging.error('No release sections were parsed from %s; keeping the existing CVE history files.', url)
        return 1
    write_outputs(parsed_data, output_dir)
    return 0


if __name__ == "__main__":
    # Configure logging with a cleaner and more human-readable format
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        datefmt='%B %d, %Y %I:%M %p'
    )
    raise SystemExit(main())
