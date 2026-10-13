#!/bin/zsh --no-rcs
# Tests for office_reset_tools/mofa_community_maintained/scripts/MOFA_Community_Microsoft_OneDrive_Reset.zsh.
# Run as an unprivileged user: zsh tests/reset_scripts/test_OneDrive_Reset.zsh (or run_all.zsh).
# Every system command is a recording stub (see harness.zsh); nothing outside the sandbox changes.
# The script also removes a few fixed system paths (/Library/Preferences/..., /Library/Logs/...);
# when they exist on the test Mac only the /bin/rm stub sees them, so no assertion depends on them.

source "${0:A:h}/harness.zsh"

mofa_source_script MOFA_Community_Microsoft_OneDrive_Reset.zsh
mofa_assert_source_clean
mofa_stub t_cleanup_probe 0 # a recording stub that t_main_flow's CleanupWorkDir calls

integer T_CASE=0
T_DOWNLOAD_URL="https://go.microsoft.com/fwlink/?linkid=861011"
T_USER_TMP="/var/folders/zz/mofa_test/T"
T_SIGNED_BY_MICROSOFT=$'Package "package.pkg":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Certificate Chain:\n    1. Developer ID Installer: Microsoft Corporation (UBF8T346G9)'
T_SIGNED_BY_OTHER=$'Package "package.pkg":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Certificate Chain:\n    1. Developer ID Installer: Microsoft Corporation (ABCDE12345)'
# The only paths outside the console user's home that the script may remove.
T_SYSTEM_TARGETS=(
	"/Library/Logs/Microsoft/OneDrive"
	"/Library/Preferences/com.microsoft.OneDrive.plist"
	"/Library/Preferences/com.microsoft.OneDriveStandaloneUpdater.plist"
	"/Library/Preferences/com.microsoft.OneDriveUpdater.plist"
	"/Library/Managed Preferences/com.microsoft.OneDriveStandaloneUpdater.plist"
	"/Library/Managed Preferences/com.microsoft.OneDriveUpdater.plist"
)

# --- Test helpers (t_ prefix: never clash with script functions) ---------------------
t_reset_globals() { # fresh script globals and per-case fixture paths inside the sandbox
	(( T_CASE++ ))
	T_DIR="$MOFA_TEST_ROOT/case${T_CASE}"
	T_WORK="$T_DIR/work"
	T_HOME="$T_DIR/home/alice"
	T_APP="$T_DIR/Applications/OneDrive.app"
	mofa_mkdir "$T_DIR"
	unset MODE
	REMOVAL_FAILURES=0
	LoggedInUser=""
	LoggedInUserID=""
	WORK_DIR=""
	PKG_PATH=""
	APP_PATH="$T_APP"
	T_KEYCHAINS=""
	T_VERIFY_ERROR=""
	T_TEAM="UBF8T346G9"
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
		*"/usr/bin/getconf DARWIN_USER_TEMP_DIR") print -r -- "${T_USER_TMP}/" ;;
		*"/usr/bin/security list-keychains -d user") [[ -n "$T_KEYCHAINS" ]] && print -r -- "$T_KEYCHAINS" ;;
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

t_fake_codesign() { # codesign --verify --deep -vv APP | codesign -dv APP
	case "$1" in
		--verify)
			if [[ -n "$T_VERIFY_ERROR" ]]; then
				print -r -- "$T_VERIFY_ERROR"
				return 1
			fi
			;;
		-dv) print -r -- $'Executable='"${2}"$'/Contents/MacOS/OneDrive\nTeamIdentifier='"${T_TEAM}" ;;
	esac
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

t_setup_console_user() { # console user alice with a sandbox home and /var/folders temp folder
	mofa_mkdir "$T_HOME"
	mofa_stub /usr/sbin/scutil 0 "  Name : alice"
	mofa_stub_passthrough /usr/bin/awk
	mofa_stub_passthrough /usr/bin/sed
	mofa_stub_passthrough /usr/bin/grep
	mofa_stub_handler /bin/launchctl t_fake_launchctl
	mofa_stub_handler /usr/bin/codesign t_fake_codesign
}

t_call_index() { # $@: exact argv; prints the 1-based position of its first call, or 0
	local want="${(j: :)${(q+)@}}"
	local -a lines
	local -i i
	lines=("${(@f)$(mofa_calls)}")
	i=${lines[(ie)$want]}
	(( i <= ${#lines} )) || i=0
	print -r -- "$i"
}

t_rm_targets() { # prints the last argument (the target) of every /bin/rm call, unquoted
	local line
	local -a words
	for line in "${(@f)$(mofa_calls /bin/rm)}"; do
		[[ -n "$line" ]] || continue
		words=("${(@Q)${(z)line}}")
		print -r -- "${words[-1]}"
	done
}

t_assert_rm_confined() { # $1: home the run used; every rm target is under it or a listed system path
	local target bad=""
	for target in "${(@f)$(t_rm_targets)}"; do
		[[ -n "$target" ]] || continue
		[[ "$target" == "$1"/?* ]] && continue
		(( ${T_SYSTEM_TARGETS[(Ie)$target]} )) && continue
		bad+="${target}"$'\n'
	done
	if [[ -z "$bad" ]]; then
		mofa_pass "every removal is under ${1:t} or a listed OneDrive system path"
	else
		mofa_fail "every removal is under ${1:t} or a listed OneDrive system path" "unexpected:"$'\n'"${bad}"
	fi
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
mofa_assert_no_calls "an invalid mode stops before any command runs"
mofa_run t_main_flow bogus bogus bogus reset
mofa_assert_status 0 "parameters 1-3 are ignored"

mofa_case "main refuses to run without root"
t_reset_globals
mofa_run main / computer alice reset
mofa_assert_status 1 "main exits 1 when not root"
mofa_assert_contains "$MOFA_STDOUT" "Starting postinstall for Reset_OneDrive" "start banner precedes the root check"
mofa_assert_contains "$MOFA_STDERR" "must be run as root" "root check message"
mofa_assert_no_calls "nothing runs before the root check"

# --- Console user, home and temp folder safety ----------------------------------------
mofa_case "GetLoggedInUser ignores loginwindow"
t_reset_globals
mofa_stub_passthrough /usr/bin/awk
mofa_stub /usr/sbin/scutil 0 $'<dictionary> {\n  Name : loginwindow\n  UID : 0\n}'
mofa_assert_eq "" "$(GetLoggedInUser)" "loginwindow is not a console user"
mofa_stub /usr/sbin/scutil 0 $'<dictionary> {\n  Name : alice\n  UID : 501\n}'
mofa_assert_eq "alice" "$(GetLoggedInUser)" "the console user name is read"

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
target="$T_HOME/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"
mofa_mkdir "$target"
mofa_capture removeTarget -rf "$target"
mofa_assert_status 0 "removeTarget succeeds"
mofa_assert_called /bin/rm -rf -- "$target"
mofa_assert_eq 1 "$(mofa_call_count /bin/rm)" "rm runs once"
mofa_assert_eq 0 "$REMOVAL_FAILURES" "no failure counted"
[[ -d "$target" ]] && mofa_pass "the stub did not delete anything" || mofa_fail "the stub did not delete anything"
plist="$T_HOME/Library/Preferences/com.microsoft.OneDrive.plist"
mofa_write_file "$plist" "x"
mofa_capture removeFileList "$plist"
mofa_assert_called /bin/rm -f -- "$plist"

mofa_case "removeTarget counts rm failures and skips missing paths"
t_reset_globals
plist="$T_HOME/Library/Preferences/com.microsoft.OneDrive.plist"
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
mofa_assert_called /usr/bin/curl -fsSL --retry 3 --connect-timeout 30 --max-time 3600 -o "$T_WORK/package.pkg" -- "$T_DOWNLOAD_URL"
mofa_assert_called /usr/sbin/pkgutil --check-signature "$T_WORK/package.pkg"
mofa_assert_not_called /usr/sbin/spctl "Gatekeeper is not consulted after a signer mismatch"
mofa_assert_not_called /usr/sbin/installer "nothing is installed"

mofa_case "DownloadAndVerifyPackage requires Gatekeeper and a non-empty download"
t_reset_globals
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_run DownloadAndVerifyPackage
mofa_assert_status 0 "a Microsoft-signed package passes"
mofa_assert_called /usr/sbin/spctl -a -t install "$T_WORK/package.pkg"
mofa_assert_not_contains "$MOFA_STDOUT" "may not install" "no macOS warning on a supported version"
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

mofa_case "DownloadAndVerifyPackage warns on old macOS and stops without a temporary folder"
t_reset_globals
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_stub /usr/bin/sw_vers 0 "14.3"
mofa_stub /usr/bin/mktemp 1
mofa_run DownloadAndVerifyPackage
mofa_assert_status 1 "a failed mktemp exits 1"
mofa_assert_contains "$MOFA_STDOUT" "macOS is older than 14.4" "an old macOS is warned about"
mofa_assert_contains "$MOFA_STDERR" "unable to create a temporary folder" "the mktemp failure is logged"
mofa_assert_called /usr/bin/mktemp -d /private/var/tmp/mofa_reset.XXXXXX
mofa_assert_not_called /usr/bin/curl "nothing is downloaded without a private folder"

mofa_case "RepairApp replace keeps the installed app when the download fails"
t_reset_globals
mofa_mkdir "$T_APP"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_stub /usr/bin/curl 22
mofa_run RepairApp replace
mofa_assert_status 1 "RepairApp exits 1"
mofa_assert_not_called /bin/rm "the installed app is not removed"
mofa_assert_not_called /usr/sbin/installer "nothing is installed"

mofa_case "RepairApp replace verifies, removes the app, then installs"
t_reset_globals
mofa_mkdir "$T_APP"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_run RepairApp replace
mofa_assert_status 0 "RepairApp returns 0 after a successful install"
mofa_assert_eq "/bin/rm -rf -- ${(q+)T_APP}" "$(mofa_calls /bin/rm)" "only the app bundle is removed"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /
mofa_assert_called_before /usr/sbin/spctl /bin/rm "the package is verified before the app is removed"
mofa_assert_called_before /bin/rm /usr/sbin/installer "the old app is removed before installing"
mofa_stub /usr/sbin/installer 1
mofa_run RepairApp replace
mofa_assert_status 1 "an installer failure exits 1"
mofa_assert_contains "$MOFA_STDERR" "Package installation failed" "the installer failure is logged"

mofa_case "RepairApp without replace installs over the existing app"
t_reset_globals
mofa_mkdir "$T_APP"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_run RepairApp
mofa_assert_status 0 "RepairApp returns 0"
mofa_assert_not_called /bin/rm "the app is not removed for an in-place update"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /

mofa_case "AppSignatureProblem reports codesign errors and a foreign team"
t_reset_globals
mofa_stub_handler /usr/bin/codesign t_fake_codesign
mofa_stub_passthrough /usr/bin/grep
mofa_run AppSignatureProblem
mofa_assert_status 1 "a valid Microsoft signature is not a problem"
mofa_assert_called /usr/bin/codesign --verify --deep -vv "$T_APP"
mofa_assert_called /usr/bin/codesign -dv "$T_APP"
T_TEAM="ABCDE12345"
mofa_run AppSignatureProblem
mofa_assert_status 0 "another team's signature is a problem"
mofa_assert_eq "app is not signed by Microsoft team UBF8T346G9" "$MOFA_STDOUT" "the foreign team is reported"
T_VERIFY_ERROR="a sealed resource is missing or invalid"
mofa_run AppSignatureProblem
mofa_assert_status 0 "a codesign failure is a problem"
mofa_assert_eq "$T_VERIFY_ERROR" "$MOFA_STDOUT" "the codesign error is reported"

# --- End-to-end flow with every command stubbed ---------------------------------------
mofa_case "main reset flow stops only OneDrive processes, then removes the console user's data"
t_reset_globals
t_setup_console_user
mofa_stub /usr/bin/find 0 "$T_HOME/Library/Keychains/MOFA-TEST-UUID/keychain-2.db"
mofa_stub_passthrough /usr/bin/head
T_KEYCHAINS=$'    "/Library/Keychains/System.keychain"'
mofa_mkdir "$T_HOME/Library/Containers/com.microsoft.OneDrive-mac" \
	"$T_HOME/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite" \
	"$T_HOME/Library/Group Containers/UBF8T346G9.com.microsoft.oneauth" \
	"$T_HOME/Library/Group Containers/UBF8T346G9.Office"
mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.OneDrive.plist" "x"
mofa_write_file "$T_HOME/Library/Cookies/com.microsoft.OneDrive.binarycookies" "x"
mofa_run t_main_flow / computer alice reset
mofa_assert_status 0 "reset flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Running as: alice; Home Folder: ${T_HOME}; Temp Folder: ${T_USER_TMP}; Mode: reset" "run context is logged"
mofa_assert_called /usr/bin/pkill -9 OneDrive
mofa_assert_called /usr/bin/pkill -9 "OneDrive Finder Integration"
mofa_assert_called /usr/bin/pkill -9 OneDriveStandaloneUpdater
mofa_assert_called /usr/bin/pkill -9 OneDriveUpdater
mofa_assert_eq 4 "$(mofa_call_count /usr/bin/pkill)" "exactly four OneDrive process patterns are killed"
mofa_assert_not_contains "$(mofa_calls /usr/bin/pkill)" "FinderSync" "no pkill pattern matches other vendors' Finder Sync extensions"
mofa_assert_not_called /usr/bin/killall "no other process killer runs"
mofa_assert_called_before /usr/bin/pkill /bin/rm "OneDrive is stopped before its data is removed"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Containers/com.microsoft.OneDrive-mac"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Group Containers/UBF8T346G9.com.microsoft.oneauth"
mofa_assert_called /bin/rm -f -- "$T_HOME/Library/Preferences/com.microsoft.OneDrive.plist"
mofa_assert_called /bin/rm -f -- "$T_HOME/Library/Cookies/com.microsoft.OneDrive.binarycookies"
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "${(q+):-$T_HOME/Library/Group Containers/UBF8T346G9.Office}" "the shared Office group container is kept"
t_assert_rm_confined "$T_HOME"
mofa_assert_contains "$MOFA_STDOUT" "Skipping missing path ${T_USER_TMP}/com.microsoft.OneDrive" "the console user's temp folder is cleaned, not root's"
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/security list-keychains -d user -s "$T_HOME/Library/Keychains/login.keychain-db" /Library/Keychains/System.keychain
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/security delete-generic-password -l "OneDrive Standalone Cached Credential"
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/security delete-generic-password -s OneAuthAccount
mofa_assert_called /usr/bin/find "$T_HOME/Library/Keychains" -name keychain-2.db
mofa_assert_called /usr/bin/sqlite3 "$T_HOME/Library/Keychains/MOFA-TEST-UUID/keychain-2.db" "DELETE FROM genp WHERE agrp='UBF8T346G9.com.microsoft.identity.universalstorage';"
mofa_assert_contains "$MOFA_STDOUT" "was not found in the default location" "a missing app is reported"
mofa_assert_not_called /usr/bin/curl "reset mode downloads nothing"
mofa_assert_not_called /usr/sbin/installer "reset mode installs nothing"
t_calls=("${(@f)$(mofa_calls)}")
mofa_assert_eq "t_cleanup_probe" "${t_calls[-1]}" "the EXIT trap cleans up after main finishes, not before"

mofa_case "main keeps the existing keychain search list when it already has the login keychain"
t_reset_globals
t_setup_console_user
T_KEYCHAINS=$'    "'"${T_HOME}"$'/Library/Keychains/login.keychain-db"\n    "/Library/Keychains/System.keychain"'
mofa_run t_main_flow / computer alice reset
mofa_assert_status 0 "reset flow exits 0"
mofa_assert_not_contains "$(mofa_calls /bin/launchctl)" "list-keychains -d user -s" "the search list is not rewritten"
mofa_assert_not_called /usr/bin/sqlite3 "no keychain-2.db, no sqlite3"

mofa_case "main adds only the login keychain when the user's search list is empty"
t_reset_globals
t_setup_console_user
mofa_run t_main_flow / computer alice reset
mofa_assert_status 0 "reset flow exits 0"
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/security list-keychains -d user -s "$T_HOME/Library/Keychains/login.keychain-db"

mofa_case "main without a console user skips user-context work"
t_reset_globals
mofa_stub_passthrough /usr/bin/awk
mofa_stub /usr/sbin/scutil 0 "  Name : loginwindow"
mofa_run t_main_flow / computer "" reset
mofa_assert_status 0 "reset flow without a user exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Running as: <none>; Home Folder: /var/empty; Temp Folder: /var/empty; Mode: reset" "run context is logged"
mofa_assert_contains "$MOFA_STDOUT" "skipping user keychain cleanup" "keychain cleanup is skipped"
mofa_assert_not_called /bin/launchctl "nothing runs in a user's context"
mofa_assert_not_called /usr/bin/sqlite3 "no keychain database is changed"
t_assert_rm_confined "/var/empty"

mofa_case "main reset flow exits 1 when a removal fails"
t_reset_globals
t_setup_console_user
mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.OneDrive.plist" "x"
mofa_stub /bin/rm 1
mofa_run t_main_flow / computer alice reset
mofa_assert_status 1 "a removal failure is reported to Jamf"
mofa_assert_contains "$MOFA_STDERR" "removal failure(s)" "the failure count is logged"

mofa_case "main reset flow reports an ancient or damaged app without reinstalling"
t_reset_globals
t_setup_console_user
mofa_mkdir "$T_APP"
mofa_stub /usr/bin/defaults 0 "22001.0101.0001"
T_VERIFY_ERROR="invalid signature"
mofa_run t_main_flow / computer alice reset
mofa_assert_status 0 "reset mode continues"
mofa_assert_called /usr/bin/defaults read "$T_APP/Contents/Info.plist" CFBundleVersion
mofa_assert_contains "$MOFA_STDOUT" "is ancient. Reset mode will not reinstall automatically" "the old build is reported"
mofa_assert_contains "$MOFA_STDOUT" "damaged. Reset mode will not reinstall automatically" "damage is reported"
mofa_assert_not_called /usr/bin/curl "reset mode downloads nothing"
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "${(q+)T_APP}" "reset mode keeps the app"

mofa_case "main repair flow updates an ancient app in place"
t_reset_globals
t_setup_console_user
mofa_mkdir "$T_APP"
mofa_stub /usr/bin/defaults 0 "22001.0101.0001"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_run t_main_flow / computer alice repair
mofa_assert_status 0 "repair flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "is ancient. Reinstall mode enabled, updating it now" "the update is logged"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "${(q+)T_APP}" "an in-place update keeps the bundle"
mofa_assert_contains "$MOFA_STDOUT" "Codesign passed successfully" "the updated app is checked"

mofa_case "main repair flow leaves a current, valid app alone"
t_reset_globals
t_setup_console_user
mofa_mkdir "$T_APP"
mofa_stub /usr/bin/defaults 0 "26168.0830.0006"
mofa_run t_main_flow / computer alice repair
mofa_assert_status 0 "repair flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Found version 26168.0830.0006 of Microsoft OneDrive" "the version is logged"
mofa_assert_not_called /usr/bin/curl "a current app is not downloaded again"

mofa_case "main repair flow replaces a damaged app only after verifying the package"
t_reset_globals
t_setup_console_user
mofa_mkdir "$T_APP"
mofa_stub /usr/bin/defaults 0 "26168.0830.0006"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
T_TEAM="ABCDE12345"
mofa_run t_main_flow / computer alice repair
mofa_assert_status 0 "repair flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "damaged and will be reinstalled" "the damage is logged"
t_spctl=$(t_call_index /usr/sbin/spctl -a -t install "$T_WORK/package.pkg")
t_rm_app=$(t_call_index /bin/rm -rf -- "$T_APP")
t_install=$(t_call_index /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /)
if (( t_spctl > 0 && t_spctl < t_rm_app && t_rm_app < t_install )); then
	mofa_pass "verify, remove the damaged app, then install"
else
	mofa_fail "verify, remove the damaged app, then install" "spctl ${t_spctl}, rm ${t_rm_app}, installer ${t_install}"$'\n'"$(mofa_calls)"
fi

mofa_case "main repair flow installs a missing app"
t_reset_globals
t_setup_console_user
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_run t_main_flow / computer alice reinstall
mofa_assert_status 0 "reinstall flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Reinstall mode enabled, installing Microsoft OneDrive" "the install is logged"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /

mofa_case "main force flow resets configuration, then verifies, replaces and installs"
t_reset_globals
t_setup_console_user
mofa_mkdir "$T_APP"
mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.OneDrive.plist" "x"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_run t_main_flow / computer alice force
mofa_assert_status 0 "a successful reinstall exits 0"
t_cfg=$(t_call_index /bin/rm -f -- "$T_HOME/Library/Preferences/com.microsoft.OneDrive.plist")
t_curl=$(t_call_index /usr/bin/curl -fsSL --retry 3 --connect-timeout 30 --max-time 3600 -o "$T_WORK/package.pkg" -- "$T_DOWNLOAD_URL")
t_spctl=$(t_call_index /usr/sbin/spctl -a -t install "$T_WORK/package.pkg")
t_rm_app=$(t_call_index /bin/rm -rf -- "$T_APP")
t_install=$(t_call_index /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /)
if (( t_cfg > 0 && t_cfg < t_curl && t_curl < t_spctl && t_spctl < t_rm_app && t_rm_app < t_install )); then
	mofa_pass "reset, download, verify, remove the app, then install"
else
	mofa_fail "reset, download, verify, remove the app, then install" \
		"config ${t_cfg}, curl ${t_curl}, spctl ${t_spctl}, rm app ${t_rm_app}, installer ${t_install}"$'\n'"$(mofa_calls)"
fi
mofa_assert_not_called /usr/bin/codesign "force mode does not inspect the old app"

mofa_case "main force flow keeps the app when the download fails"
t_reset_globals
t_setup_console_user
mofa_mkdir "$T_APP"
mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.OneDrive.plist" "x"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_stub /usr/bin/curl 22
mofa_run t_main_flow / computer alice force
mofa_assert_status 1 "a failed download exits 1"
mofa_assert_called /bin/rm -f -- "$T_HOME/Library/Preferences/com.microsoft.OneDrive.plist"
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "${(q+)T_APP}" "the installed app is kept"
mofa_assert_not_called /usr/sbin/installer "nothing is installed"
mofa_assert_called_before /usr/bin/curl t_cleanup_probe "the EXIT trap cleans up after a failure exit"

mofa_finish
