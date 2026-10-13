"""Generate latest_raw_files/ios_appstore_latest.{xml,json,yaml} from the iOS App Store.

Each entry below is an iTunes Search API query (entity=software). The first
result published by Microsoft (sellerName or artistName contains "Microsoft")
is used; add "bundle_id": "<exact bundle ID>" to an entry to require that app
instead. A failed request keeps the cached entry (WARNING); a search with no
Microsoft match keeps the cached entry and logs ERROR, which fails
run_generators.py until the entry is corrected. Shared code lives in
appstore_feed.py.

Run from the repository root: python .github/actions/generate_ios_appstore_latest.py
"""

import appstore_feed as feed

OUTPUT_BASENAME = "ios_appstore_latest"

# Feed field -> iTunes Search API result key.
common_keys = feed.COMMON_KEYS

# Define app-specific configurations
apps = {
    "iOS Microsoft Word": {
        "url": "https://itunes.apple.com/search?term=microsoft-word&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Excel": {
        "url": "https://itunes.apple.com/search?term=microsoft-excel&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft PowerPoint": {
        "url": "https://itunes.apple.com/search?term=microsoft-powerpoint&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Outlook": {
        "url": "https://itunes.apple.com/search?term=microsoft-outlook&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft OneNote": {
        "url": "https://itunes.apple.com/search?term=microsoft-onenote&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft OneDrive": {
        "url": "https://itunes.apple.com/search?term=microsoft-onedrive&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Windows App Mobile": {
        "url": "https://itunes.apple.com/search?term=windows-app-mobile&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Defender Security": {
        "url": "https://itunes.apple.com/search?term=microsoft-defender-security&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Copilot": {
        "url": "https://itunes.apple.com/search?term=microsoft-copilot&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Loop": {
        "url": "https://itunes.apple.com/search?term=microsoft-loop&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Warehouse Management": {
        "url": "https://itunes.apple.com/search?term=microsoft-warehouse-management&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Store Commerce": {
        "url": "https://itunes.apple.com/search?term=store-commerce&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Dynamics 365 Sales": {
        "url": "https://itunes.apple.com/search?term=dynamics-365-sales&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Lists": {
        "url": "https://itunes.apple.com/search?term=microsoft-lists&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Dynamics 365 Field Service": {
        "url": "https://itunes.apple.com/search?term=dynamics-365-field-service&country=us&entity=software",
        "keys": common_keys
    },
    ### These are constantly not available for App Store
    # "iOS Microsoft Dynamics 365 Remote Assist": {
    #     "url": "https://itunes.apple.com/search?term=dynamics-365-remote-assist&country=us&entity=software",
    #     "keys": common_keys
    # },
    # "iOS Microsoft Dynamics 365 Project Timesheet": {
    #     "url": "https://itunes.apple.com/search?term=dynamics-365-remote-assist&country=us&entity=software",
    #     "keys": common_keys
    # },
    "iOS Microsoft Viva Engage": {
        "url": "https://itunes.apple.com/search?term=viva-engage&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Whiteboard": {
        "url": "https://itunes.apple.com/search?term=whiteboard&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Edge AI Browser": {
        "url": "https://itunes.apple.com/search?term=edge-ai-browser&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Seeing AI": {
        "url": "https://itunes.apple.com/search?term=seeing-ai&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Planner": {
        "url": "https://itunes.apple.com/search?term=microsoft-planner&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Azure": {
        "url": "https://itunes.apple.com/search?term=microsoft-azure&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft To-Do": {
        "url": "https://itunes.apple.com/search?term=microsoft-to-do&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Teams": {
        "url": "https://itunes.apple.com/search?term=microsoft-teams&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Sharepoint": {
        "url": "https://itunes.apple.com/search?term=microsoft-sharepoint&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Dynamics 365 Business Central": {
        "url": "https://itunes.apple.com/search?term=dynamics-365-business-central&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Power Apps": {
        "url": "https://itunes.apple.com/search?term=power-apps&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Authenticator": {
        "url": "https://itunes.apple.com/search?term=microsoft-authenticator&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Advertising": {
        "url": "https://itunes.apple.com/search?term=microsoft-advertising&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Lens PDF Scanner": {
        "url": "https://itunes.apple.com/search?term=microsoft-lens-pdf-scanner&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Work Folders": {
        "url": "https://itunes.apple.com/search?term=work-folders&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Power BI": {
        "url": "https://itunes.apple.com/search?term=microsoft-power-bi&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft 365 Admin": {
        "url": "https://itunes.apple.com/search?term=microsoft-365-admin&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Intune Company Portal": {
        "url": "https://itunes.apple.com/search?term=intune-company-portal&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Azure Information Protection": {
        "url": "https://itunes.apple.com/search?term=azure-information-protection&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft 365 Office": {
        "url": "https://itunes.apple.com/search?term=microsoft-365-office&country=us&entity=software",
        "keys": common_keys
    },
    "iOS Microsoft Skype for Business": {
        "url": "https://itunes.apple.com/search?term=skype-for-business&country=us&entity=software",
        "keys": common_keys
    }
}


def main(output_dir="latest_raw_files"):
    return feed.run(apps, OUTPUT_BASENAME, output_dir)


if __name__ == "__main__":
    feed.configure_logging()
    raise SystemExit(main())
