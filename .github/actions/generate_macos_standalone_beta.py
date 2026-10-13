"""Generate latest_raw_files/macos_standalone_beta.{xml,yaml,json}.

Reads each app's Microsoft AutoUpdate beta-channel manifest, or the App Center
release list for "type": "appcenter" entries, reuses the cached entry when
nothing changed and hashes each new installer once. A failed fetch keeps the
cached entry (WARNING); an app with no cached entry logs ERROR so
run_generators.py fails the run. Shared code lives in standalone_feed.py.

Run from the repository root: python .github/actions/generate_macos_standalone_beta.py
"""

import logging

import standalone_feed as feed

# Define app-specific configurations
apps = {
    "Word": {
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409MSWD2019.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409XCEL2019.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409PPT32019.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409OPIM2019.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409ONMC2019.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409MSFB16.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409TEAMS21.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409IMCP01.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409EDGE01.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409WDAV00.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409WDAVCONSUMER.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409WDAVSHIM.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409MSCP10.xml",
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
        "url": "https://officecdnmac.microsoft.com/pr/4B2D7701-0A4F-49C8-B4CB-0C2D4043F51F/MacAutoupdate/0409MSau04.xml",
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
    },
    "Windows App Beta": {
        "type": "appcenter",
        "base": "https://install.appcenter.ms/api/v0.1/apps/rdmacios-k2vy/microsoft-remote-desktop-for-mac/distribution_groups/all-users-of-microsoft-remote-desktop-for-mac",
        "manual_entries": {
            "CFBundleVersion": "com.microsoft.windows.app",
            "application_name": "Windows App Beta.app",
            "application_id": "N/A",
            "min_os": "N/A"
        },
        "keys": {
            "short_version": "short_version",
            "full_version": "short_version",
            "last_updated": "uploaded_at",
            "update_download": "download_url",
            "latest_download": "download_url"
        }
    }
}

OUTPUT_FILE = "latest_raw_files/macos_standalone_beta.xml"

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


def fetch_appcenter_data(app_name, config):
    """App Center is two JSON requests: the public release list, then the newest release."""
    base = config.get("base")
    if not base:
        raise ValueError(f"Missing 'base' for App Center app: {app_name}")

    list_url = f"{base}/public_releases"
    logging.info(f"Fetching App Center releases for {app_name} from {list_url}...")
    list_resp = feed.http_get(list_url, timeout=30)
    list_resp.raise_for_status()
    releases = list_resp.json()
    if not releases:
        raise ValueError(f"No App Center releases found for {app_name} (group may be private).")

    release_id = releases[0].get("id")
    if not release_id:
        raise ValueError(f"Latest App Center release missing 'id' for {app_name}.")

    detail_url = f"{base}/releases/{release_id}"
    logging.info(f"Fetching App Center release details for {app_name} from {detail_url}...")
    detail_resp = feed.http_get(detail_url, timeout=30)
    detail_resp.raise_for_status()
    return feed.process_json_data(detail_resp.json(), config)


def fetch_and_process(app_name, config, run):
    if config.get("type") == "appcenter":
        # App Center build metadata changes between requests; only a new
        # short_version counts as an update.
        feed.fetch_and_process(
            app_name,
            config,
            run,
            feed.add_download_hashes,
            fetch=fetch_appcenter_data,
            compare_keys=("short_version",),
        )
    else:
        feed.fetch_and_process(app_name, config, run, feed.add_download_hashes)


def main(output_file=OUTPUT_FILE):
    feed.run_generator(apps, FIELD_ORDER, output_file, fetch_and_process)
    return 0


if __name__ == "__main__":
    feed.configure_logging()
    raise SystemExit(main())
