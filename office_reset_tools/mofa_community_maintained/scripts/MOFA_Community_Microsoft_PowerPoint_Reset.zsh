#!/bin/zsh

# ============================================================
# Script Name: MOFA_Community_Microsoft_PowerPoint_Reset.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets the Microsoft PointPoint
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
#
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Reset_PowerPoint"

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

APP_NAME="Microsoft PowerPoint"
DOWNLOAD_URL="https://go.microsoft.com/fwlink/?linkid=525136"
MODE="${4:-${MODE:-reset}}"
MODE=${MODE:l}

GetLoggedInUser() {
	/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/&&!/loginwindow/{print $3}'
}

SetHomeFolder() {
	local target_user="$1"

	LoggedInUserID=""
	if [[ -z "$target_user" ]]; then
		HOME="/var/empty"
		return 0
	fi

	HOME=$(/usr/bin/dscl . -read "/Users/${target_user}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk -F': ' 'NR==1 { print $2 }')
	if [[ -z "$HOME" && -d "/Users/${target_user}" ]]; then
		HOME="/Users/${target_user}"
	fi
	if [[ -z "$HOME" ]]; then
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

GetPrefValue() { # $1: domain, $2: key
	local value

	value=$(/usr/bin/defaults read "$1" "$2" 2>/dev/null) || value=""
	if [[ -z "$value" ]]; then
		value=$(runAsUser /usr/bin/defaults read "$1" "$2" 2>/dev/null) || true
	fi

	printf '%s\n' "$value"
}

shouldReinstall() {
	[[ "$MODE" == "reinstall" || "$MODE" == "repair" || "$MODE" == "force" ]]
}

removePathList() {
	local target
	for target in "$@"; do
		if [[ -e "$target" || -L "$target" ]]; then
			echo "Office-Reset: Removing $target"
			/bin/rm -rf -- "$target"
		else
			echo "Office-Reset: Skipping missing path $target"
		fi
	done
}

removeFileList() {
	local target
	for target in "$@"; do
		if [[ -e "$target" || -L "$target" ]]; then
			echo "Office-Reset: Removing $target"
			/bin/rm -f -- "$target"
		else
			echo "Office-Reset: Skipping missing file $target"
		fi
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
		echo "Office-Reset: Removing $match"
		/bin/rm -f -- "$match"
	done < <(/usr/bin/find "$search_dir" -maxdepth 1 \( -type f -o -type l \) -name "$name_pattern" 2>/dev/null)

	if [[ $found -eq 0 ]]; then
		echo "Office-Reset: No matches for $name_pattern in $search_dir"
	fi
}

GetCustomManifestVersion() {
	CHANNEL_NAME=$(GetPrefValue "com.microsoft.autoupdate2" "ChannelName")
	if [ "${CHANNEL_NAME}" = "Custom" ]; then
    	MANIFEST_SERVER=$(GetPrefValue "com.microsoft.autoupdate2" "ManifestServer")
    	echo "Office-Reset: Found custom ManifestServer ${MANIFEST_SERVER}"
    	FULL_UPDATER=$(/usr/bin/nscurl --location ${MANIFEST_SERVER}/0409PPT32019.xml | grep -A1 -m1 'FullUpdaterLocation' | grep 'string' | sed -e 's,.*<string>\([^<]*\)</string>.*,\1,g')
    	echo "Office-Reset: Found custom FullUpdaterLocation ${FULL_UPDATER}"
    	if [[ "${FULL_UPDATER}" = "https://"* ]]; then
    		CUSTOM_VERSION=$(/usr/bin/nscurl --location ${MANIFEST_SERVER}/0409PPT32019-chk.xml | grep -A1 -m1 'Update Version' | grep 'string' | sed -e 's,.*<string>\([^<]*\)</string>.*,\1,g')
    		echo "Office-Reset: Found custom update version ${CUSTOM_VERSION}"
    	fi
    fi
}

RepairApp() {
	DOWNLOAD_FOLDER="/Users/Shared/OnDemandInstaller/"
	if [ -d "$DOWNLOAD_FOLDER" ]; then
		rm -rf "$DOWNLOAD_FOLDER"
	fi
	mkdir -p "$DOWNLOAD_FOLDER"

	GetCustomManifestVersion
	if [[ -z "${CUSTOM_VERSION}" ]]; then
		CDN_PKG_URL=$(/usr/bin/nscurl --location --head $DOWNLOAD_URL --dump-header - | awk '/Location/' | cut -d ' ' -f2 | tail -1 | awk '{$1=$1};1')
	else
		CDN_PKG_URL="${FULL_UPDATER}"
	fi
	
	echo "Office-Reset: Package to download is ${CDN_PKG_URL}"
	CDN_PKG_NAME=$(/usr/bin/basename "${CDN_PKG_URL}")

	CDN_PKG_SIZE=$(/usr/bin/nscurl --location --head $CDN_PKG_URL --dump-header - | awk '/Content-Length/' | cut -d ' ' -f2 | tail -1 | awk '{$1=$1};1')
	CDN_PKG_MB=$(/bin/expr ${CDN_PKG_SIZE} / 1000 / 1000)
	echo "Office-Reset: Download package is ${CDN_PKG_MB} megabytes in size"

	echo "Office-Reset: Starting ${APP_NAME} package download"
	/usr/bin/nscurl --background --download --large-download --location --download-directory $DOWNLOAD_FOLDER $CDN_PKG_URL
	echo "Office-Reset: Finished package download"

	LOCAL_PKG_SIZE=$(cd "${DOWNLOAD_FOLDER}" && stat -qf%z "${CDN_PKG_NAME}")
	if [[ "${LOCAL_PKG_SIZE}" == "${CDN_PKG_SIZE}" ]]; then
		echo "Office-Reset: Downloaded package is wholesome"
	else
		echo "Office-Reset: Downloaded package is malformed. Local file size: ${LOCAL_PKG_SIZE}"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		exit 0
	fi

	LOCAL_PKG_SIGNING=$(/usr/sbin/pkgutil --check-signature ${DOWNLOAD_FOLDER}${CDN_PKG_NAME} | awk '/Developer ID Installer'/ | cut -d ':' -f 2 | awk '{$1=$1};1')
	if [[ "${LOCAL_PKG_SIGNING}" == "Microsoft Corporation (UBF8T346G9)" ]]; then
		echo "Office-Reset: Downloaded package is signed by Microsoft"
	else
		echo "Office-Reset: Downloaded package is not signed by Microsoft"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		exit 0
	fi

	echo "Office-Reset: Starting package install"
	/usr/sbin/installer -pkg ${DOWNLOAD_FOLDER}${CDN_PKG_NAME} -target /
	if [ $? -eq 0 ]; then
		echo "Office-Reset: Package installed successfully"
	else
		echo "Office-Reset: Package installation failed"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		exit 0
	fi
	echo "Office-Reset: Exiting without removing configuration data"
	exit 0
}

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME; Mode: $MODE"

/usr/bin/pkill -9 'Microsoft PowerPoint'

if [ -d "/Applications/Microsoft PowerPoint.app" ]; then
	APP_VERSION=$(defaults read /Applications/Microsoft\ PowerPoint.app/Contents/Info.plist CFBundleVersion)
	echo "Office-Reset: Found version ${APP_VERSION} of ${APP_NAME}"
	echo "Office-Reset: Office for Mac now uses a unified 16.x codebase; skipping legacy 2016/2019 generation checks"
	GetCustomManifestVersion
	if [[ "${CUSTOM_VERSION}" ]] && [[ "${APP_VERSION}" != "${CUSTOM_VERSION}" ]]; then
		if shouldReinstall; then
			echo "Office-Reset: ${APP_NAME} is ${APP_VERSION} on-disk, but the pinned version has been set to ${CUSTOM_VERSION}. Removing and reinstalling"
			removePathList "/Applications/Microsoft PowerPoint.app"
			RepairApp
		else
			echo "Office-Reset: ${APP_NAME} does not match the pinned version. Reset mode will not reinstall automatically"
		fi
	fi
	echo "Office-Reset: Checking the app bundle for corruption"
	/usr/bin/codesign -vv --deep /Applications/Microsoft\ PowerPoint.app
	if [ $? -gt 0 ]; then
		CODESIGN_ERROR=$(/usr/bin/codesign -vv --deep /Applications/Microsoft\ PowerPoint.app)
		echo "Office-Reset: The ${APP_NAME} app bundle is damaged and reporting error ${CODESIGN_ERROR}"
		if [[ "${CODESIGN_ERROR}" = *"OLE.framework"* ]]; then
			echo "Office-Reset: Only OLE.framework has been modified. Ignoring the repair"
		else
			if shouldReinstall; then
				echo "Office-Reset: The ${APP_NAME} app bundle is damaged and will be removed and reinstalled"
				removePathList "/Applications/Microsoft PowerPoint.app"
				RepairApp
			else
				echo "Office-Reset: The ${APP_NAME} app bundle is damaged. Reset mode will not reinstall automatically"
			fi
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

echo "Office-Reset: Removing configuration data for ${APP_NAME}"
removeFileList \
	"/Library/Preferences/com.microsoft.Powerpoint.plist" \
	"/Library/Managed Preferences/com.microsoft.Powerpoint.plist" \
	"$HOME/Library/Preferences/com.microsoft.Powerpoint.plist" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/MicrosoftRegistrationDB.reg"

removePathList \
	"$HOME/Library/Containers/com.microsoft.Powerpoint" \
	"$HOME/Library/Application Scripts/com.microsoft.Powerpoint" \
	"/Applications/.Microsoft PowerPoint.app.installBackup" \
	"/Library/Application Support/Microsoft/Office365/User Content.localized/Startup.localized/PowerPoint" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/PowerPoint" \
	"/Library/Application Support/Microsoft/Office365/User Content.localized/Themes" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Themes" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/mip_policy" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/FontCache" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/ComRPC32" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/TemporaryItems" \
	"$TMPDIR/com.microsoft.Powerpoint"

removeFindMatches "/Library/Application Support/Microsoft/Office365/User Content.localized/Templates.localized" "*.pot"
removeFindMatches "/Library/Application Support/Microsoft/Office365/User Content.localized/Templates.localized" "*.potx"
removeFindMatches "/Library/Application Support/Microsoft/Office365/User Content.localized/Templates.localized" "*.potm"
removeFindMatches "$HOME/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Templates.localized" "*.pot"
removeFindMatches "$HOME/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Templates.localized" "*.potx"
removeFindMatches "$HOME/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Templates.localized" "*.potm"
removeFindMatches "/Library/Application Support/Microsoft/Office365/User Content.localized/Add-Ins" "*.ppam"
removeFindMatches "$HOME/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Add-Ins" "*.ppam"
removeFindMatches "$HOME/Library/Group Containers/UBF8T346G9.Office" "Microsoft Office ACL*"

exit 0
