import requests
from http_client import get as http_get
from bs4 import BeautifulSoup
import xml.etree.ElementTree as ET
from xml.dom import minidom
from datetime import datetime
import pytz
import logging
import json
import yaml

# Configure logging with a cleaner and more human-readable format
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%B %d, %Y %I:%M %p'
)

def scrape_office_mac_updates(url):
    try:
        logging.info("Starting the scraping process.")

        # Send a GET request to the URL
        response = http_get(url, timeout=30)
        response.raise_for_status()  # Raise an exception for HTTP errors
        logging.info("Successfully fetched the URL.")

        # Parse the HTML content with BeautifulSoup
        soup = BeautifulSoup(response.text, 'html.parser')

        # Identify the correct table by its headers
        tables = soup.find_all('table')  # Get all tables
        target_table = None

        # Iterate through tables to find the one with desired headers
        for table in tables:
            headers = [header.text.strip() for header in table.find_all('th')]
            if headers == ["Release date", "Version", "Install package", "Update packages"]:
                target_table = table
                break

        if not target_table:
            logging.warning("Target table not found on the page.")
            return

        logging.info("Target table found.")

        # Extract rows from the target table
        rows = []
        for row in target_table.find_all('tr')[1:]:  # Skip the header row
            cells = row.find_all(['td', 'th'])
            row_data = {}
            for i, cell in enumerate(cells):
                links = cell.find_all('a')
                if links:
                    row_data[headers[i]] = [{"name": link.text.strip(), "url": link['href']} for link in links]
                else:
                    row_data[headers[i]] = [{"name": cell.text.strip(), "url": "NA"}]
            rows.append(row_data)

        logging.info("Extracted rows from the target table.")

        # Save the data to an XML file
        root = ET.Element("Releases")

        # Add last scan date in a human-readable format with time zone
        eastern = pytz.timezone('US/Eastern')
        last_scan_date = ET.SubElement(root, "last_scan_date")
        last_scan_date.text = datetime.now(eastern).strftime("%B %d, %Y %I:%M %p %Z")

        for row in rows:
            release = ET.SubElement(root, "release")
            has_links = False

            # Map row data to specific XML elements
            for key, values in row.items():
                if key == "Release date":
                    ET.SubElement(release, "date").text = values[0].get("name", "NA")
                elif key == "Version":
                    version = values[0].get("name", "NA")
                    ET.SubElement(release, "version").text = version
                elif key == "Install package":
                    for value in values:
                        if "with teams" in value["name"].lower():
                            ET.SubElement(release, "businesspro_suite_download").text = value.get("url", "NA")
                            has_links = True
                        elif "without teams" in value["name"].lower():
                            ET.SubElement(release, "suite_download").text = value.get("url", "NA")
                            has_links = True
                elif key == "Update packages":
                    for value in values:
                        if value.get("url", "NA") != "NA":
                            tag_name = f"{value['name'].lower().replace(' ', '_')}_update"
                            app_update = ET.SubElement(release, tag_name)
                            app_update.text = value.get("url", "NA")
                            has_links = True

            # Set archive to true if no links are present
            ET.SubElement(release, "archive").text = "false" if has_links else "true"

        logging.info("Mapped row data to XML elements.")

        # Pretty-print the XML
        xml_str = ET.tostring(root, encoding="utf-8")
        pretty_xml = minidom.parseString(xml_str).toprettyxml(indent="    ")

        # Write the pretty XML to a file
        xml_file = "latest_raw_files/macos_standalone_update_history.xml"
        with open(xml_file, "w", encoding="utf-8") as f:
            f.write(pretty_xml)

        logging.info(f"Data saved to {xml_file}")

        # Convert XML data to JSON and YAML
        tree = ET.ElementTree(ET.fromstring(xml_str))
        root = tree.getroot()

        data = {
            "last_scan_date": root.find("last_scan_date").text,
            "releases": []
        }

        for release in root.findall("release"):
            release_data = {}
            for child in release:
                release_data[child.tag] = child.text
            data["releases"].append(release_data)

        # Write the JSON data to a file
        json_file = "latest_raw_files/macos_standalone_update_history.json"
        with open(json_file, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=4)
        logging.info(f"Data saved to {json_file}")

        # Write the YAML data to a file
        yaml_file = "latest_raw_files/macos_standalone_update_history.yaml"
        with open(yaml_file, "w", encoding="utf-8") as f:
            yaml.dump(data, f, default_flow_style=False, sort_keys=False)
        logging.info(f"Data saved to {yaml_file}")

    except requests.exceptions.RequestException as e:
        logging.warning(f"Error fetching the URL: {e}")
    except Exception as e:
        logging.warning(f"An error occurred: {e}")

# URL of the webpage to scrape
url = "https://learn.microsoft.com/en-us/officeupdates/update-history-office-for-mac"

# Call the scraping function
scrape_office_mac_updates(url)
