from bs4 import BeautifulSoup
import requests
import xml.etree.ElementTree as ET
from xml.dom import minidom
import logging
from datetime import datetime
import pytz
import json
import yaml
import os

# Configure logging with a cleaner and more human-readable format
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%B %d, %Y %I:%M %p'
)

url = 'https://learn.microsoft.com/en-us/officeupdates/release-notes-office-for-mac'  # URL to fetch HTML data

# Fetch the HTML content
logging.info('Fetching HTML content from URL: %s', url)
response = requests.get(url, timeout=30)
html_data = response.text
logging.info('HTML content fetched successfully')

# Parse the HTML content
logging.info('Parsing HTML content')
soup = BeautifulSoup(html_data, 'html.parser')

# Initialize an empty list to store parsed data
parsed_data = []

# Loop through each <h2> to get the date and version info
for h2 in soup.find_all('h2'):
    # Get the h2 id (the date)
    date_id = h2.get('id', '')
    date_text = h2.get_text(strip=True)

    # Skip if the date is not a valid date
    try:
        datetime.strptime(date_text, '%B %d, %Y')
    except ValueError:
        logging.warning('Skipping invalid date: %s', date_text)
        continue

    # Stop if the date is January 14, 2020
    if date_text == "December 10, 2019":
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
                    # Get all the links in the <ul>
                    links = ul_tag.find_all('a')
                    for link in links:
                        url = link['href']
                        cve_name = link.get_text(strip=True)

                        # Store CVE updates grouped by application
                        if app_name not in section_data['security_updates']:
                            section_data['security_updates'][app_name] = []

                        section_data['security_updates'][app_name].append({
                            'cve_name': cve_name,
                            'url': url
                        })

    # If no security updates were found, add a placeholder
    if not section_data['security_updates']:
        section_data['security_updates'] = {'N/A': [{'cve_name': 'N/A', 'url': None}]}

    parsed_data.append(section_data)
    logging.info('Parsed data for date: %s', date_text)

# Create the root element for the XML
root = ET.Element('Updates')

# Add the last scan date at the top
last_scan_date = datetime.now(pytz.timezone('US/Eastern')).strftime('%B %d, %Y %I:%M %p %Z')
last_scan_elem = ET.SubElement(root, 'last_scan_date')
last_scan_elem.text = last_scan_date

# Add last_scan_date to parsed_data
parsed_data_with_date = {
    'last_scan_date': last_scan_date,
    'updates': parsed_data
}

# Loop through each section and build the XML structure
for section in parsed_data:
    update_elem = ET.SubElement(root, 'Update')
    date_elem = ET.SubElement(update_elem, 'Date')
    date_elem.text = section['date_text']
    version_elem = ET.SubElement(update_elem, 'Version')
    version_elem.text = section['version']

    security_updates_elem = ET.SubElement(update_elem, 'SecurityUpdates')
    if section['security_updates'] == {'N/A': [{'cve_name': 'N/A', 'url': None}]}:
        application_elem = ET.SubElement(security_updates_elem, 'Application')
        name_elem = ET.SubElement(application_elem, 'Name')
        name_elem.text = 'N/A'
        cve_elem = ET.SubElement(application_elem, 'CVE')
        cve_elem.text = 'N/A'
        url_elem = ET.SubElement(application_elem, 'URL')
        url_elem.text = 'N/A'
    else:
        for app_name, updates in section['security_updates'].items():
            application_elem = ET.SubElement(security_updates_elem, 'Application')
            name_elem = ET.SubElement(application_elem, 'Name')
            name_elem.text = app_name
            for update in updates:
                cve_elem = ET.SubElement(application_elem, 'CVE')
                cve_elem.text = update['cve_name']
                url_elem = ET.SubElement(application_elem, 'URL')
                url_elem.text = update['url'] if update['url'] else 'N/A'

# Convert the XML tree to a string
xml_str = ET.tostring(root, encoding='utf-8')

# Pretty print the XML
pretty_xml_str = minidom.parseString(xml_str).toprettyxml(indent="    ")

# Write the pretty XML to a file
output_file = 'latest_raw_files/mac_standalone_cve_history.xml'
with open(output_file, 'w') as f:
    f.write(pretty_xml_str)
logging.info('XML data written to file: %s', output_file)

# Ensure the JSON file is deleted before writing new data
json_output_file = 'latest_raw_files/mac_standalone_cve_history.json'
if os.path.exists(json_output_file):
    os.remove(json_output_file)
with open(json_output_file, 'w') as f:
    json.dump(parsed_data_with_date, f, indent=4)
logging.info('JSON data written to file: %s', json_output_file)

# Ensure the YAML file is deleted before writing new data
yaml_output_file = 'latest_raw_files/mac_standalone_cve_history.yaml'
if os.path.exists(yaml_output_file):
    os.remove(yaml_output_file)
with open(yaml_output_file, 'w') as f:
    yaml.dump(parsed_data_with_date, f, default_flow_style=False)
logging.info('YAML data written to file: %s', yaml_output_file)
