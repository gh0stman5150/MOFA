"""Generate latest_raw_files/macos_standalone_preview.{xml,yaml,json}.

Reads each app's Microsoft AutoUpdate preview-channel manifest, reuses the
cached entry when nothing changed and hashes each new installer once. A failed
fetch keeps the cached entry (WARNING); an app with no cached entry logs ERROR
so run_generators.py fails the run. Shared code lives in standalone_feed.py.

Run from the repository root: python .github/actions/generate_macos_standalone_preview.py
"""

import standalone_feed as feed

# Define app-specific configurations
apps = {
    "Word": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409MSWD2019.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.word",
        },
        "keys": {
            "application_id": "Application ID",
            "application_name": "Application Name",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "FullUpdaterLocation",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "FullUpdaterLocation"
        }
    },
    "Excel": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409XCEL2019.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.excel",
        },
        "keys": {
            "application_id": "Application ID",
            "application_name": "Application Name",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "FullUpdaterLocation",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "FullUpdaterLocation"
        }
    },
    "PowerPoint": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409PPT32019.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.powerpoint",
        },
        "keys": {
            "application_id": "Application ID",
            "application_name": "Application Name",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "FullUpdaterLocation",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "FullUpdaterLocation"
        }
    },
    "Outlook": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409OPIM2019.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.outlook",
        },
        "keys": {
            "application_id": "Application ID",
            "application_name": "Application Name",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "FullUpdaterLocation",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "FullUpdaterLocation"
        }
    },
    "OneNote": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409ONMC2019.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.onenote",
        },
        "keys": {
            "application_id": "Application ID",
            "application_name": "Application Name",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "FullUpdaterLocation",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "FullUpdaterLocation"
        }
    },
    # "OneDrive": { ######## MOVED OVER TO ITS OWN FILE MACOS_STANDALONE_ONEDRIVE_LATEST.* ########
    #     "url": "https://g.live.com/0USSDMC_W5T/MacODSUInsiders",
    #     "manual_entries": {
    #         "CFBundleVersion": "com.microsoft.onedrive",
    #         "application_name": "OneDrive.app",
    #         "min_os": "N/A",
    #         "last_updated": "N/A",
    #         "application_id": "OneDrive.app"
    #     },
    #     "keys": {
    #         "latest_download": "PkgBinaryURL",
    #         "short_version": "CFBundleShortVersionString",
    #         "full_version": "CFBundleVersion",
    #         "update_download": "PkgBinaryURL"
    #     }
    # },
    "Skype": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409MSFB16.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.skypeforbusiness",
            "application_name": "Skype for Business.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "Location"
        }
    },
    "Teams": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409TEAMS21.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.teams",
            "application_name": "Microsoft Teams.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "Location"
        }
    },    "Intune": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409IMCP01.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.intune.companyportal",
            "application_name": "Company Portal.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS Version",
            "latest_download": "Location"
        }
    },
    "Edge": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409EDGE01.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.edgemac",
            "application_name": "Microsoft Edge.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "Location"
        }
    },
    "Defender For Endpoint": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409WDAV00.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.defender.endpoint",
            "application_name": "Microsoft Defender.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "Location"
        }
    },
    "Defender For Consumers": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409WDAVCONSUMER.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.defender.endpoint",
            "application_name": "Microsoft Defender.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "Location"
        }
    },
    "Defender Shim": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409WDAVSHIM.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.defender.endpoint",
            "application_name": "Microsoft Defender.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "Location"
        }
    },
    "Visual": {
        "url": "https://update.code.visualstudio.com/api/update/darwin-universal/insider/92d25e35d9bf1a6b16f7d0758f25d48ace11e5b9",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.VSCodeInsiders",
            "latest_download": "https://code.visualstudio.com/sha/download?build=insider&os=darwin-universal",
            "application_name": "Visual Studio Code - Insiders.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "name",
            "full_version": "productVersion",
            "update_download": "url",
            "last_updated": "timestamp",
            "min_os": "Minimum OS"
        }
    },
    "Copilot": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409MSCP10.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.m365copilot",
            "application_name": "Microsoft 365 Copilot.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "Location"
        }
    },
    "MAU": {
        "url": "https://officecdnmac.microsoft.com/pr/1ac37578-5a24-40fb-892e-b89d85b6dfaa/MacAutoupdate/0409MSau04.xml",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.autoupdate",
            "application_name": "Microsoft AutoUpdate.app",
        },
        "keys": {
            "application_id": "Application ID",
            "short_version": "Title",
            "full_version": "Update Version",
            "update_download": "Location",
            "last_updated": "Date",
            "min_os": "Minimum OS",
            "latest_download": "Location"
        }
    }
}

OUTPUT_FILE = "latest_raw_files/macos_standalone_preview.xml"

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
    "update_download",
    "latest_download",
    "sha1",
    "sha256",
]


def fetch_and_process(app_name, config, run):
    feed.fetch_and_process(app_name, config, run, feed.add_download_hashes)


def main(output_file=OUTPUT_FILE):
    feed.run_generator(apps, FIELD_ORDER, output_file, fetch_and_process)
    return 0


if __name__ == "__main__":
    feed.configure_logging()
    raise SystemExit(main())
