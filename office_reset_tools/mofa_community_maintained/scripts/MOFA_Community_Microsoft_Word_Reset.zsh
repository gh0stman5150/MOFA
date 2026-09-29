#!/bin/zsh --no-rcs

# ============================================================
# Script Name: MOFA_Community_Microsoft_Word_Reset.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets Microsoft Word configuration data and optionally repairs or reinstalls the app.
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
# 1.1.0 - MOFA refresh: validate the Jamf mode, download and verify the Microsoft package
#         (pkgutil, Gatekeeper and team ID) before removing the installed app, download into
#         a private temporary folder, capture codesign errors, read MDM-managed MAU settings,
#         clean the console user's temp folder instead of root's, and return nonzero when a
#         cleanup step fails.
#
# Jamf parameter 4 (MODE, optionally written as MODE=value):
#   reset     - remove configuration data only (default)
#   repair    - reinstall the app when it is missing, damaged, or differs from a custom-manifest
#               pinned version; otherwise reset
#   reinstall - same as repair
#   force     - always download and reinstall the app; configuration data is kept
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
autoload -Uz is-at-least

echo "Office-Reset: Starting postinstall for Reset_Word"

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

APP_NAME="Microsoft Word"
APP_PATH="/Applications/${APP_NAME}.app"
DOWNLOAD_URL="https://go.microsoft.com/fwlink/?linkid=525134"
# MAU application ID for custom manifests. The "2019" suffix is still Microsoft's current ID.
MAU_APP_ID="MSWD2019"
MICROSOFT_TEAM_ID="UBF8T346G9"
MINIMUM_MACOS_VERSION="14.0"
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

GetPrefValue() { # $1: domain, $2: key
	local value=""
	local plist

	for plist in "/Library/Managed Preferences/${LoggedInUser:-.none}/$1.plist" "/Library/Managed Preferences/$1.plist" "/Library/Preferences/$1.plist"; do
		if [[ -f "$plist" ]]; then
			value=$(/usr/bin/defaults read "$plist" "$2" 2>/dev/null) || value=""
			[[ -n "$value" ]] && break
		fi
	done
	if [[ -z "$value" ]]; then
		value=$(runAsUser /usr/bin/defaults read "$1" "$2" 2>/dev/null) || value=""
	fi

	printf '%s\n' "$value"
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

removeFindMatches() {
	local search_dir="$1"
	local name_pattern="$2"
	local match
	local found=0

	if [[ ! -d "$search_dir" ]]; then
		echo "Office-Reset: Skipping missing directory $search_dir"
		return 0
	fi

	while IFS= read -r match; do
		found=1
		removeTarget -f "$match"
	done < <(/usr/bin/find "$search_dir" -maxdepth 1 \( -type f -o -type l \) -name "$name_pattern" 2>/dev/null)

	if [[ $found -eq 0 ]]; then
		echo "Office-Reset: No matches for $name_pattern in $search_dir"
	fi
}

ReadManifestString() { # $1: URL, $2: key
	/usr/bin/curl -fsSL --connect-timeout 30 --max-time 120 "$1" 2>/dev/null \
		| /usr/bin/grep -A1 -m1 "$2" \
		| /usr/bin/grep 'string' \
		| /usr/bin/sed -e 's,.*<string>\([^<]*\)</string>.*,\1,g'
}

GetCustomManifestVersion() {
	[[ -n "$CUSTOM_MANIFEST_CHECKED" ]] && return 0
	CUSTOM_MANIFEST_CHECKED=1
	CUSTOM_VERSION=""
	FULL_UPDATER=""

	CHANNEL_NAME=$(GetPrefValue "com.microsoft.autoupdate2" "ChannelName")
	if [[ "${CHANNEL_NAME}" == "Custom" ]]; then
		MANIFEST_SERVER=$(GetPrefValue "com.microsoft.autoupdate2" "ManifestServer")
		MANIFEST_SERVER="${MANIFEST_SERVER%/}"
		echo "Office-Reset: Found custom ManifestServer ${MANIFEST_SERVER}"
		[[ -z "$MANIFEST_SERVER" ]] && return 0
		FULL_UPDATER=$(ReadManifestString "${MANIFEST_SERVER}/0409${MAU_APP_ID}.xml" 'FullUpdaterLocation')
		echo "Office-Reset: Found custom FullUpdaterLocation ${FULL_UPDATER}"
		if [[ "${FULL_UPDATER}" == "https://"* ]]; then
			CUSTOM_VERSION=$(ReadManifestString "${MANIFEST_SERVER}/0409${MAU_APP_ID}-chk.xml" 'Update Version')
			echo "Office-Reset: Found custom update version ${CUSTOM_VERSION}"
		else
			FULL_UPDATER=""
		fi
	fi
}

DownloadAndVerifyPackage() {
	local pkg_url="$DOWNLOAD_URL"
	local signature
	local signature_rc

	GetCustomManifestVersion
	if [[ -n "${CUSTOM_VERSION}" && -n "${FULL_UPDATER}" ]]; then
		pkg_url="${FULL_UPDATER}"
	fi

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

RepairApp() {
	# Download and verify before removing the installed copy so a failed download leaves it in place.
	DownloadAndVerifyPackage
	removePathList "$APP_PATH"
	InstallVerifiedPackage
	echo "Office-Reset: Exiting without removing configuration data"
	FinishRun
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

CheckInstalledApp() {
	local app_version
	local signature_problem

	if [[ "$MODE" == "force" ]]; then
		echo "Office-Reset: Force mode enabled, reinstalling ${APP_NAME}"
		RepairApp
	fi

	if [[ ! -d "$APP_PATH" ]]; then
		echo "Office-Reset: ${APP_NAME} was not found in the default location"
		if shouldReinstall; then
			echo "Office-Reset: Reinstall mode enabled, installing ${APP_NAME}"
			RepairApp
		fi
		return 0
	fi

	app_version=$(/usr/bin/defaults read "${APP_PATH}/Contents/Info.plist" CFBundleVersion 2>/dev/null)
	echo "Office-Reset: Found version ${app_version} of ${APP_NAME}"
	GetCustomManifestVersion
	# A custom manifest pins an exact build, so any difference (including a newer build) is reinstalled.
	if [[ -n "${CUSTOM_VERSION}" && "${app_version}" != "${CUSTOM_VERSION}" ]]; then
		if shouldReinstall; then
			echo "Office-Reset: ${APP_NAME} is ${app_version} on-disk, but the pinned version has been set to ${CUSTOM_VERSION}. Reinstalling"
			RepairApp
		else
			echo "Office-Reset: ${APP_NAME} does not match the pinned version. Reset mode will not reinstall automatically"
		fi
	fi

	echo "Office-Reset: Checking the app bundle for corruption"
	if signature_problem=$(AppSignatureProblem); then
		echo "Office-Reset: The ${APP_NAME} app bundle is damaged and reporting error ${signature_problem}"
		if shouldReinstall; then
			echo "Office-Reset: The ${APP_NAME} app bundle is damaged and will be reinstalled"
			RepairApp
		else
			echo "Office-Reset: The ${APP_NAME} app bundle is damaged. Reset mode will not reinstall automatically"
		fi
	else
		echo "Office-Reset: Codesign passed successfully"
	fi
}

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
USER_TMPDIR=$(GetUserTempFolder)
echo "Office-Reset: Running as: ${LoggedInUser:-<none>}; Home Folder: $HOME; Temp Folder: $USER_TMPDIR; Mode: $MODE"

/usr/bin/pkill -9 'Microsoft Word'

CheckInstalledApp

echo "Office-Reset: Removing configuration data for ${APP_NAME}"
removeFileList \
	"/Library/Preferences/com.microsoft.Word.plist" \
	"/Library/Managed Preferences/com.microsoft.Word.plist" \
	"$HOME/Library/Preferences/com.microsoft.Word.plist" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/MicrosoftRegistrationDB.reg"

removePathList \
	"$HOME/Library/Containers/com.microsoft.Word" \
	"$HOME/Library/Application Scripts/com.microsoft.Word" \
	"/Applications/.Microsoft Word.app.installBackup" \
	"/Library/Application Support/Microsoft/Office365/User Content.localized/Startup.localized/Word" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/Word" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/mip_policy" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/FontCache" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/ComRPC32" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/TemporaryItems" \
	"$USER_TMPDIR/com.microsoft.Word"

removeFindMatches "/Library/Application Support/Microsoft/Office365/User Content.localized/Templates.localized" "*.dot"
removeFindMatches "/Library/Application Support/Microsoft/Office365/User Content.localized/Templates.localized" "*.dotx"
removeFindMatches "/Library/Application Support/Microsoft/Office365/User Content.localized/Templates.localized" "*.dotm"
removeFindMatches "$HOME/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Templates.localized" "*.dot"
removeFindMatches "$HOME/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Templates.localized" "*.dotx"
removeFindMatches "$HOME/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Templates.localized" "*.dotm"
removeFindMatches "$HOME/Library/Group Containers/UBF8T346G9.Office" "Microsoft Office ACL*"

FinishRun
