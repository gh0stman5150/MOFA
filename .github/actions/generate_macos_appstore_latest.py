"""Generate latest_raw_files/macos_appstore_latest.{xml,json,yaml} from the Mac App Store.

Each entry below is an iTunes Search API query (entity=macSoftware). The first
result published by Microsoft (sellerName or artistName contains "Microsoft")
is used; add "bundle_id": "<exact bundle ID>" to an entry to require that app
instead. A failed request keeps the cached entry (WARNING); a search with no
Microsoft match keeps the cached entry and logs ERROR, which fails
run_generators.py until the entry is corrected. Shared code lives in
appstore_feed.py.

Run from the repository root: python .github/actions/generate_macos_appstore_latest.py
"""

import appstore_feed as feed

OUTPUT_BASENAME = "macos_appstore_latest"

# Feed field -> iTunes Search API result key.
common_keys = feed.COMMON_KEYS

# Define app-specific configurations
apps = {
    "MacOS Microsoft Word": {
        "url": "https://itunes.apple.com/search?term=microsoft-word&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Microsoft Excel": {
        "url": "https://itunes.apple.com/search?term=microsoft-excel&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Microsoft PowerPoint": {
        "url": "https://itunes.apple.com/search?term=microsoft-powerpoint&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Microsoft Outlook": {
        "url": "https://itunes.apple.com/search?term=microsoft-outlook&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Microsoft OneNote": {
        "url": "https://itunes.apple.com/search?term=microsoft-onenote&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Microsoft OneDrive": {
        "url": "https://itunes.apple.com/search?term=microsoft-onedrive&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS RMS Sharing": {
        "url": "https://itunes.apple.com/search?term=rms-sharing&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Microsoft Windows App": {
        "url": "https://itunes.apple.com/search?term=windows-app&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Microsoft To-Do": {
        "url": "https://itunes.apple.com/search?term=microsoft-to-do&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Microsoft CoPilot": {
        "url": "https://itunes.apple.com/search?term=microsoft-copilot&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Microsoft Azure VPN Client": {
        "url": "https://itunes.apple.com/search?term=azure-vpn-client&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Universal Print": {
        "url": "https://itunes.apple.com/search?term=universal-print&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Microsoft Rewards for Safari": {
        "url": "https://itunes.apple.com/search?term=microsoft-rewards-for-safari&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Microsoft Bing for Safari": {
        "url": "https://itunes.apple.com/search?term=microsoft-bing-for-safari&country=us&entity=macSoftware",
        "keys": common_keys
    },
    "MacOS Microsoft Accessory Updater": {
        "url": "https://itunes.apple.com/search?term=microsoft-accessory-updater&country=us&entity=macSoftware",
        "keys": common_keys
    }
}


def main(output_dir="latest_raw_files"):
    return feed.run(apps, OUTPUT_BASENAME, output_dir)


if __name__ == "__main__":
    feed.configure_logging()
    raise SystemExit(main())
