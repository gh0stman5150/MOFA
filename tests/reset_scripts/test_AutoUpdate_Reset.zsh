#!/bin/zsh --no-rcs
# Tests for office_reset_tools/mofa_community_maintained/scripts/MOFA_Community_Microsoft_AutoUpdate_Reset.zsh.
# Run as an unprivileged user: zsh tests/reset_scripts/test_AutoUpdate_Reset.zsh (or run_all.zsh).
# Every system command is a recording stub (see harness.zsh); nothing outside the sandbox changes.
# The script names fixed system paths (/Library/LaunchAgents, /Library/Preferences, /Applications);
# their presence on the test Mac only decides whether a stub is called, so assertions here use
# sandbox paths (APP_PATH, the console user's home) or exact argv for the fixed paths.

source "${0:A:h}/harness.zsh"

mofa_source_script MOFA_Community_Microsoft_AutoUpdate_Reset.zsh
mofa_assert_source_clean
mofa_stub t_cleanup_probe 0 # a recording stub that t_main_flow's CleanupWorkDir calls

integer T_CASE=0
T_SIGNED_BY_MICROSOFT=$'Package "package.pkg":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Certificate Chain:\n    1. Developer ID Installer: Microsoft Corporation (UBF8T346G9)'
T_SIGNED_BY_OTHER=$'Package "package.pkg":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Certificate Chain:\n    1. Developer ID Installer: Microsoft Corporation (ABCDE12345)'
T_MAU_URL="https://go.microsoft.com/fwlink/?linkid=830196"
T_MAU_PREFS="/Library/Preferences/com.microsoft.autoupdate2"

# --- Test helpers (t_ prefix: never clash with script functions) ---------------------
t_reset_globals() { # fresh script globals and per-case fixture paths inside the sandbox
	(( T_CASE++ ))
	T_DIR="$MOFA_TEST_ROOT/case${T_CASE}"
	T_WORK="$T_DIR/work"
	T_HOME="$T_DIR/home/alice"
	T_APP="$T_DIR/MAU2.0/Microsoft AutoUpdate.app"
	mofa_mkdir "$T_DIR"
	unset MODE
	REMOVAL_FAILURES=0
	LoggedInUser=""
	LoggedInUserID=""
	USER_TMPDIR=""
	WORK_DIR=""
	PKG_PATH=""
	APP_VERSION=""
	SIGNATURE_PROBLEM=""
	APP_PATH="$T_APP"
	T_APP_VERSION=""
	T_APP_TEAM="UBF8T346G9"
	T_CODESIGN_ERROR=""
	T_USER_TMP="/var/folders/zz/mofa_test/T/"
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

t_fake_launchctl() { # launchctl asuser UID sudo -H -u USER CMD... reports T_USER_TMP; all else succeeds
	case "$*" in
		*"/usr/bin/getconf DARWIN_USER_TEMP_DIR"*) print -r -- "$T_USER_TMP" ;;
	esac
	return 0
}

t_fake_launchctl_no_bootout() { # bootout fails, so bootoutJob must fall back to unload
	[[ "$1" == bootout ]] && return 5
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

t_fake_defaults() { # reads only the sandbox app's CFBundleVersion (T_APP_VERSION); writes succeed
	case "$1" in
		read)
			[[ "$2" == "$T_APP/Contents/Info.plist" && "$3" == CFBundleVersion && -n "$T_APP_VERSION" ]] || return 1
			print -r -- "$T_APP_VERSION"
			;;
		write) return 0 ;;
		*) return 1 ;;
	esac
}

t_fake_codesign() { # --verify fails with T_CODESIGN_ERROR when set; -dv reports T_APP_TEAM
	case "$1" in
		--verify)
			if [[ -n "$T_CODESIGN_ERROR" ]]; then
				print -r -- "$T_CODESIGN_ERROR"
				return 1
			fi
			return 0
			;;
		-dv)
			print -r -- "Executable=${2}/Contents/MacOS/Microsoft AutoUpdate"
			print -r -- "TeamIdentifier=${T_APP_TEAM}"
			return 0
			;;
	esac
	return 1
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

t_setup_main() { # console user alice with a sandbox home, an installed sandbox MAU and a clean signature
	mofa_stub /usr/sbin/scutil 0 "  Name : alice"
	mofa_stub_passthrough /usr/bin/awk
	mofa_stub_passthrough /usr/bin/grep
	mofa_stub_handler /bin/launchctl t_fake_launchctl
	mofa_stub_handler /usr/bin/defaults t_fake_defaults
	mofa_stub_handler /usr/bin/codesign t_fake_codesign
	mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.autoupdate2.plist" "x"
	mofa_mkdir "$T_HOME/Library/Caches/com.microsoft.autoupdate2"
	mofa_mkdir "$T_HOME/Library/Application Support/Microsoft AU Daemon"
	mofa_write_file "$T_APP/Contents/Info.plist" "plist"
	T_APP_VERSION="4.83.26040910"
}

t_rm_calls_for_app() { # prints the /bin/rm calls that target the sandbox app bundle
	local line
	for line in "${(@f)$(mofa_calls /bin/rm)}"; do
		[[ "$line" == *"Microsoft AutoUpdate.app"* ]] && print -r -- "$line"
	done
	return 0
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
mofa_assert_contains "$MOFA_STDOUT" "Starting postinstall for Reset_AutoUpdate" "the start banner is printed first"
mofa_assert_no_calls "an invalid mode stops before any command runs"
MODE=bogus mofa_run t_main_flow / computer alice ""
mofa_assert_status 2 "main falls back to the MODE environment value when parameter 4 is empty"
mofa_assert_no_calls "an invalid MODE environment value stops before any command runs"
mofa_run t_main_flow bogus bogus bogus reset
mofa_assert_status 0 "parameters 1-3 are ignored"
mofa_assert_contains "$MOFA_STDOUT" "Mode: reset" "parameter 4 sets the mode"

mofa_case "main refuses to run without root"
t_reset_globals
mofa_run main / computer alice reset
mofa_assert_status 1 "main exits 1 when not root"
mofa_assert_contains "$MOFA_STDOUT" "Starting postinstall for Reset_AutoUpdate" "start banner precedes the root check"
mofa_assert_contains "$MOFA_STDERR" "must be run as root" "root check message"
mofa_assert_no_calls "nothing runs before the root check"

mofa_case "shouldReinstall is true only for repair, reinstall and force"
t_reset_globals
for MODE expected in reset 1 repair 0 reinstall 0 force 0; do
	mofa_capture shouldReinstall
	mofa_assert_status "$expected" "shouldReinstall in ${MODE} mode returns ${expected}"
done
unset MODE

# --- Console user, home and temp folder safety --------------------------------------
mofa_case "GetLoggedInUser ignores the login window"
t_reset_globals
mofa_stub_passthrough /usr/bin/awk
mofa_stub /usr/sbin/scutil 0 "  Name : alice"
mofa_assert_eq "alice" "$(GetLoggedInUser)" "the console user is read from scutil"
mofa_stub /usr/sbin/scutil 0 "  Name : loginwindow"
mofa_assert_eq "" "$(GetLoggedInUser)" "no user at the login window"

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

mofa_case "runAsUser runs only in a known console user's context"
t_reset_globals
mofa_capture runAsUser /usr/bin/true
mofa_assert_status 1 "runAsUser fails without a console user"
mofa_assert_contains "$MOFA_STDERR" "No logged-in user detected" "the skip is logged"
mofa_assert_not_called /bin/launchctl "nothing runs as a user without a console user"
LoggedInUser=alice
LoggedInUserID=501
mofa_capture runAsUser /usr/bin/getconf DARWIN_USER_TEMP_DIR
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/getconf DARWIN_USER_TEMP_DIR

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
target="$T_HOME/Library/Application Support/Microsoft AU Daemon"
mofa_mkdir "$target"
mofa_capture removePathList "$target"
mofa_assert_status 0 "removePathList succeeds"
mofa_assert_called /bin/rm -rf -- "$target"
mofa_assert_eq 1 "$(mofa_call_count /bin/rm)" "rm runs once"
mofa_assert_eq 0 "$REMOVAL_FAILURES" "no failure counted"
[[ -d "$target" ]] && mofa_pass "the stub did not delete anything" || mofa_fail "the stub did not delete anything"
plist="$T_HOME/Library/Preferences/com.microsoft.autoupdate2.plist"
mofa_write_file "$plist" "x"
mofa_capture removeFileList "$plist"
mofa_assert_called /bin/rm -f -- "$plist"

mofa_case "removeTarget counts rm failures and skips missing paths"
t_reset_globals
plist="$T_HOME/Library/Preferences/com.microsoft.autoupdate2.plist"
mofa_write_file "$plist" "x"
mofa_stub /bin/rm 1
mofa_capture removeTarget -f "$plist"
mofa_assert_status 1 "a failed rm returns 1"
mofa_assert_eq 1 "$REMOVAL_FAILURES" "a failed rm is counted"
mofa_assert_contains "$MOFA_STDERR" "Failed to remove" "a failed rm is logged"
mofa_reset_calls
mofa_capture removeTarget -rf "$T_HOME/Library/Caches/missing"
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

# --- launchd jobs -------------------------------------------------------------------
mofa_case "bootoutJob stops existing MAU jobs in the right domain"
t_reset_globals
agent="$T_DIR/LaunchAgents/com.microsoft.update.agent.plist"
daemon="$T_DIR/LaunchDaemons/com.microsoft.autoupdate.helper.plist"
mofa_write_file "$agent" "agent"
mofa_write_file "$daemon" "daemon"
mofa_capture bootoutJob gui "$T_DIR/LaunchAgents/missing.plist"
mofa_assert_contains "$MOFA_STDOUT" "Skipping missing launchd item" "a missing job is skipped"
mofa_capture bootoutJob gui "$agent"
mofa_assert_contains "$MOFA_STDOUT" "skipping gui launchd item" "a gui job needs a console user"
mofa_assert_not_called /bin/launchctl "launchctl does not run for a missing job or without a console user"
LoggedInUser=alice
LoggedInUserID=501
mofa_capture bootoutJob gui "$agent"
mofa_assert_called /bin/launchctl bootout gui/501 "$agent"
mofa_capture bootoutJob system "$daemon"
mofa_assert_called /bin/launchctl bootout system "$daemon"
mofa_assert_not_contains "$(mofa_calls /bin/launchctl)" "unload" "unload is not needed after a successful bootout"
mofa_reset_calls
mofa_stub_handler /bin/launchctl t_fake_launchctl_no_bootout
mofa_capture bootoutJob system "$daemon"
mofa_assert_status 0 "a failed bootout is not fatal"
mofa_assert_called /bin/launchctl unload "$daemon"

mofa_case "bootstrapJob restarts existing MAU jobs only"
t_reset_globals
agent="$T_DIR/LaunchAgents/com.microsoft.update.agent.plist"
daemon="$T_DIR/LaunchDaemons/com.microsoft.autoupdate.helper.plist"
mofa_write_file "$agent" "agent"
mofa_write_file "$daemon" "daemon"
mofa_capture bootstrapJob system "$T_DIR/LaunchDaemons/missing.plist"
mofa_capture bootstrapJob gui "$agent"
mofa_assert_not_called /bin/launchctl "nothing starts for a missing job or without a console user"
mofa_capture bootstrapJob system "$daemon"
mofa_assert_called /bin/launchctl bootstrap system "$daemon"
mofa_assert_contains "$MOFA_STDOUT" "Started launchd item $daemon" "the restart is logged"
LoggedInUser=alice
LoggedInUserID=501
mofa_capture bootstrapJob gui "$agent"
mofa_assert_called /bin/launchctl bootstrap gui/501 "$agent"

# --- MAU registrations --------------------------------------------------------------
mofa_case "registerMauApp registers installed apps only, with an optional app domain"
t_reset_globals
office_app="$T_DIR/Applications/Microsoft Word.app"
edge_app="$T_DIR/Applications/Microsoft Edge.app"
mofa_capture registerMauApp "$office_app" MSWD2019 com.microsoft.office
mofa_assert_not_called /usr/bin/defaults "a missing app is not registered"
mofa_mkdir "$office_app" "$edge_app"
mofa_capture registerMauApp "$office_app" MSWD2019 com.microsoft.office
mofa_assert_called /usr/bin/defaults write "$T_MAU_PREFS" Applications -dict-add "$office_app" "{ 'Application ID' = 'MSWD2019'; 'App Domain' = 'com.microsoft.office' ; }"
mofa_capture registerMauApp "$edge_app" EDGE01
mofa_assert_called /usr/bin/defaults write "$T_MAU_PREFS" Applications -dict-add "$edge_app" "{ 'Application ID' = 'EDGE01'; }"

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

# --- App signature check ------------------------------------------------------------
mofa_case "AppSignatureProblem reports codesign errors and a foreign team"
t_reset_globals
mofa_mkdir "$T_APP"
mofa_stub_handler /usr/bin/codesign t_fake_codesign
mofa_stub_passthrough /usr/bin/grep
mofa_capture AppSignatureProblem
mofa_assert_status 1 "a valid Microsoft signature is not a problem"
mofa_assert_called /usr/bin/codesign --verify --deep -vv "$T_APP"
mofa_assert_called /usr/bin/codesign -dv "$T_APP"
T_CODESIGN_ERROR="a sealed resource is missing or invalid"
mofa_capture AppSignatureProblem
mofa_assert_status 0 "a codesign failure is a problem"
mofa_assert_eq "$T_CODESIGN_ERROR" "$MOFA_STDOUT" "the codesign error is reported"
T_CODESIGN_ERROR=""
T_APP_TEAM="ABCDE12345"
mofa_capture AppSignatureProblem
mofa_assert_status 0 "another team's signature is a problem"
mofa_assert_contains "$MOFA_STDOUT" "not signed by Microsoft team UBF8T346G9" "the team mismatch is reported"

# --- Package download and verification ----------------------------------------------
mofa_case "DownloadAndVerifyPackage rejects a package from another team"
t_reset_globals
t_setup_download "$T_SIGNED_BY_OTHER"
mofa_run DownloadAndVerifyPackage
mofa_assert_status 1 "a team ID mismatch exits 1"
mofa_assert_contains "$MOFA_STDERR" "not signed by Microsoft" "the mismatch is logged"
mofa_assert_called /usr/bin/mktemp -d /private/var/tmp/mofa_reset.XXXXXX
mofa_assert_called /usr/bin/curl -fsSL --retry 3 --connect-timeout 30 --max-time 3600 -o "$T_WORK/package.pkg" -- "$T_MAU_URL"
mofa_assert_called /usr/sbin/pkgutil --check-signature "$T_WORK/package.pkg"
mofa_assert_not_called /usr/sbin/spctl "Gatekeeper is not consulted after a signer mismatch"
mofa_assert_not_called /usr/sbin/installer "nothing is installed"

mofa_case "DownloadAndVerifyPackage requires Gatekeeper and a non-empty download"
t_reset_globals
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_run DownloadAndVerifyPackage
mofa_assert_status 0 "a Microsoft-signed package passes"
mofa_assert_contains "$MOFA_STDOUT" "Downloaded package is signed by Microsoft" "the verification is logged"
mofa_assert_not_contains "$MOFA_STDOUT" "Warning: macOS is older" "no warning on a supported macOS"
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

mofa_case "DownloadAndVerifyPackage stops without a private temporary folder and warns on old macOS"
t_reset_globals
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_stub /usr/bin/mktemp 1
mofa_run DownloadAndVerifyPackage
mofa_assert_status 1 "a mktemp failure exits 1"
mofa_assert_contains "$MOFA_STDERR" "unable to create a temporary folder" "the mktemp failure is logged"
mofa_assert_not_called /usr/bin/curl "nothing is downloaded without a private folder"
mofa_stub /usr/bin/mktemp 0 "$T_WORK"
mofa_stub /usr/bin/sw_vers 0 "11.7.10"
mofa_run DownloadAndVerifyPackage
mofa_assert_status 0 "an old macOS only warns"
mofa_assert_contains "$MOFA_STDOUT" "Warning: macOS is older than 12.0" "the old macOS warning is logged"

mofa_case "RepairApp keeps the installed app when the download fails"
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
mofa_assert_status 0 "RepairApp replace returns 0 after a successful install"
mofa_assert_called /bin/rm -rf -- "$T_APP"
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
mofa_assert_status 0 "RepairApp returns 0 after a successful install"
mofa_assert_not_called /bin/rm "the installed app is kept"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /

# --- End-to-end flows with every command stubbed --------------------------------------
mofa_case "main reset flow stops MAU, removes its data, rewrites preferences and cleans up last"
t_reset_globals
t_setup_main
mofa_run t_main_flow / computer alice reset
mofa_assert_status 0 "reset flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Running as: alice; Home Folder: ${T_HOME}; Temp Folder: ${T_USER_TMP%/}; Mode: reset" "run context is logged"
mofa_assert_eq 6 "$(mofa_call_count /usr/bin/pkill)" "six MAU processes are stopped"
mofa_assert_called /usr/bin/pkill -9 "Microsoft AutoUpdate"
mofa_assert_called /usr/bin/pkill -9 "Microsoft AU Daemon"
mofa_assert_called /usr/bin/pkill -9 -f com.microsoft.autoupdate.bootstrapper.helper
mofa_assert_called /bin/rm -f -- "$T_HOME/Library/Preferences/com.microsoft.autoupdate2.plist"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Caches/com.microsoft.autoupdate2"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Application Support/Microsoft AU Daemon"
mofa_assert_called_before /usr/bin/pkill /bin/rm "MAU is stopped before its data is removed"
mofa_assert_called /usr/bin/killall cfprefsd
mofa_assert_called_before /usr/bin/killall /usr/bin/defaults "cfprefsd is flushed before preferences are rewritten"
mofa_assert_called /usr/bin/defaults write "$T_MAU_PREFS" AcknowledgedDataCollectionPolicy -string RequiredDataOnly
mofa_assert_called /usr/bin/defaults read "$T_APP/Contents/Info.plist" CFBundleVersion
mofa_assert_called /usr/bin/defaults write "$T_MAU_PREFS" Applications -dict-add "$T_APP" "{ 'Application ID' = 'MSau04'; 'App Domain' = 'com.microsoft.office' ; }"
mofa_assert_contains "$MOFA_STDOUT" "Codesign passed successfully" "the installed MAU is checked"
mofa_assert_not_called /usr/bin/curl "reset mode downloads nothing"
mofa_assert_not_called /usr/sbin/installer "reset mode installs nothing"
mofa_assert_eq "" "$(t_rm_calls_for_app)" "reset mode keeps the app bundle"
t_calls=("${(@f)$(mofa_calls)}")
mofa_assert_eq "t_cleanup_probe" "${t_calls[-1]}" "the EXIT trap cleans up after main finishes, not before"
mofa_assert_eq 1 "$(mofa_call_count t_cleanup_probe)" "the EXIT trap runs once"

if [[ "$MOFA_TEST_ROOT" == /private/var/folders/?* ]]; then
	mofa_case "main reset flow cleans MAU files from the console user's temp folder"
	t_reset_globals
	t_setup_main
	T_USER_TMP="$T_DIR/T/"
	mofa_mkdir "$T_DIR/T/MSauClones"
	mofa_write_file "$T_DIR/T/TelemetryUploadFilecom.microsoft.autoupdate2.txt" "x"
	mofa_run t_main_flow / computer alice reset
	mofa_assert_status 0 "reset flow exits 0"
	mofa_assert_called /bin/rm -rf -- "$T_DIR/T/MSauClones"
	mofa_assert_called /bin/rm -f -- "$T_DIR/T/TelemetryUploadFilecom.microsoft.autoupdate2.txt"
fi

mofa_case "main without a console user leaves user data alone"
t_reset_globals
t_setup_main
mofa_stub /usr/sbin/scutil 0 "  Name : loginwindow"
mofa_run t_main_flow / computer alice reset
mofa_assert_status 0 "reset flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Running as: <none>; Home Folder: /var/empty; Temp Folder: /var/empty; Mode: reset" "no user context is logged"
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "$T_HOME" "the sandbox user's data is not touched"
mofa_assert_not_contains "$(mofa_calls /bin/launchctl)" "asuser" "nothing runs as a user"

mofa_case "main reset flow reports an old or damaged MAU without reinstalling"
t_reset_globals
t_setup_main
T_APP_VERSION="4.50.23020000"
T_CODESIGN_ERROR="a sealed resource is missing or invalid"
mofa_run t_main_flow / computer alice reset
mofa_assert_status 0 "reset flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "older than the recommended version 4.83.26040910. Reset mode will not reinstall automatically" "the old version is reported"
mofa_assert_contains "$MOFA_STDOUT" "app bundle is damaged. Reset mode will not reinstall automatically" "the damage is reported"
mofa_assert_not_called /usr/bin/curl "reset mode downloads nothing"
mofa_assert_not_called /usr/sbin/installer "reset mode installs nothing"
mofa_assert_eq "" "$(t_rm_calls_for_app)" "reset mode keeps the app bundle"

mofa_case "main repair flow updates an old MAU in place"
t_reset_globals
t_setup_main
t_setup_download "$T_SIGNED_BY_MICROSOFT"
T_APP_VERSION="4.50.23020000"
mofa_run t_main_flow / computer alice repair
mofa_assert_status 0 "repair flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Reinstall mode enabled, updating it now" "the update is logged"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /
mofa_assert_eq "" "$(t_rm_calls_for_app)" "an old but intact app is installed over, not removed"
mofa_assert_contains "$MOFA_STDOUT" "Codesign passed successfully" "the signature is checked after the update"
t_calls=("${(@f)$(mofa_calls)}")
mofa_assert_eq "t_cleanup_probe" "${t_calls[-1]}" "the EXIT trap runs last"

mofa_case "main repair flow replaces a damaged MAU after verifying the package"
t_reset_globals
t_setup_main
t_setup_download "$T_SIGNED_BY_MICROSOFT"
T_CODESIGN_ERROR="a sealed resource is missing or invalid"
mofa_run t_main_flow / computer alice repair
mofa_assert_status 0 "repair flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "app bundle is damaged and will be reinstalled" "the replacement is logged"
mofa_assert_called /bin/rm -rf -- "$T_APP"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /
mofa_assert_called_before /usr/sbin/spctl /usr/sbin/installer "the package is verified before installing"

mofa_case "main repair flow installs a missing MAU; reset mode does not"
t_reset_globals
t_setup_main
t_setup_download "$T_SIGNED_BY_MICROSOFT"
APP_PATH="$T_DIR/MAU2.0/missing/Microsoft AutoUpdate.app"
mofa_run t_main_flow / computer alice reset
mofa_assert_status 0 "reset flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "was not found in the default location" "the missing app is reported"
mofa_assert_not_called /usr/bin/curl "reset mode does not install a missing app"
mofa_reset_calls
mofa_run t_main_flow / computer alice reinstall
mofa_assert_status 0 "reinstall flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Reinstall mode enabled, installing Microsoft AutoUpdate" "the install is logged"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /

mofa_case "main force flow exits 1 and keeps the app when the download fails"
t_reset_globals
t_setup_main
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_stub /usr/bin/curl 22
mofa_run t_main_flow / computer alice force
mofa_assert_status 1 "a failed download exits 1"
mofa_assert_contains "$MOFA_STDERR" "Package download failed" "the failure is logged"
mofa_assert_eq "" "$(t_rm_calls_for_app)" "the app bundle is not removed"
mofa_assert_not_called /usr/sbin/installer "nothing is installed"
mofa_assert_not_contains "$MOFA_STDOUT" "Creating new preferences" "the run stops at the failure"
mofa_assert_called_before /usr/bin/curl t_cleanup_probe "the EXIT trap cleans up after a failure exit"

mofa_case "main force flow reinstalls MAU and registers it"
t_reset_globals
t_setup_main
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_run t_main_flow / computer alice force
mofa_assert_status 0 "a successful reinstall exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Force mode enabled, reinstalling Microsoft AutoUpdate" "force mode is logged"
mofa_assert_called /bin/rm -rf -- "$T_APP"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/package.pkg" -target /
mofa_assert_called_before /usr/sbin/installer t_cleanup_probe "cleanup runs after the install"
mofa_assert_not_called /usr/bin/codesign "force mode does not re-check the signature"
mofa_assert_called /usr/bin/defaults write "$T_MAU_PREFS" Applications -dict-add "$T_APP" "{ 'Application ID' = 'MSau04'; 'App Domain' = 'com.microsoft.office' ; }"

mofa_case "main reset flow exits 1 when a removal fails"
t_reset_globals
t_setup_main
mofa_stub /bin/rm 1
mofa_run t_main_flow / computer alice reset
mofa_assert_status 1 "a removal failure is reported to Jamf"
mofa_assert_contains "$MOFA_STDERR" "removal failure(s)" "the failure count is logged"
mofa_assert_contains "$MOFA_STDOUT" "Restarting update services" "the run still finishes before reporting"

mofa_finish
