#!/bin/zsh --no-rcs
# Tests for office_reset_tools/mofa_community_maintained/scripts/MOFA_Community_Microsoft_PowerPoint_Reset.zsh.
# Run as an unprivileged user: zsh tests/reset_scripts/test_PowerPoint_Reset.zsh (or run_all.zsh).
# Every system command is a recording stub (see harness.zsh); nothing outside the sandbox changes.

source "${0:A:h}/harness.zsh"

mofa_source_script MOFA_Community_Microsoft_PowerPoint_Reset.zsh
mofa_assert_source_clean
mofa_stub t_cleanup_probe 0 # a recording stub that t_main_flow's CleanupWorkDir calls

integer T_CASE=0
T_SIGNED_BY_MICROSOFT=$'Package "package.pkg":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Certificate Chain:\n    1. Developer ID Installer: Microsoft Corporation (UBF8T346G9)'
T_SIGNED_BY_OTHER=$'Package "package.pkg":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Certificate Chain:\n    1. Developer ID Installer: Microsoft Corporation (ABCDE12345)'
T_DEFAULT_URL="https://go.microsoft.com/fwlink/?linkid=525136"
T_GROUP="Library/Group Containers/UBF8T346G9.Office"

# --- Test helpers (t_ prefix: never clash with script functions) ---------------------
t_reset_globals() { # fresh script globals and per-case fixture paths inside the sandbox
	(( T_CASE++ ))
	T_DIR="$MOFA_TEST_ROOT/case${T_CASE}"
	T_MANAGED="$T_DIR/managed"
	T_SYSTEM="$T_DIR/system"
	T_WORK="$T_DIR/work"
	T_HOME="$T_DIR/home/alice"
	T_APP="$T_DIR/Applications/Microsoft PowerPoint.app"
	mofa_mkdir "$T_DIR"
	unset MODE
	REMOVAL_FAILURES=0
	LoggedInUser=""
	LoggedInUserID=""
	WORK_DIR=""
	PKG_PATH=""
	CUSTOM_MANIFEST_CHECKED=""
	CUSTOM_VERSION=""
	FULL_UPDATER=""
	MANIFEST_SERVER=""
	APP_PATH="$T_APP"
	MANAGED_PREFERENCES_DIR="$T_MANAGED"
	SYSTEM_PREFERENCES_DIR="$T_SYSTEM"
	T_CHANNEL=""
	T_SERVER=""
	T_APP_VERSION=""
}

t_show_mode() {
	ParseMode "$@"
	print -r -- "MODE=${MODE}"
}

# Runs main as if root, with a sandbox home for console user "alice". Only call through mofa_run.
t_main_flow() {
	RequireRoot() { :; }
	SetHomeFolder() {
		LoggedInUserID=""
		if [[ "$1" == alice ]]; then
			LoggedInUserID=501
			HOME="$T_HOME"
		else
			LoggedInUser=""
			HOME="/var/empty"
		fi
	}
	CleanupWorkDir() { t_cleanup_probe; } # recorded in the call log, so tests see when the EXIT trap ran
	main "$@"
}

t_fake_launchctl() { # launchctl asuser UID sudo -H -u USER CMD...
	case "$*" in
		*"/usr/bin/getconf DARWIN_USER_TEMP_DIR"*) print -r -- "/var/folders/zz/mofa_test/T/" ;;
	esac
	return 0
}

t_fake_download() { # writes the "package" to the -o path, inside the sandbox only
	local out="" prev="" arg
	for arg in "$@"; do
		[[ "$prev" == -o ]] && out="$arg"
		prev="$arg"
	done
	[[ "$out" == "$MOFA_TEST_ROOT"/?* ]] || return 99
	print -r -- "fake package" >| "$out"
}

t_fake_defaults() { # defaults read PLIST KEY
	[[ "$1" == read ]] || return 1
	case "$3" in
		ChannelName) print -r -- "$T_CHANNEL" ;;
		ManifestServer) print -r -- "$T_SERVER" ;;
		CFBundleVersion) [[ -n "$T_APP_VERSION" ]] && print -r -- "$T_APP_VERSION" ;;
		*) return 1 ;;
	esac
}

t_fake_manifest_curl() { # the URL is the last argument
	case "${@[-1]}" in
		https://manifest.example.com/0409PPT32019-chk.xml)
			print -r -- $'<dict>\n<key>Update Version</key>\n<string>16.89.24091630</string>\n</dict>' ;;
		https://manifest.example.com/0409PPT32019.xml)
			print -r -- $'<dict>\n<key>FullUpdaterLocation</key>\n<string>https://cdn.example.com/PowerPoint_Installer.pkg</string>\n</dict>' ;;
		*) return 22 ;;
	esac
}

t_fake_curl() { # package downloads (-o) go to t_fake_download, manifest reads to t_fake_manifest_curl
	if (( ${@[(Ie)-o]} )); then
		t_fake_download "$@"
	else
		t_fake_manifest_curl "$@"
	fi
}

t_fake_find() { # find DIR -maxdepth 1 ( -type f -o -type l ) -name PATTERN; sandbox only
	local dir="$1" pattern="${@[-1]}"
	local -a matches
	[[ "$dir" == "$MOFA_TEST_ROOT"/?* ]] || return 0
	matches=("$dir"/${~pattern}(N.))
	(( ${#matches} )) && print -rl -- "${matches[@]}"
	return 0
}

t_setup_download() { # $1: pkgutil output
	mofa_mkdir "$T_WORK"
	mofa_stub /usr/bin/sw_vers 0 "15.5"
	mofa_stub /usr/bin/mktemp 0 "$T_WORK"
	mofa_stub_handler /usr/bin/curl t_fake_download
	mofa_stub /usr/bin/stat 0 "13"
	mofa_stub /usr/sbin/pkgutil 0 "$1"
	mofa_stub /usr/sbin/spctl 0
}

t_setup_console_user() { # console user alice with a sandbox home and a /var/folders temp folder
	mofa_stub /usr/sbin/scutil 0 "  Name : alice"
	mofa_stub_passthrough /usr/bin/awk
	mofa_stub_handler /bin/launchctl t_fake_launchctl
}

# --- MODE parsing -------------------------------------------------------------------
mofa_case "ParseMode normalises Jamf parameter 4"
t_reset_globals
for raw expected in "MODE= Repair " repair "" reset "FORCE" force "mode=Reinstall" reinstall " reset " reset; do
	mofa_run t_show_mode "$raw"
	mofa_assert_status 0 "ParseMode accepts '${raw}'"
	mofa_assert_eq "MODE=${expected}" "$MOFA_STDOUT" "ParseMode '${raw}' gives ${expected}"
done
MODE=Force mofa_run t_show_mode ""
mofa_assert_eq "MODE=force" "$MOFA_STDOUT" "an empty parameter 4 falls back to the MODE environment value"
MODE=force mofa_run t_show_mode "repair"
mofa_assert_eq "MODE=repair" "$MOFA_STDOUT" "parameter 4 wins over the MODE environment value"

mofa_case "ParseMode exits 2 on an unknown mode"
t_reset_globals
for raw in bogus "MODE=" "reset;rm" "MODE=delete"; do
	mofa_run t_show_mode "$raw"
	mofa_assert_status 2 "ParseMode '${raw}' exits 2"
	mofa_assert_contains "$MOFA_STDERR" "Unsupported mode" "ParseMode '${raw}' explains the failure"
	mofa_assert_eq "" "$MOFA_STDOUT" "ParseMode '${raw}' does not continue"
done
mofa_assert_no_calls "mode parsing runs no command"

mofa_case "main reads MODE from parameter 4 and validates it before touching the system"
t_reset_globals
mofa_run t_main_flow / computer alice bogus
mofa_assert_status 2 "main exits 2 for an unknown parameter 4"
mofa_assert_contains "$MOFA_STDOUT" "Starting postinstall for Reset_PowerPoint" "the start banner is printed first"
mofa_assert_no_calls "an invalid mode stops before any command runs"
mofa_run t_main_flow bogus bogus bogus reset
mofa_assert_status 0 "parameters 1-3 are ignored"

mofa_case "main refuses to run without root"
t_reset_globals
mofa_run main / computer alice reset
mofa_assert_status 1 "main exits 1 when not root"
mofa_assert_contains "$MOFA_STDOUT" "Starting postinstall for Reset_PowerPoint" "start banner precedes the root check"
mofa_assert_contains "$MOFA_STDERR" "must be run as root" "root check message"
mofa_assert_no_calls "nothing runs before the root check"

# --- Home and temp folder safety ----------------------------------------------------
mofa_case "SetHomeFolder maps root, _mbsetupuser and no user to /var/empty"
t_reset_globals
for user in root _mbsetupuser ""; do
	LoggedInUser="$user"
	LoggedInUserID=0
	mofa_capture SetHomeFolder "$user"
	mofa_assert_status 0 "SetHomeFolder '${user}' succeeds"
	mofa_assert_eq "/var/empty" "$HOME" "SetHomeFolder '${user}' uses /var/empty"
	mofa_assert_eq "" "$LoggedInUser" "SetHomeFolder '${user}' clears the console user"
	mofa_assert_eq "" "$LoggedInUserID" "SetHomeFolder '${user}' clears the user ID"
done
mofa_assert_not_called /usr/bin/dscl "no directory lookup for system accounts"

mofa_case "SetHomeFolder refuses a home outside /Users"
t_reset_globals
mofa_stub /usr/bin/dscl 0 "NFSHomeDirectory: /private/var/mofa_test_home"
mofa_stub_passthrough /usr/bin/awk
LoggedInUser=mofatestuser
mofa_capture SetHomeFolder mofatestuser
mofa_assert_status 1 "SetHomeFolder returns 1"
mofa_assert_eq "/var/empty" "$HOME" "HOME falls back to /var/empty"
mofa_assert_eq "" "$LoggedInUser" "the console user is cleared so user data is skipped"
mofa_assert_contains "$MOFA_STDERR" "not under /Users" "the refusal is logged"
mofa_assert_called /usr/bin/dscl . -read /Users/mofatestuser NFSHomeDirectory
mofa_assert_not_called /usr/bin/id "no user ID is looked up for a refused home"

mofa_case "SetHomeFolder refuses a missing home under /Users"
t_reset_globals
mofa_stub /usr/bin/dscl 0 "NFSHomeDirectory: /Users/mofa_no_such_home_$$"
mofa_stub_passthrough /usr/bin/awk
LoggedInUser=mofatestuser
mofa_capture SetHomeFolder mofatestuser
mofa_assert_status 1 "SetHomeFolder returns 1 for a home that does not exist"
mofa_assert_eq "/var/empty" "$HOME" "HOME falls back to /var/empty"

if [[ -d /Users/Shared ]]; then
	mofa_case "SetHomeFolder accepts an existing home under /Users"
	t_reset_globals
	mofa_stub /usr/bin/dscl 0 "NFSHomeDirectory: /Users/Shared"
	mofa_stub_passthrough /usr/bin/awk
	mofa_stub /usr/bin/id 0 "502"
	LoggedInUser=mofatestuser
	mofa_capture SetHomeFolder mofatestuser
	mofa_assert_status 0 "SetHomeFolder accepts /Users/Shared"
	mofa_assert_eq "/Users/Shared" "$HOME" "HOME is the directory record's home"
	mofa_assert_eq "502" "$LoggedInUserID" "the user ID comes from id -u"
	mofa_assert_called /usr/bin/id -u mofatestuser
fi

mofa_case "GetUserTempFolder accepts only /var/folders paths"
t_reset_globals
LoggedInUser=alice
LoggedInUserID=501
for reported expected in \
	"/var/folders/ab/cd1234/T/" "/var/folders/ab/cd1234/T" \
	"/private/var/folders/ab/cd1234/T/" "/private/var/folders/ab/cd1234/T" \
	"/tmp" "/var/empty" \
	"/Users/alice" "/var/empty" \
	"/" "/var/empty" \
	"" "/var/empty"; do
	mofa_stub /bin/launchctl 0 "$reported"
	mofa_assert_eq "$expected" "$(GetUserTempFolder)" "user temp folder '${reported}' gives ${expected}"
done
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/getconf DARWIN_USER_TEMP_DIR
mofa_stub /bin/launchctl 1 "/var/folders/ab/cd1234/T"
mofa_assert_eq "/var/empty" "$(GetUserTempFolder)" "a failed lookup gives /var/empty"

mofa_case "GetUserTempFolder without a console user does not run anything as a user"
t_reset_globals
mofa_assert_eq "/var/empty" "$(GetUserTempFolder 2>/dev/null)" "no console user gives /var/empty"
mofa_assert_not_called /bin/launchctl

# --- Removal wrapper ----------------------------------------------------------------
mofa_case "removeTarget refuses empty, relative and root targets"
t_reset_globals
for bad in "" "relative/path" "." "/"; do
	REMOVAL_FAILURES=0
	mofa_capture removeTarget -rf "$bad"
	mofa_assert_status 1 "removeTarget refuses '${bad}'"
	mofa_assert_eq 1 "$REMOVAL_FAILURES" "refusing '${bad}' counts as a removal failure"
	mofa_assert_contains "$MOFA_STDERR" "Refusing to remove unsafe path" "refusing '${bad}' is logged"
done
mofa_assert_not_called /bin/rm "rm never runs for an unsafe target"

mofa_case "removeTarget calls rm with the option, -- and the exact path"
t_reset_globals
target="$T_HOME/$T_GROUP/FontCache"
mofa_mkdir "$target"
mofa_capture removeTarget -rf "$target"
mofa_assert_status 0 "removeTarget succeeds"
mofa_assert_called /bin/rm -rf -- "$target"
mofa_assert_eq 1 "$(mofa_call_count /bin/rm)" "rm runs once"
mofa_assert_eq 0 "$REMOVAL_FAILURES" "no failure counted"
[[ -d "$target" ]] && mofa_pass "the stub did not delete anything" || mofa_fail "the stub did not delete anything"
plist="$T_HOME/Library/Preferences/com.microsoft.Powerpoint.plist"
mofa_write_file "$plist" "x"
mofa_capture removeFileList "$plist"
mofa_assert_called /bin/rm -f -- "$plist"

mofa_case "removeTarget counts rm failures and skips missing paths"
t_reset_globals
plist="$T_HOME/Library/Preferences/com.microsoft.Powerpoint.plist"
mofa_write_file "$plist" "x"
mofa_stub /bin/rm 1
mofa_capture removeTarget -f "$plist"
mofa_assert_status 1 "a failed rm returns 1"
mofa_assert_eq 1 "$REMOVAL_FAILURES" "a failed rm is counted"
mofa_assert_contains "$MOFA_STDERR" "Failed to remove" "a failed rm is logged"
mofa_reset_calls
mofa_capture removeTarget -rf "$T_HOME/Library/Containers/missing"
mofa_assert_status 0 "a missing path is not an error"
mofa_assert_contains "$MOFA_STDOUT" "Skipping missing path" "a missing path is logged"
mofa_assert_not_called /bin/rm "rm does not run for a missing path"

mofa_case "removeFindMatches removes only matching files in the folder itself"
t_reset_globals
addins="$T_HOME/$T_GROUP/User Content.localized/Add-Ins"
mofa_write_file "$addins/Tools.ppam" "x"
mofa_write_file "$addins/Excel.xlam" "x"
mofa_write_file "$addins/nested/Deep.ppam" "x"
mofa_stub_handler /usr/bin/find t_fake_find
mofa_capture removeFindMatches "$addins" "*.ppam"
mofa_assert_called /usr/bin/find "$addins" -maxdepth 1 "(" -type f -o -type l ")" -name "*.ppam"
t_addin="$addins/Tools.ppam"
mofa_assert_eq "/bin/rm -f -- ${(q+)t_addin}" "$(mofa_calls /bin/rm)" "only the top-level .ppam add-in is removed"
mofa_reset_calls
mofa_capture removeFindMatches "$T_HOME/$T_GROUP/missing" "*.ppam"
mofa_assert_contains "$MOFA_STDOUT" "Skipping missing directory" "a missing folder is skipped"
mofa_assert_not_called /usr/bin/find "find does not run for a missing folder"

mofa_case "CleanupWorkDir removes only its own download folder"
t_reset_globals
mofa_mkdir "$T_WORK"
for WORK_DIR in "$T_WORK" "/" "" "/private/var/tmp/mofa_reset.does_not_exist_$$"; do
	mofa_run CleanupWorkDir
done
mofa_assert_not_called /bin/rm "nothing outside /private/var/tmp/mofa_reset.* is removed"

# --- Exit status --------------------------------------------------------------------
mofa_case "FinishRun exits nonzero after a removal failure"
t_reset_globals
REMOVAL_FAILURES=2
mofa_run FinishRun
mofa_assert_status 1 "FinishRun exits 1"
mofa_assert_contains "$MOFA_STDERR" "Completed with 2 removal failure(s)" "failure count is logged"
REMOVAL_FAILURES=0
mofa_run FinishRun
mofa_assert_status 0 "FinishRun exits 0 without failures"

# --- Package download and verification ----------------------------------------------
mofa_case "DownloadAndVerifyPackage rejects a package from another team"
t_reset_globals
t_setup_download "$T_SIGNED_BY_OTHER"
mofa_run DownloadAndVerifyPackage
mofa_assert_status 1 "a team ID mismatch exits 1"
mofa_assert_contains "$MOFA_STDERR" "not signed by Microsoft" "the mismatch is logged"
mofa_assert_called /usr/bin/curl -fsSL --retry 3 --connect-timeout 30 --max-time 3600 -o "$T_WORK/package.pkg" -- "$T_DEFAULT_URL"
mofa_assert_called /usr/sbin/pkgutil --check-signature "$T_WORK/package.pkg"
mofa_assert_not_called /usr/sbin/spctl "Gatekeeper is not consulted after a signer mismatch"
mofa_assert_not_called /usr/sbin/installer "nothing is installed"

mofa_case "DownloadAndVerifyPackage requires Gatekeeper and a non-empty download"
t_reset_globals
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_run DownloadAndVerifyPackage
mofa_assert_status 0 "a Microsoft-signed package passes"
mofa_assert_called /usr/sbin/spctl -a -t install "$T_WORK/package.pkg"
mofa_stub /usr/sbin/spctl 3
mofa_run DownloadAndVerifyPackage
mofa_assert_status 1 "a Gatekeeper rejection exits 1"
mofa_assert_contains "$MOFA_STDERR" "Gatekeeper" "the Gatekeeper rejection is logged"
mofa_stub /usr/bin/curl 0
: >| "$T_WORK/package.pkg"
mofa_run DownloadAndVerifyPackage
mofa_assert_status 1 "an empty download exits 1"
mofa_assert_contains "$MOFA_STDERR" "malformed" "the empty download is logged"
mofa_stub /usr/bin/curl 22
mofa_reset_calls
mofa_run DownloadAndVerifyPackage
mofa_assert_status 1 "a failed download exits 1"
mofa_assert_not_called /usr/sbin/pkgutil "a failed download is not verified"
mofa_assert_not_called /usr/sbin/installer "a failed download is not installed"

mofa_case "DownloadAndVerifyPackage stops when no private download folder can be created"
t_reset_globals
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_stub /usr/bin/mktemp 1
mofa_run DownloadAndVerifyPackage
mofa_assert_status 1 "a mktemp failure exits 1"
mofa_assert_contains "$MOFA_STDERR" "unable to create a temporary folder" "the mktemp failure is logged"
mofa_assert_called /usr/bin/mktemp -d /private/var/tmp/mofa_reset.XXXXXX
mofa_assert_not_called /usr/bin/curl "nothing is downloaded without a private folder"

mofa_case "RepairApp keeps the installed app when the download fails"
t_reset_globals
mofa_mkdir "$T_APP"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_stub /usr/bin/curl 22
mofa_run RepairApp
mofa_assert_status 1 "RepairApp exits 1"
mofa_assert_not_called /bin/rm "the installed app is not removed"
mofa_assert_not_called /usr/sbin/installer "nothing is installed"

mofa_case "RepairApp keeps the installed app when the signature check fails"
t_reset_globals
mofa_mkdir "$T_APP"
t_setup_download "$T_SIGNED_BY_OTHER"
mofa_run RepairApp
mofa_assert_status 1 "RepairApp exits 1"
mofa_assert_not_called /bin/rm "the installed app is not removed"
mofa_assert_not_called /usr/sbin/installer "nothing is installed"

mofa_case "RepairApp verifies, removes the app, installs, then exits"
t_reset_globals
mofa_mkdir "$T_APP"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_run RepairApp
mofa_assert_status 0 "RepairApp exits 0 after a successful install"
mofa_assert_called /bin/rm -rf -- "$T_APP"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /
mofa_assert_called_before /usr/sbin/spctl /bin/rm "the package is verified before the app is removed"
mofa_assert_called_before /bin/rm /usr/sbin/installer "the old app is removed before installing"
mofa_stub /usr/sbin/installer 1
mofa_run RepairApp
mofa_assert_status 1 "an installer failure exits 1"
mofa_assert_contains "$MOFA_STDERR" "Package installation failed" "the installer failure is logged"

mofa_case "CheckInstalledApp in reset mode reports a damaged app without reinstalling"
t_reset_globals
MODE=reset
mofa_write_file "$T_APP/Contents/Info.plist" "plist"
mofa_stub /usr/bin/codesign 1 "invalid signature"
mofa_run CheckInstalledApp
mofa_assert_status 0 "reset mode continues"
mofa_assert_contains "$MOFA_STDOUT" "Reset mode will not reinstall automatically" "damage is reported"
mofa_assert_not_called /usr/bin/curl "reset mode downloads nothing"

mofa_case "CheckInstalledApp in repair mode reinstalls an app not signed by Microsoft"
t_reset_globals
MODE=repair
mofa_write_file "$T_APP/Contents/Info.plist" "plist"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_stub /usr/bin/codesign 0 "TeamIdentifier=ABCDE12345"
mofa_stub_passthrough /usr/bin/grep
mofa_run CheckInstalledApp
mofa_assert_status 0 "the reinstall exits 0"
mofa_assert_contains "$MOFA_STDOUT" "not signed by Microsoft team UBF8T346G9" "the wrong signer is reported"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /

mofa_case "CheckInstalledApp in repair mode reinstalls a missing app"
t_reset_globals
MODE=repair
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_run CheckInstalledApp
mofa_assert_status 0 "the install exits 0"
mofa_assert_contains "$MOFA_STDOUT" "was not found in the default location" "the missing app is reported"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /
mofa_assert_not_called /bin/rm "there is no app to remove"

# --- Custom manifest security --------------------------------------------------------
mofa_case "ReadManifestString refuses option-like and non-https URLs"
t_reset_globals
for bad in "--config=/tmp/mofa_test_curlrc" "-K/tmp/mofa_test_curlrc" "http://manifest.example.com/0409PPT32019.xml" \
	"file:///etc/hosts" "https://" ""; do
	mofa_run ReadManifestString "$bad" FullUpdaterLocation
	mofa_assert_status 1 "ReadManifestString refuses '${bad}'"
	mofa_assert_contains "$MOFA_STDERR" "Refusing to read a manifest" "refusing '${bad}' is logged"
done
mofa_assert_not_called /usr/bin/curl "curl never sees a refused URL"

mofa_case "ReadManifestString passes the URL to curl after --"
t_reset_globals
mofa_stub_handler /usr/bin/curl t_fake_manifest_curl
mofa_stub_passthrough /usr/bin/grep
mofa_stub_passthrough /usr/bin/sed
mofa_run ReadManifestString "https://manifest.example.com/0409PPT32019.xml" FullUpdaterLocation
mofa_assert_eq "https://cdn.example.com/PowerPoint_Installer.pkg" "$MOFA_STDOUT" "the manifest value is extracted"
mofa_assert_called /usr/bin/curl -fsSL --connect-timeout 30 --max-time 120 -- https://manifest.example.com/0409PPT32019.xml

mofa_case "GetCustomManifestVersion ignores a ManifestServer that is not https"
t_reset_globals
mofa_write_file "$T_MANAGED/com.microsoft.autoupdate2.plist" "managed"
mofa_stub_handler /usr/bin/defaults t_fake_defaults
T_CHANNEL=Custom
for T_SERVER in "--config=/tmp/mofa_test_curlrc" "-K /tmp/mofa_test_curlrc" "http://manifest.example.com" \
	"file:///tmp/mofa_test" "ftp://manifest.example.com"; do
	CUSTOM_MANIFEST_CHECKED=""
	mofa_capture GetCustomManifestVersion
	mofa_assert_contains "$MOFA_STDERR" "not an https:// URL" "ManifestServer '${T_SERVER}' is ignored"
	mofa_assert_eq "" "${CUSTOM_VERSION}${FULL_UPDATER}${MANIFEST_SERVER}" "ManifestServer '${T_SERVER}' pins nothing"
done
mofa_assert_not_called /usr/bin/curl "curl never runs for a refused ManifestServer"

mofa_case "GetCustomManifestVersion reads an https manifest server"
t_reset_globals
mofa_write_file "$T_MANAGED/com.microsoft.autoupdate2.plist" "managed"
mofa_stub_handler /usr/bin/defaults t_fake_defaults
mofa_stub_handler /usr/bin/curl t_fake_manifest_curl
mofa_stub_passthrough /usr/bin/grep
mofa_stub_passthrough /usr/bin/sed
T_CHANNEL=Custom
T_SERVER="https://manifest.example.com/"
mofa_capture GetCustomManifestVersion
mofa_assert_eq "16.89.24091630" "$CUSTOM_VERSION" "the pinned version is read"
mofa_assert_eq "https://cdn.example.com/PowerPoint_Installer.pkg" "$FULL_UPDATER" "the package URL is read"
mofa_assert_called /usr/bin/defaults read "$T_MANAGED/com.microsoft.autoupdate2.plist" ChannelName
mofa_assert_called /usr/bin/curl -fsSL --connect-timeout 30 --max-time 120 -- https://manifest.example.com/0409PPT32019.xml
mofa_assert_called /usr/bin/curl -fsSL --connect-timeout 30 --max-time 120 -- https://manifest.example.com/0409PPT32019-chk.xml
mofa_reset_calls
mofa_capture GetCustomManifestVersion
mofa_assert_no_calls "the manifest is read once per run"

mofa_case "GetCustomManifestVersion ignores a non-https FullUpdaterLocation"
t_reset_globals
mofa_write_file "$T_MANAGED/com.microsoft.autoupdate2.plist" "managed"
mofa_stub_handler /usr/bin/defaults t_fake_defaults
t_fake_http_updater_curl() { print -r -- $'<key>FullUpdaterLocation</key>\n<string>http://cdn.example.com/PowerPoint_Installer.pkg</string>'; }
mofa_stub_handler /usr/bin/curl t_fake_http_updater_curl
mofa_stub_passthrough /usr/bin/grep
mofa_stub_passthrough /usr/bin/sed
T_CHANNEL=Custom
T_SERVER="https://manifest.example.com"
mofa_capture GetCustomManifestVersion
mofa_assert_eq "" "${CUSTOM_VERSION}${FULL_UPDATER}" "an http package URL pins nothing"
mofa_assert_eq 1 "$(mofa_call_count /usr/bin/curl)" "the version manifest is not read for an http package URL"

mofa_case "GetPrefValue never reads the console user's own preferences"
t_reset_globals
LoggedInUser=alice
LoggedInUserID=501
mofa_stub /usr/bin/defaults 0 "Custom"
mofa_stub /bin/launchctl 0 "Custom"
mofa_assert_eq "" "$(GetPrefValue com.microsoft.autoupdate2 ChannelName)" "no managed or system value gives an empty result"
mofa_assert_not_called /bin/launchctl "nothing runs in the user's context"
mofa_assert_not_called /usr/bin/defaults "the user's preference domain is not read"

mofa_case "GetPrefValue prefers user-scoped managed, then computer managed, then system preferences"
t_reset_globals
LoggedInUser=alice
LoggedInUserID=501
t_fake_scoped_defaults() { print -r -- "${2:h:t}"; }
mofa_stub_handler /usr/bin/defaults t_fake_scoped_defaults
mofa_write_file "$T_SYSTEM/com.microsoft.autoupdate2.plist" "system"
mofa_assert_eq "system" "$(GetPrefValue com.microsoft.autoupdate2 ChannelName)" "system preferences are used last"
mofa_write_file "$T_MANAGED/com.microsoft.autoupdate2.plist" "managed"
mofa_assert_eq "managed" "$(GetPrefValue com.microsoft.autoupdate2 ChannelName)" "computer-level managed preferences beat system preferences"
mofa_write_file "$T_MANAGED/alice/com.microsoft.autoupdate2.plist" "user managed"
mofa_assert_eq "alice" "$(GetPrefValue com.microsoft.autoupdate2 ChannelName)" "user-scoped managed preferences win"
mofa_assert_not_called /bin/launchctl "nothing runs in the user's context"

mofa_case "CheckInstalledApp in repair mode reinstalls the pinned build from the custom manifest"
t_reset_globals
MODE=repair
mofa_write_file "$T_APP/Contents/Info.plist" "plist"
mofa_write_file "$T_MANAGED/com.microsoft.autoupdate2.plist" "managed"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_stub_handler /usr/bin/defaults t_fake_defaults
mofa_stub_handler /usr/bin/curl t_fake_curl
mofa_stub_passthrough /usr/bin/grep
mofa_stub_passthrough /usr/bin/sed
T_CHANNEL=Custom
T_SERVER="https://manifest.example.com"
T_APP_VERSION="16.80.23121017"
mofa_run CheckInstalledApp
mofa_assert_status 0 "the pinned reinstall exits 0"
mofa_assert_contains "$MOFA_STDOUT" "pinned version has been set to 16.89.24091630" "the version difference is reported"
mofa_assert_called /usr/bin/curl -fsSL --retry 3 --connect-timeout 30 --max-time 3600 -o "$T_WORK/package.pkg" -- https://cdn.example.com/PowerPoint_Installer.pkg
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /
mofa_assert_not_called /usr/bin/codesign "the pinned reinstall exits before the codesign check"

# --- End-to-end flow with every command stubbed ---------------------------------------
mofa_case "main reset flow removes the console user's PowerPoint data after quitting PowerPoint"
t_reset_globals
t_setup_console_user
mofa_stub_handler /usr/bin/find t_fake_find
templates="$T_HOME/$T_GROUP/User Content.localized/Templates.localized"
addins="$T_HOME/$T_GROUP/User Content.localized/Add-Ins"
mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.Powerpoint.plist" "x"
mofa_write_file "$T_HOME/$T_GROUP/MicrosoftRegistrationDB.reg" "x"
mofa_mkdir "$T_HOME/Library/Containers/com.microsoft.Powerpoint"
mofa_mkdir "$T_HOME/$T_GROUP/User Content.localized/Themes"
mofa_mkdir "$T_HOME/$T_GROUP/FontCache"
mofa_write_file "$templates/Pitch.potx" "x"
mofa_write_file "$templates/Keep.docx" "x"
mofa_write_file "$addins/Tools.ppam" "x"
mofa_write_file "$T_HOME/$T_GROUP/Microsoft Office ACL [Pitch]" "x"
mofa_run t_main_flow / computer alice reset
mofa_assert_status 0 "reset flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Running as: alice; Home Folder: ${T_HOME}; Temp Folder: /var/folders/zz/mofa_test/T; Mode: reset" "run context is logged"
mofa_assert_called /usr/bin/pkill -9 "Microsoft PowerPoint"
mofa_assert_called /bin/rm -f -- "$T_HOME/Library/Preferences/com.microsoft.Powerpoint.plist"
mofa_assert_called /bin/rm -f -- "$T_HOME/$T_GROUP/MicrosoftRegistrationDB.reg"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Containers/com.microsoft.Powerpoint"
mofa_assert_called /bin/rm -rf -- "$T_HOME/$T_GROUP/User Content.localized/Themes"
mofa_assert_called /bin/rm -rf -- "$T_HOME/$T_GROUP/FontCache"
mofa_assert_called /bin/rm -f -- "$templates/Pitch.potx"
mofa_assert_called /bin/rm -f -- "$addins/Tools.ppam"
mofa_assert_called /bin/rm -f -- "$T_HOME/$T_GROUP/Microsoft Office ACL [Pitch]"
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "Keep.docx" "other templates are kept"
mofa_assert_contains "$MOFA_STDOUT" "Skipping missing path /var/folders/zz/mofa_test/T/com.microsoft.Powerpoint" "the console user's temp folder is cleaned, not root's"
mofa_assert_called_before /usr/bin/pkill /bin/rm "PowerPoint is stopped before its data is removed"
mofa_assert_not_called /usr/bin/curl "reset mode downloads nothing"
mofa_assert_not_called /usr/sbin/installer "reset mode installs nothing"
t_calls=("${(@f)$(mofa_calls)}")
mofa_assert_eq "t_cleanup_probe" "${t_calls[-1]}" "the EXIT trap cleans up after main finishes, not before"

mofa_case "main reset flow without a console user touches no user data"
t_reset_globals
mofa_stub /usr/sbin/scutil 0 "  Name : loginwindow"
mofa_stub_passthrough /usr/bin/awk
mofa_stub_handler /usr/bin/find t_fake_find
mofa_run t_main_flow / computer "" reset
mofa_assert_status 0 "reset flow without a user exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Running as: <none>; Home Folder: /var/empty; Temp Folder: /var/empty; Mode: reset" "the missing user is logged"
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "/var/empty" "nothing under /var/empty is removed"
mofa_assert_not_called /bin/launchctl "nothing runs in a user's context"

mofa_case "main reset flow exits 1 when a removal fails"
t_reset_globals
t_setup_console_user
mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.Powerpoint.plist" "x"
mofa_stub /bin/rm 1
mofa_run t_main_flow / computer alice reset
mofa_assert_status 1 "a removal failure is reported to Jamf"
mofa_assert_contains "$MOFA_STDERR" "removal failure(s)" "the failure count is logged"

mofa_case "main force flow keeps the app and its data when the download fails"
t_reset_globals
mofa_mkdir "$T_APP"
mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.Powerpoint.plist" "x"
t_setup_console_user
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_stub /usr/bin/curl 22
mofa_run t_main_flow / computer alice force
mofa_assert_status 1 "a failed download exits 1"
mofa_assert_not_called /bin/rm "neither the app nor configuration data is removed"
mofa_assert_not_called /usr/sbin/installer "nothing is installed"
mofa_assert_called_before /usr/bin/curl t_cleanup_probe "the EXIT trap cleans up after a failure exit"

mofa_case "main force flow reinstalls and keeps configuration data"
t_reset_globals
mofa_mkdir "$T_APP"
mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.Powerpoint.plist" "x"
t_setup_console_user
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_run t_main_flow / computer alice force
mofa_assert_status 0 "a successful reinstall exits 0"
mofa_assert_eq "/bin/rm -rf -- ${(q+)T_APP}" "$(mofa_calls /bin/rm)" "only the app bundle is removed"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /
mofa_assert_contains "$MOFA_STDOUT" "Exiting without removing configuration data" "configuration data is kept"
mofa_assert_called_before /usr/sbin/installer t_cleanup_probe "the EXIT trap cleans up after the install"

mofa_finish
