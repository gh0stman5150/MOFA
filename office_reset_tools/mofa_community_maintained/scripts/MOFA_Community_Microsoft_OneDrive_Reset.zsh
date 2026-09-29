#!/bin/zsh --no-rcs

# ============================================================
# Script Name: MOFA_Community_Microsoft_OneDrive_Reset.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets Microsoft OneDrive caches, preferences, containers and cached credentials,
#              and optionally repairs or reinstalls OneDrive.
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
# 1.1.0 - MOFA refresh: validate the Jamf mode, reset configuration before (re)installing so the new
#         app is not cleaned underneath itself, download and verify the package before removing a
#         damaged copy, drop the obsolete macOS 10.15 check, clean the console user's temp folder,
#         append the login keychain to the search list instead of replacing it, and return nonzero
#         when a cleanup step fails.
#
# Jamf parameter 4 (MODE, optionally written as MODE=value):
#   reset     - reset OneDrive configuration only (default)
#   repair    - also reinstall OneDrive when it is missing, damaged or older than build 23154
#   reinstall - same as repair
#   force     - always download and reinstall OneDrive after the reset
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
autoload -Uz is-at-least

echo "Office-Reset: Starting postinstall for Reset_OneDrive"

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

APP_NAME="Microsoft OneDrive"
APP_PATH="/Applications/OneDrive.app"
# Standalone OneDrive package. Ring-specific links: 861009 (Deferred), 861010 (Upcoming Deferred);
# see latest_raw_files/macos_standalone_onedrive_all.xml.
DOWNLOAD_URL="https://go.microsoft.com/fwlink/?linkid=861011"
# CFBundleVersion is formatted like 26168.0830.0006; builds older than 23154 are treated as ancient.
ONEDRIVE_MINIMUM_BUILD="23154.0"
MICROSOFT_TEAM_ID="UBF8T346G9"
MINIMUM_MACOS_VERSION="14.4"
REMOVAL_FAILURES=0
WORK_DIR=""

MODE="${4:-${MODE:-reset}}"
MODE="${MODE//[[:space:]]/}"
MODE="${MODE#[Mm][Oo][Dd][Ee]=}"
MODE=${MODE:l}
case "$MODE" in
	reset|repair|reinstall|force) ;;
	*)
		echo "Office-Reset: Unsupported mode '${MODE}'. Use reset, repair, reinstall or force." >&2
		exit 2
		;;
esac

CleanupWorkDir() {
	if [[ -n "$WORK_DIR" && "$WORK_DIR" == /private/var/tmp/mofa_reset.* && -d "$WORK_DIR" ]]; then
		/bin/rm -rf -- "$WORK_DIR"
	fi
}
trap CleanupWorkDir EXIT

FinishRun() {
	if (( REMOVAL_FAILURES > 0 )); then
		echo "Office-Reset: Completed with ${REMOVAL_FAILURES} removal failure(s)" >&2
		exit 1
	fi
	exit 0
}

GetLoggedInUser() {
	/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && !/loginwindow/ { print $3 }'
}

SetHomeFolder() {
	local target_user="$1"

	LoggedInUserID=""
	if [[ -z "$target_user" || "$target_user" == "root" || "$target_user" == "_mbsetupuser" ]]; then
		LoggedInUser=""
		HOME="/var/empty"
		return 0
	fi

	HOME=$(/usr/bin/dscl . -read "/Users/${target_user}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk -F': ' 'NR==1 { print $2 }')
	if [[ -z "$HOME" && -d "/Users/${target_user}" ]]; then
		HOME="/Users/${target_user}"
	fi
	if [[ "$HOME" != /Users/?* || ! -d "$HOME" ]]; then
		echo "Office-Reset: Home folder for ${target_user} is not under /Users; skipping user data" >&2
		LoggedInUser=""
		HOME="/var/empty"
		return 1
	fi

	LoggedInUserID=$(/usr/bin/id -u "$target_user" 2>/dev/null)
}

runAsUser() {
	if [[ -z "$LoggedInUser" || -z "$LoggedInUserID" ]]; then
		echo "Office-Reset: No logged-in user detected; skipping user-context command: $*" >&2
		return 1
	fi

	/bin/launchctl asuser "$LoggedInUserID" /usr/bin/sudo -H -u "$LoggedInUser" "$@"
}

GetUserTempFolder() {
	local user_tmp

	user_tmp=$(runAsUser /usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || user_tmp=""
	user_tmp="${user_tmp%/}"
	if [[ "$user_tmp" == /private/var/folders/* || "$user_tmp" == /var/folders/* ]]; then
		printf '%s\n' "$user_tmp"
	else
		printf '%s\n' "/var/empty"
	fi
}

shouldReinstall() {
	[[ "$MODE" == "reinstall" || "$MODE" == "repair" || "$MODE" == "force" ]]
}

removeTarget() { # $1: rm option, $2: target
	local target="$2"

	if [[ -z "$target" || "$target" == "/" || "$target" != /* ]]; then
		echo "Office-Reset: Refusing to remove unsafe path '${target}'" >&2
		(( REMOVAL_FAILURES++ ))
		return 1
	fi
	if [[ -e "$target" || -L "$target" ]]; then
		echo "Office-Reset: Removing $target"
		if ! /bin/rm "$1" -- "$target"; then
			echo "Office-Reset: Failed to remove $target" >&2
			(( REMOVAL_FAILURES++ ))
			return 1
		fi
	else
		echo "Office-Reset: Skipping missing path $target"
	fi
}

removePathList() {
	local target
	for target in "$@"; do
		removeTarget -rf "$target"
	done
}

removeFileList() {
	local target
	for target in "$@"; do
		removeTarget -f "$target"
	done
}

DownloadAndVerifyPackage() {
	local pkg_url="$DOWNLOAD_URL"
	local signature
	local signature_rc

	if ! is-at-least "$MINIMUM_MACOS_VERSION" "$(/usr/bin/sw_vers -productVersion)"; then
		echo "Office-Reset: Warning: macOS is older than ${MINIMUM_MACOS_VERSION}; the current ${APP_NAME} package may not install"
	fi

	WORK_DIR=$(/usr/bin/mktemp -d /private/var/tmp/mofa_reset.XXXXXX) || WORK_DIR=""
	if [[ -z "$WORK_DIR" ]]; then
		echo "Office-Reset: Package download failed: unable to create a temporary folder" >&2
		exit 1
	fi
	PKG_PATH="${WORK_DIR}/package.pkg"

	echo "Office-Reset: Starting ${APP_NAME} package download from ${pkg_url}"
	if ! /usr/bin/curl -fsSL --retry 3 --connect-timeout 30 --max-time 3600 -o "$PKG_PATH" "$pkg_url"; then
		echo "Office-Reset: Package download failed" >&2
		exit 1
	fi
	if [[ ! -s "$PKG_PATH" ]]; then
		echo "Office-Reset: Downloaded package is malformed (empty file)" >&2
		exit 1
	fi
	echo "Office-Reset: Finished package download ($(/usr/bin/stat -f%z "$PKG_PATH") bytes)"

	signature=$(/usr/sbin/pkgutil --check-signature "$PKG_PATH" 2>&1)
	signature_rc=$?
	if (( signature_rc != 0 )) \
		|| [[ "$signature" != *"Status: signed by a developer certificate issued by Apple"* ]] \
		|| [[ "$signature" != *"Developer ID Installer: Microsoft Corporation (${MICROSOFT_TEAM_ID})"* ]]; then
		echo "Office-Reset: Downloaded package is not signed by Microsoft" >&2
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${pkg_url}" >&2
		exit 1
	fi
	if ! /usr/sbin/spctl -a -t install "$PKG_PATH" >/dev/null 2>&1; then
		echo "Office-Reset: Downloaded package is not signed in a way Gatekeeper accepts" >&2
		exit 1
	fi
	echo "Office-Reset: Downloaded package is signed by Microsoft"
}

InstallVerifiedPackage() {
	echo "Office-Reset: Starting package install"
	if /usr/sbin/installer -pkg "$PKG_PATH" -target /; then
		echo "Office-Reset: Package installed successfully"
	else
		echo "Office-Reset: Package installation failed" >&2
		echo "Office-Reset: Please manually download and install ${APP_NAME}" >&2
		exit 1
	fi
}

AppSignatureProblem() {
	local output
	local codesign_rc

	output=$(/usr/bin/codesign --verify --deep -vv "$APP_PATH" 2>&1)
	codesign_rc=$?
	if (( codesign_rc != 0 )); then
		printf '%s\n' "$output"
		return 0
	fi
	if ! /usr/bin/codesign -dv "$APP_PATH" 2>&1 | /usr/bin/grep -q "TeamIdentifier=${MICROSOFT_TEAM_ID}"; then
		printf '%s\n' "app is not signed by Microsoft team ${MICROSOFT_TEAM_ID}"
		return 0
	fi
	return 1
}

RepairApp() { # $1: "replace" removes the installed copy after the new package is verified
	DownloadAndVerifyPackage
	if [[ "$1" == "replace" ]]; then
		removePathList "$APP_PATH"
	fi
	InstallVerifiedPackage
}

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
USER_TMPDIR=$(GetUserTempFolder)
echo "Office-Reset: Running as: ${LoggedInUser:-<none>}; Home Folder: $HOME; Temp Folder: $USER_TMPDIR; Mode: $MODE"

/usr/bin/pkill -9 'OneDrive'
/usr/bin/pkill -9 'FinderSync'
/usr/bin/pkill -9 'OneDriveStandaloneUpdater'
/usr/bin/pkill -9 'OneDriveUpdater'

echo "Office-Reset: Removing configuration data for ${APP_NAME}"
removePathList \
	"$HOME/Library/Caches/OneDrive" \
	"$HOME/Library/Caches/com.microsoft.OneDrive" \
	"$HOME/Library/Caches/com.microsoft.OneDriveUpdater" \
	"$HOME/Library/Caches/com.microsoft.OneDriveStandaloneUpdater" \
	"$HOME/Library/Caches/com.microsoft.SyncReporter" \
	"$HOME/Library/Caches/com.microsoft.SharePoint-mac" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDrive" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDriveUpdater" \
	"$HOME/Library/HTTPStorages/com.microsoft.SharePoint-mac" \
	"$HOME/Library/HTTPStorages/com.microsoft.SyncReporter" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater" \
	"$HOME/Library/WebKit/com.microsoft.OneDrive" \
	"$HOME/Library/Containers/com.microsoft.OneDrive-mac" \
	"$HOME/Library/Containers/com.microsoft.OneDrive.FinderSync" \
	"$HOME/Library/Containers/com.microsoft.OneDrive-mac.FinderSync" \
	"$HOME/Library/Containers/com.microsoft.OneDriveLauncher" \
	"$HOME/Library/Containers/com.microsoft.OneDrive.FileProvider" \
	"$HOME/Library/Logs/OneDrive" \
	"/Library/Logs/Microsoft/OneDrive" \
	"$HOME/Library/Application Support/OneDrive" \
	"$HOME/Library/Application Support/com.microsoft.OneDrive" \
	"$HOME/Library/Application Support/com.microsoft.OneDriveUpdater" \
	"$HOME/Library/Application Support/com.microsoft.OneDriveStandaloneUpdater" \
	"$HOME/Library/Application Support/com.microsoft.SharePoint-mac" \
	"$HOME/Library/Application Support/OneDriveUpdater" \
	"$HOME/Library/Application Support/OneDriveStandaloneUpdater" \
	"$HOME/Library/Application Scripts/com.microsoft.OneDrive.FinderSync" \
	"$HOME/Library/Application Scripts/com.microsoft.OneDrive.FileProvider" \
	"$HOME/Library/Application Scripts/UBF8T346G9.OneDriveStandaloneSuite" \
	"$HOME/Library/Application Scripts/UBF8T346G9.OfficeOneDriveSyncIntegration" \
	"$HOME/Library/Application Scripts/UBF8T346G9.OneDriveSyncClientSuite" \
	"$HOME/Library/Application Scripts/UBF8T346G9.Kfm" \
	"$HOME/Library/Group Containers/UBF8T346G9.OfficeOneDriveSyncIntegration" \
	"$HOME/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite" \
	"$HOME/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite" \
	"$HOME/Library/Group Containers/UBF8T346G9.Kfm" \
	"$USER_TMPDIR/com.microsoft.OneDrive" \
	"$USER_TMPDIR/com.microsoft.OneDrive.FinderSync"

removeFileList \
	"$HOME/Library/Cookies/com.microsoft.OneDrive.binarycookies" \
	"$HOME/Library/Cookies/com.microsoft.OneDriveUpdater.binarycookies" \
	"$HOME/Library/Cookies/com.microsoft.OneDriveStandaloneUpdater.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDrive.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDriveUpdater.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.SharePoint-mac.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.SyncReporter.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater.binarycookies" \
	"$HOME/Library/Preferences/com.microsoft.OneDrive.plist" \
	"$HOME/Library/Preferences/com.microsoft.SharePoint-mac.plist" \
	"$HOME/Library/Preferences/com.microsoft.OneDriveStandaloneUpdater.plist" \
	"$HOME/Library/Preferences/com.microsoft.OneDriveUpdater.plist" \
	"$HOME/Library/Preferences/UBF8T346G9.OneDriveStandaloneSuite.plist" \
	"$HOME/Library/Preferences/UBF8T346G9.OfficeOneDriveSyncIntegration.plist" \
	"/Library/Preferences/com.microsoft.OneDrive.plist" \
	"/Library/Preferences/com.microsoft.OneDriveStandaloneUpdater.plist" \
	"/Library/Preferences/com.microsoft.OneDriveUpdater.plist" \
	"/Library/Managed Preferences/com.microsoft.OneDriveStandaloneUpdater.plist" \
	"/Library/Managed Preferences/com.microsoft.OneDriveUpdater.plist" \
	"$USER_TMPDIR/OneDriveVersion.xml"

if [[ -n "$LoggedInUser" ]]; then
	KeychainSearchList=("${(@f)$(runAsUser /usr/bin/security list-keychains -d user 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')}")
	if [[ ${KeychainSearchList[(I)*login.keychain*]} -eq 0 ]]; then
		echo "Office-Reset: Adding user login keychain to the existing search list"
		runAsUser /usr/bin/security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "${(@)KeychainSearchList:#}" >/dev/null 2>&1 || true
	fi

	echo "Office-Reset: Keychain search list for logged-in user:"
	runAsUser /usr/bin/security list-keychains -d user || true

	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OneDrive.FinderSync.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OneDrive.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OneDriveUpdater.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OneDriveStandaloneUpdater.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'OneDrive Standalone Cached Credential Business - Business1' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'OneDrive Standalone Cached Credential' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -s 'com.microsoft.onedrive.cookies' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -s 'OneAuthAccount' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.adalcache' 2>/dev/null || true
else
	echo "Office-Reset: No logged-in user detected; skipping user keychain cleanup"
fi
removePathList "$HOME/Library/Group Containers/UBF8T346G9.com.microsoft.oneauth"

KEYCHAIN_2_PATH=$(/usr/bin/find "$HOME/Library/Keychains" -name keychain-2.db 2>/dev/null | /usr/bin/head -n 1)
if [[ -n "$KEYCHAIN_2_PATH" ]]; then
	/usr/bin/sqlite3 "$KEYCHAIN_2_PATH" "DELETE FROM genp WHERE agrp='UBF8T346G9.com.microsoft.identity.universalstorage';" >/dev/null 2>&1 || true
fi

if [[ "$MODE" == "force" ]]; then
	echo "Office-Reset: Force mode enabled, reinstalling ${APP_NAME}"
	RepairApp replace
elif [[ -d "$APP_PATH" ]]; then
	APP_VERSION=$(/usr/bin/defaults read "${APP_PATH}/Contents/Info.plist" CFBundleVersion 2>/dev/null)
	echo "Office-Reset: Found version ${APP_VERSION} of ${APP_NAME}"
	if [[ -n "$APP_VERSION" ]] && ! is-at-least "$ONEDRIVE_MINIMUM_BUILD" "$APP_VERSION"; then
		if shouldReinstall; then
			echo "Office-Reset: The installed version of ${APP_NAME} is ancient. Reinstall mode enabled, updating it now"
			RepairApp
		else
			echo "Office-Reset: The installed version of ${APP_NAME} is ancient. Reset mode will not reinstall automatically"
		fi
	fi
	echo "Office-Reset: Checking the app bundle for corruption"
	if SIGNATURE_PROBLEM=$(AppSignatureProblem); then
		echo "Office-Reset: The ${APP_NAME} app bundle is damaged and reporting error ${SIGNATURE_PROBLEM}"
		if shouldReinstall; then
			echo "Office-Reset: The ${APP_NAME} app bundle is damaged and will be reinstalled"
			RepairApp replace
		else
			echo "Office-Reset: The ${APP_NAME} app bundle is damaged. Reset mode will not reinstall automatically"
		fi
	else
		echo "Office-Reset: Codesign passed successfully"
	fi
else
	echo "Office-Reset: ${APP_NAME} was not found in the default location"
	if shouldReinstall; then
		echo "Office-Reset: Reinstall mode enabled, installing ${APP_NAME}"
		RepairApp
	fi
fi

FinishRun
