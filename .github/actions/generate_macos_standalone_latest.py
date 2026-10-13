"""Generate latest_raw_files/macos_standalone_latest.{xml,yaml,json}.

Reads each app's Microsoft AutoUpdate production manifest (or JSON endpoint),
reuses the cached entry and its hashes when nothing changed, and streams each
new installer once to compute its SHA1 and SHA256. A failed fetch keeps the
cached entry (WARNING); an app with no cached entry to fall back on logs ERROR
so run_generators.py fails the run. Shared code lives in standalone_feed.py.

Run from the repository root: python .github/actions/generate_macos_standalone_latest.py
"""

import standalone_feed as feed

# Define app-specific configurations
apps = {
    "Microsoft Office Suite": {
        "url": "https://officecdnmac.microsoft.com/pr/A1E15C18-4D18-40B0-8577-616A9470BB10/MacAutoUpdate/0409OPIM2019.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.office",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=525133",
            "application_id": "Data sourced from Outlook (CurrentThrottle)",
            "application_name": "Data sourced from Outlook (CurrentThrottle)",
        },
        "keys": {
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "NA",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "Microsoft BusinessPro Suite": {
        "url": "https://officecdnmac.microsoft.com/pr/A1E15C18-4D18-40B0-8577-616A9470BB10/MacAutoUpdate/0409OPIM2019.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.office",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=2009112",
            "application_id": "Data sourced from Outlook (CurrentThrottle)",
            "application_name": "Data sourced from Outlook (CurrentThrottle)",
        },
        "keys": {
           "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "NA",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "Word": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409MSWD2019.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.word",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=525134",
        },
        "keys": {
            "application_id": "Application ID",
            "application_name": "Application Name",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "FullUpdaterLocation",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "Excel": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409XCEL2019.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.excel",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=525135",
        },
        "keys": {
            "application_id": "Application ID",
            "application_name": "Application Name",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "FullUpdaterLocation",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "PowerPoint": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409PPT32019.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.powerpoint",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=525136",
        },
        "keys": {
            "application_id": "Application ID",
            "application_name": "Application Name",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "FullUpdaterLocation",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "Outlook": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409OPIM2019.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.outlook",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=2228621",
        },
        "keys": {
            "application_id": "Application ID",
            "application_name": "Application Name",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "FullUpdaterLocation",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "OneNote": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409ONMC2019.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.onenote",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=820886",
        },
        "keys": {
            "application_id": "Application ID",
            "application_name": "Application Name",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "FullUpdaterLocation",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    # "OneDrive": { ######## MOVED OVER TO ITS OWN FILE MACOS_STANDALONE_ONEDRIVE_LATEST.* ########
    #     "url": "https://g.live.com/0USSDMC_W5T/MacODSUProduction",
    #     "manual_entries": {
    #         "CFBundleVersion": "com.microsoft.onedrive",
    #         "application_name": "OneDrive.app",
    #         "min_os": "N/A",
    #         "last_updated": "N/A",
    #         "application_id": "OneDrive.app"
    #     },
    #     "keys": {
    #         "full_update_download": "PkgBinaryURL",
    #         "short_version": "CFBundleShortVersionString",
    #         "full_version": "CFBundleVersion",
    #         "app_only_update_download": "PkgBinaryURL"
    #     }
    # },
    "Skype": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409MSFB16.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.skypeforbusiness",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=832978",
            "application_name": "Skype for Business.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "Teams": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409TEAMS21.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.teams",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=2249065",
            "application_name": "Microsoft Teams.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },    "Intune": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409IMCP01.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.intune.companyportal",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=853070",
            "application_name": "Company Portal.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS Version"
        }
    },
    # "Edge": { ######## MOVED OVER TO ITS OWN FILE MACOS_STANDALONE_EDGE_LATEST.* ########
    #     "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409EDGE01.xml",
    #     "manual_entries": {
    #         "CFBundleVersion": "com.microsoft.edgemac",
    #         "full_update_download": "https://go.microsoft.com/fwlink/?linkid=2093504",
    #         "application_name": "Microsoft Edge.app",
    #     },
    #     "keys": {
    #         "application_id": "Application ID",
    #         "short_version": "Title",
    #         "full_version": "Update Version",
    #         "app_only_update_download": "Location",
    #         "last_updated": "Date",
    #         "min_os": "Minimum OS"
    #     }
    # },
    "Defender For Endpoint": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409WDAV00.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.defender.endpoint",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=2097502",
            "application_name": "Microsoft Defender.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "Defender for Consumers": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409WDAVCONSUMER.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.defender.endpoint",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=2247001",
            "application_name": "Microsoft Defender.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "Defender Shim": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409WDAVSHIM.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.defender.endpoint",
            "application_name": "N/A",
        },
        "keys": {
            "application_id": "Application ID",
            "full_update_download": "Location",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "Windows App": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409MSRD10.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.windows.app",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=868963",
            "application_name": "Windows App.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS Version"
        }
    },
    "Visual": {
        "url": "https://update.code.visualstudio.com/api/update/darwin-universal/stable/384ff7382de624fb94dbaf6da11977bba1ecd427",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.visualstudio",
            "full_update_download": "https://code.visualstudio.com/sha/download?build=stable&os=darwin-universal-dmg",
            "application_name": "Visual Studio Code.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "name",
            "full_version": "productVersion",
            "app_only_update_download": "url",
            "last_updated": "timestamp",
            "min_os": "Minimum OS"
        }
    },
    "Copilot": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409MSCP10.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.m365copilot",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=2325438",
            "application_name": "Microsoft 365 Copilot.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "MAU": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409MSau04.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.autoupdate",
            "full_update_download": "https://go.microsoft.com/fwlink/?linkid=830196",
            "application_name": "Microsoft AutoUpdate.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "Licensing Helper Tool": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409OLIC02.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.office.licensingV2.helper",
            "application_name": "N/A",
        },
        "keys": {
            "full_update_download": "Location",
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "app_only_update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "Quick Assist": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409MSQA01.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.quickassist",
        },
        "keys": {
            "full_update_download": "Location",
            "application_id": "Application ID",
            "application_name": "Application Name",
            "full_update_download": "Location",
            "short_version": "Update Version",
            "full_version": "Update Version",
            "app_only_update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    },
    "Remote Help": {
        "url": "https://officecdnmac.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/0409MSRH01.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.remotehelp"
        },
        "keys": {
            "full_update_download": "Location",
            "application_id": "Application ID",
            "application_name": "Application Name",
            "full_update_download": "Location",
            "short_version": "Update Version",
            "full_version": "Update Version",
            "app_only_update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS"
        }
    }
}

OUTPUT_FILE = "latest_raw_files/macos_standalone_latest.xml"

# Field order of each <package>, shared by the XML, YAML and JSON outputs.
FIELD_ORDER = [
    "name",
    "application_id",
    "application_name",
    "CFBundleVersion",
    "short_version",
    "full_version",
    "last_updated",
    "min_os",
    "app_only_update_download",
    "app_update_sha1",
    "app_update_sha256",
    "full_update_download",
    "full_update_sha1",
    "full_update_sha256",
]

# Set to True only for local testing: new or changed apps then get "N/A"
# hashes instead of downloading their installers.
skip_sha_checks = False


def add_hashes(extracted_data):
    """Fill the full-installer and app-only-update hashes of a new or changed app."""
    if skip_sha_checks:
        for key in ("full_update_sha1", "full_update_sha256", "app_update_sha1", "app_update_sha256"):
            extracted_data[key] = "N/A"
        return
    full_download_url = extracted_data.get("full_update_download")
    app_download_url = extracted_data.get("app_only_update_download")
    extracted_data["full_update_sha1"] = feed.compute_sha1(full_download_url) if full_download_url else "N/A"
    extracted_data["full_update_sha256"] = feed.compute_sha256(full_download_url) if full_download_url else "N/A"
    extracted_data["app_update_sha1"] = feed.compute_sha1(app_download_url) if app_download_url else "N/A"
    extracted_data["app_update_sha256"] = feed.compute_sha256(app_download_url) if app_download_url else "N/A"


def fetch_and_process(app_name, config, run):
    feed.fetch_and_process(app_name, config, run, add_hashes)


def main(output_file=OUTPUT_FILE):
    feed.run_generator(apps, FIELD_ORDER, output_file, fetch_and_process)
    return 0


if __name__ == "__main__":
    feed.configure_logging()
    raise SystemExit(main())
