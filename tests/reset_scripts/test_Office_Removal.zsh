#!/bin/zsh --no-rcs
# Tests for office_reset_tools/mofa_community_maintained/scripts/MOFA_Community_Microsoft_Office_Removal.zsh.
# Run as an unprivileged user: zsh tests/reset_scripts/test_Office_Removal.zsh (or run_all.zsh).
# Every system command is a recording stub (see harness.zsh); nothing outside the sandbox changes.
# The script removes fixed system paths (/Applications, /Library, /var/root, /Users/Shared). The
# tests only look at those paths with [[ -e ]]: /bin/rm and /bin/launchctl are stubs, so a path that
# exists on this Mac produces a recorded call and nothing more. Exact rm assertions use sandbox
# fixtures under the console user's (sandbox) home, so results do not depend on what is installed.

source "${0:A:h}/harness.zsh"

mofa_source_script MOFA_Community_Microsoft_Office_Removal.zsh
mofa_assert_source_clean

integer T_CASE=0
integer T_FORGET_STATUS=0
typeset -a T_RECEIPTS

# --- Test helpers (t_ prefix: never clash with script functions) ---------------------
t_reset_globals() { # fresh script globals and per-case fixture paths inside the sandbox
	(( T_CASE++ ))
	T_DIR="$MOFA_TEST_ROOT/case${T_CASE}"
	T_HOME="$T_DIR/home/alice"
	T_LAUNCHD="$T_DIR/LaunchDaemons"
	mofa_mkdir "$T_DIR"
	REMOVAL_FAILURES=0
	LoggedInUser=""
	LoggedInUserID=""
	T_RECEIPTS=()
	T_FORGET_STATUS=0
}

t_fmt() { # prints the call-log line the harness records for this argv
	print -r -- "${(j: :)${(q+)@}}"
}

t_lines() { # $1: text; prints its non-empty lines, one per line
	local t_line
	for t_line in "${(@f)1}"; do
		[[ -n "$t_line" ]] && print -r -- "$t_line"
	done
	return 0
}

# Records every removeTarget call ("OPTION PATH") in $T_DIR/targets, then runs the real one.
# Only call inside mofa_run (it redefines removeTarget for that subshell).
t_spy_removals() {
	: >| "$T_DIR/targets"
	(( ${+functions[t_real_removeTarget]} )) || functions[t_real_removeTarget]="${functions[removeTarget]}"
	removeTarget() {
		print -r -- "$1 $2" >> "$T_DIR/targets"
		t_real_removeTarget "$@"
	}
}

t_recorded_targets() { # prints what t_spy_removals recorded (a function, so zsh -n never reads the file)
	local t_text=""
	[[ -f "$T_DIR/targets" ]] && t_text="$(<"$T_DIR/targets")"
	print -r -- "$t_text"
}

# Runs main as if root, with a sandbox home for console user "alice" (UID 501). Only call through mofa_run.
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
	t_spy_removals
	main "$@"
}

# Runs main as if root with the script's own SetHomeFolder. Only call through mofa_run.
t_main_flow_real_home() {
	RequireRoot() { :; }
	t_spy_removals
	main "$@"
}

t_fake_pkgutil() { # pkgutil --pkgs | pkgutil --forget ID
	case "$1" in
		--pkgs)
			(( ${#T_RECEIPTS} )) && print -rl -- "${T_RECEIPTS[@]}"
			return 0
			;;
		--forget) return $T_FORGET_STATUS ;;
	esac
	return 1
}

# Every removal main performs, in order, as "OPTION PATH". $1: the home folder main uses.
t_expected_targets() {
	local h="$1" t_item t_domain
	for t_item in \
		"/Applications/Microsoft Word.app" \
		"/Applications/Microsoft Excel.app" \
		"/Applications/Microsoft PowerPoint.app" \
		"/Applications/Microsoft Outlook.app" \
		"/Applications/Microsoft OneNote.app" \
		"/Applications/OneDrive.app" \
		"/Applications/Microsoft Teams.app" \
		"/Applications/Microsoft Teams (work or school).app" \
		"/Applications/Microsoft Teams classic.app" \
		"/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver" \
		"/Library/Application Support/Microsoft/MAU2.0" \
		"/Library/Application Support/Microsoft/MERP2.0" \
		"/Library/Application Support/Microsoft/Office365" \
		"$h/Library/Application Support/Microsoft" \
		"$h/Library/Application Scripts/com.microsoft.errorreporting" \
		"/Library/Logs/Microsoft"; do
		print -r -- "-rf $t_item"
	done
	for t_item in \
		"/Library/LaunchAgents/com.microsoft.update.agent.plist" \
		"/Library/LaunchAgents/com.microsoft.OneDriveStandaloneUpdater.plist" \
		"/Library/LaunchAgents/com.microsoft.SyncReporter.plist" \
		"/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist" \
		"/Library/LaunchDaemons/com.microsoft.office.licensingV2.helper.plist" \
		"/Library/LaunchDaemons/com.microsoft.OneDriveStandaloneUpdaterDaemon.plist" \
		"/Library/LaunchDaemons/com.microsoft.OneDriveUpdaterDaemon.plist" \
		"/Library/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist" \
		"/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper" \
		"/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helpertool" \
		"/Library/PrivilegedHelperTools/com.microsoft.office.licensingV2.helper"; do
		print -r -- "-f $t_item"
	done
	for t_item in "$h/Library/Preferences" "/Library/Preferences"; do
		for t_domain in autoupdate2 autoupdate.fba shared office Word Excel Powerpoint Outlook onenote.mac \
			OneDrive-mac OneDrive teams teams2; do
			print -r -- "-f ${t_item}/com.microsoft.${t_domain}.plist"
		done
	done
	for t_domain in shared office Word Excel Powerpoint Outlook onenote.mac OneDrive-mac OneDrive teams; do
		print -r -- "-f /Library/Managed Preferences/com.microsoft.${t_domain}.plist"
	done
	print -r -- "-f /var/root/Library/Preferences/com.microsoft.autoupdate2.plist"
	print -r -- "-f /var/root/Library/Preferences/com.microsoft.autoupdate.fba.plist"
	for t_item in \
		"$h/Library/Caches/com.microsoft.autoupdate2" \
		"$h/Library/Caches/com.microsoft.autoupdate.fba" \
		"$h/Library/Caches/Microsoft" \
		"$h/Library/Group Containers/UBF8T346G9.Office" \
		"$h/Library/Group Containers/UBF8T346G9.ms" \
		"$h/Library/Group Containers/UBF8T346G9.OfficeOsfWebHost" \
		"$h/Library/Group Containers/group.com.microsoft"; do
		print -r -- "-rf $t_item"
	done
	for t_item in \
		"/Library/Preferences/com.microsoft.office.licensingV2.backup" \
		"/Library/Preferences/com.microsoft.autoupdate2.plist" \
		"$h/Library/Cookies/com.microsoft.OneDrive.binarycookies" \
		"$h/Library/Cookies/com.microsoft.OneDriveUpdater.binarycookies" \
		"$h/Library/Cookies/com.microsoft.OneDriveStandaloneUpdater.binarycookies" \
		"$h/Library/Cookies/com.microsoft.teams.binarycookies" \
		"$h/Library/Cookies/com.microsoft.teams2.binarycookies"; do
		print -r -- "-f $t_item"
	done
	print -r -- "-rf /Users/Shared/OnDemandInstaller"
}

# Fails if any recorded rm call is not one of the documented removals. $1: the home folder main used.
t_assert_rm_only_documented() {
	local t_line t_entry
	local -a t_allowed t_unexpected
	for t_entry in "${(@f)$(t_expected_targets "$1")}"; do
		t_allowed+=("$(t_fmt /bin/rm "${t_entry%% *}" -- "${t_entry#* }")")
	done
	for t_line in "${(@f)$(t_lines "$(mofa_calls /bin/rm)")}"; do
		[[ -z "$t_line" ]] && continue
		(( ${t_allowed[(Ie)$t_line]} )) || t_unexpected+=("$t_line")
	done
	mofa_assert_eq "" "${(F)t_unexpected}" "rm only ever receives a documented target with its documented option"
}

t_sandbox_rm_calls() { # prints the recorded rm calls whose target is inside the sandbox
	local t_line
	for t_line in "${(@f)$(mofa_calls /bin/rm)}"; do
		[[ -n "$t_line" && "$t_line" == *"$MOFA_TEST_ROOT"* ]] && print -r -- "$t_line"
	done
	return 0
}

t_forget_calls() { # prints the recorded pkgutil --forget calls
	local t_line
	for t_line in "${(@f)$(mofa_calls /usr/sbin/pkgutil)}"; do
		[[ "$t_line" == *" --forget "* ]] && print -r -- "$t_line"
	done
	return 0
}

typeset -a T_LAUNCHD_ITEMS T_PKILL_TARGETS
T_LAUNCHD_ITEMS=(
	"gui /Library/LaunchAgents/com.microsoft.update.agent.plist"
	"gui /Library/LaunchAgents/com.microsoft.autoupdate.helper.plist"
	"gui /Library/LaunchAgents/com.microsoft.OneDriveStandaloneUpdater.plist"
	"gui /Library/LaunchAgents/com.microsoft.SyncReporter.plist"
	"system /Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist"
	"system /Library/LaunchDaemons/com.microsoft.office.licensingV2.helper.plist"
	"system /Library/LaunchDaemons/com.microsoft.OneDriveStandaloneUpdaterDaemon.plist"
	"system /Library/LaunchDaemons/com.microsoft.OneDriveUpdaterDaemon.plist"
	"system /Library/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist"
)
T_PKILL_TARGETS=(
	"Microsoft Word" "Microsoft Excel" "Microsoft PowerPoint" "Microsoft Outlook" "Microsoft OneNote"
	"OneDrive" "OneDrive Finder Integration" "OneDriveStandaloneUpdater" "OneDriveUpdater" "MSTeams"
	"Microsoft Teams" "Microsoft Teams Helper" "Microsoft AutoUpdate" "Microsoft Update Assistant"
	"Microsoft AU Daemon" "Microsoft AU Bootstrapper"
)

t_setup_user_fixtures() { # sandbox Office data for alice, plus files that must be kept
	mofa_mkdir "$T_HOME/Library/Application Support/Microsoft/Office"
	mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.Word.plist" "x"
	mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.teams2.plist" "x"
	mofa_write_file "$T_HOME/Library/Preferences/com.apple.finder.plist" "keep"
	mofa_mkdir "$T_HOME/Library/Group Containers/UBF8T346G9.Office/Outlook"
	mofa_mkdir "$T_HOME/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"
	mofa_write_file "$T_HOME/Library/Cookies/com.microsoft.OneDrive.binarycookies" "x"
	mofa_write_file "$T_HOME/Documents/Report.docx" "keep"
}

t_expected_sandbox_rm() { # the rm calls t_setup_user_fixtures should produce, in order
	t_fmt /bin/rm -rf -- "$T_HOME/Library/Application Support/Microsoft"
	t_fmt /bin/rm -f -- "$T_HOME/Library/Preferences/com.microsoft.Word.plist"
	t_fmt /bin/rm -f -- "$T_HOME/Library/Preferences/com.microsoft.teams2.plist"
	t_fmt /bin/rm -rf -- "$T_HOME/Library/Group Containers/UBF8T346G9.Office"
	t_fmt /bin/rm -f -- "$T_HOME/Library/Cookies/com.microsoft.OneDrive.binarycookies"
}

# --- Root check ---------------------------------------------------------------------
mofa_case "main refuses to run without root"
t_reset_globals
mofa_run main / computer alice
mofa_assert_status 1 "main exits 1 when not root"
mofa_assert_contains "$MOFA_STDOUT" "Starting postinstall for Remove_Office" "start banner precedes the root check"
mofa_assert_contains "$MOFA_STDERR" "must be run as root" "root check message"
mofa_assert_no_calls "nothing runs before the root check"

# --- Console user and home folder safety --------------------------------------------
mofa_case "GetLoggedInUser reads the console user and ignores loginwindow"
t_reset_globals
mofa_stub /usr/sbin/scutil 0 "  Name : alice"
mofa_stub_passthrough /usr/bin/awk
mofa_assert_eq "alice" "$(GetLoggedInUser)" "the console user name is read from scutil"
mofa_assert_called /usr/sbin/scutil
mofa_stub /usr/sbin/scutil 0 "  Name : loginwindow"
mofa_assert_eq "" "$(GetLoggedInUser)" "loginwindow is not a console user"

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
mofa_assert_eq "" "$LoggedInUserID" "no user ID is kept, so gui launchd items are skipped"
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

# The sandbox lives under TMPDIR (/var/folders), so T_HOME is an existing directory outside
# /Users: only the /Users prefix check, not the directory test, can refuse it.
mofa_case "SetHomeFolder refuses an existing home outside /Users"
t_reset_globals
if [[ "$T_HOME" != /Users/* ]]; then
	mofa_mkdir "$T_HOME/Library/Preferences"
	mofa_stub /usr/bin/dscl 0 "NFSHomeDirectory: ${T_HOME}"
	mofa_stub_passthrough /usr/bin/awk
	mofa_stub /usr/bin/id 0 "501"
	LoggedInUser=alice
	mofa_capture SetHomeFolder alice
	mofa_assert_status 1 "SetHomeFolder returns 1 for an existing directory outside /Users"
	mofa_assert_eq "/var/empty" "$HOME" "HOME falls back to /var/empty"
	mofa_assert_eq "" "$LoggedInUser" "the console user is cleared so user data is skipped"
	mofa_assert_eq "" "$LoggedInUserID" "no user ID is kept, so gui launchd items are skipped"
	mofa_assert_contains "$MOFA_STDERR" "Home folder for alice is not under /Users" "the refusal is logged"
	mofa_assert_not_called /usr/bin/id "no user ID is looked up for a refused home"
else
	print -r -- "# skip: the sandbox is under /Users (TMPDIR=${TMPDIR}), so it cannot stand in for a home outside /Users"
fi

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

	mofa_case "SetHomeFolder falls back to /Users/NAME when the directory has no home"
	t_reset_globals
	mofa_stub /usr/bin/dscl 1
	mofa_stub_passthrough /usr/bin/awk
	mofa_stub /usr/bin/id 0 "503"
	LoggedInUser=Shared
	mofa_capture SetHomeFolder Shared
	mofa_assert_status 0 "SetHomeFolder accepts the existing /Users/Shared"
	mofa_assert_eq "/Users/Shared" "$HOME" "HOME is /Users/NAME"
	mofa_assert_eq "503" "$LoggedInUserID" "the user ID comes from id -u"
fi

# --- Removal wrapper ----------------------------------------------------------------
mofa_case "removeTarget refuses empty, relative and root targets"
t_reset_globals
for bad in "" "relative/path" "." "Library/Preferences" "/"; do
	REMOVAL_FAILURES=0
	mofa_capture removeTarget -rf "$bad"
	mofa_assert_status 1 "removeTarget refuses '${bad}'"
	mofa_assert_eq 1 "$REMOVAL_FAILURES" "refusing '${bad}' counts as a removal failure"
	mofa_assert_contains "$MOFA_STDERR" "Refusing to remove unsafe path" "refusing '${bad}' is logged"
done
mofa_assert_not_called /bin/rm "rm never runs for an unsafe target"

mofa_case "removePathList and removeFileList call rm with the option, -- and the exact path"
t_reset_globals
target="$T_HOME/Library/Group Containers/UBF8T346G9.Office"
mofa_mkdir "$target"
mofa_capture removePathList "$target"
mofa_assert_status 0 "removePathList succeeds"
mofa_assert_called /bin/rm -rf -- "$target"
mofa_assert_eq 1 "$(mofa_call_count /bin/rm)" "rm runs once"
mofa_assert_eq 0 "$REMOVAL_FAILURES" "no failure counted"
[[ -d "$target" ]] && mofa_pass "the stub did not delete anything" || mofa_fail "the stub did not delete anything"
plist="$T_HOME/Library/Preferences/com.microsoft.Word.plist"
mofa_write_file "$plist" "x"
mofa_reset_calls
mofa_capture removeFileList "$plist"
mofa_assert_eq "$(t_fmt /bin/rm -f -- "$plist")" "$(mofa_calls /bin/rm)" "removeFileList uses rm -f"

mofa_case "removeTarget counts rm failures, keeps going and skips missing paths"
t_reset_globals
first="$T_HOME/Library/Preferences/com.microsoft.Word.plist"
second="$T_HOME/Library/Preferences/com.microsoft.Excel.plist"
mofa_write_file "$first" "x"
mofa_write_file "$second" "x"
mofa_stub /bin/rm 1
mofa_capture removeFileList "$first" "$second"
mofa_assert_eq 2 "$REMOVAL_FAILURES" "each failed rm is counted"
mofa_assert_eq 2 "$(mofa_call_count /bin/rm)" "a failed removal does not stop the next one"
mofa_assert_contains "$MOFA_STDERR" "Failed to remove ${first}" "a failed rm is logged"
mofa_reset_calls
REMOVAL_FAILURES=0
mofa_capture removeTarget -rf "$T_HOME/Library/Caches/missing"
mofa_assert_status 0 "a missing path is not an error"
mofa_assert_eq 0 "$REMOVAL_FAILURES" "a missing path is not counted"
mofa_assert_contains "$MOFA_STDOUT" "Skipping missing path" "a missing path is logged"
mofa_assert_not_called /bin/rm "rm does not run for a missing path"

# --- Package receipts ---------------------------------------------------------------
mofa_case "forgetReceiptList forgets only receipts that match exactly"
t_reset_globals
mofa_stub_handler /usr/sbin/pkgutil t_fake_pkgutil
mofa_stub_passthrough /usr/bin/grep
T_RECEIPTS=(com.apple.pkg.Core com.microsoft.Word com.microsoft.Excel.extra)
mofa_run forgetReceiptList com.microsoft.Word com.microsoft.Excel "com.microsoft.*"
mofa_assert_status 0 "forgetReceiptList succeeds"
mofa_assert_eq "$(t_fmt /usr/sbin/pkgutil --forget com.microsoft.Word)" "$(t_forget_calls)" "only the installed receipt is forgotten"
mofa_assert_called /usr/sbin/pkgutil --pkgs
mofa_assert_contains "$MOFA_STDOUT" "Skipping missing package receipt com.microsoft.Excel" "a prefix match is not a receipt"
mofa_assert_contains "$MOFA_STDOUT" 'Skipping missing package receipt com.microsoft.*' "a receipt ID is not a pattern"

mofa_case "forgetReceiptList ignores a failed pkgutil --forget"
t_reset_globals
mofa_stub_handler /usr/sbin/pkgutil t_fake_pkgutil
mofa_stub_passthrough /usr/bin/grep
T_RECEIPTS=(com.microsoft.Word)
T_FORGET_STATUS=1
mofa_run forgetReceiptList com.microsoft.Word
mofa_assert_status 0 "a failed forget does not fail the run"
mofa_assert_called /usr/sbin/pkgutil --forget com.microsoft.Word

# --- launchd jobs -------------------------------------------------------------------
mofa_case "bootoutJob skips a missing launchd item"
t_reset_globals
LoggedInUserID=501
mofa_run bootoutJob system "$T_LAUNCHD/com.microsoft.missing.plist"
mofa_assert_status 0 "a missing item is not an error"
mofa_assert_contains "$MOFA_STDOUT" "Skipping missing launchd item" "the missing item is logged"
mofa_assert_not_called /bin/launchctl

mofa_case "bootoutJob boots out gui items in the console user's domain, falling back to unload"
t_reset_globals
plist="$T_LAUNCHD/com.microsoft.update.agent.plist"
mofa_write_file "$plist" "plist"
LoggedInUserID=501
mofa_run bootoutJob gui "$plist"
mofa_assert_status 0 "bootoutJob gui succeeds"
mofa_assert_eq "$(t_fmt /bin/launchctl bootout gui/501 "$plist")" "$(mofa_calls /bin/launchctl)" "bootout runs in gui/UID only"
mofa_reset_calls
mofa_stub /bin/launchctl 5
mofa_run bootoutJob gui "$plist"
mofa_assert_status 0 "a failed bootout and unload are not fatal"
mofa_assert_called /bin/launchctl bootout gui/501 "$plist"
mofa_assert_called /bin/launchctl unload "$plist"

mofa_case "bootoutJob skips gui items without a console user"
t_reset_globals
plist="$T_LAUNCHD/com.microsoft.update.agent.plist"
mofa_write_file "$plist" "plist"
LoggedInUserID=""
mofa_run bootoutJob gui "$plist"
mofa_assert_status 0 "skipping is not an error"
mofa_assert_contains "$MOFA_STDOUT" "No logged-in user detected; skipping gui launchd item" "the skip is logged"
mofa_assert_not_called /bin/launchctl "nothing is booted out of an unknown gui domain"

mofa_case "bootoutJob boots out system items, falling back to unload"
t_reset_globals
plist="$T_LAUNCHD/com.microsoft.autoupdate.helper.plist"
mofa_write_file "$plist" "plist"
mofa_run bootoutJob system "$plist"
mofa_assert_eq "$(t_fmt /bin/launchctl bootout system "$plist")" "$(mofa_calls /bin/launchctl)" "bootout runs in the system domain"
mofa_reset_calls
mofa_stub /bin/launchctl 5
mofa_run bootoutJob system "$plist"
mofa_assert_status 0 "a failed bootout and unload are not fatal"
mofa_assert_called /bin/launchctl unload "$plist"

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

# --- End-to-end flow with every command stubbed ---------------------------------------
mofa_case "main stops Office, boots out its jobs, removes the documented paths and forgets receipts"
t_reset_globals
t_setup_user_fixtures
mofa_stub /usr/sbin/scutil 0 "  Name : alice"
mofa_stub_passthrough /usr/bin/awk
mofa_stub_passthrough /usr/bin/grep
mofa_stub_handler /usr/sbin/pkgutil t_fake_pkgutil
T_RECEIPTS=(com.apple.pkg.Core com.microsoft.Word com.microsoft.Word.extra com.microsoft.package.Frameworks com.microsoft.teams2)
mofa_run t_main_flow / computer alice
mofa_assert_status 0 "the removal flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Starting postinstall for Remove_Office" "the start banner is logged"
mofa_assert_contains "$MOFA_STDOUT" "Running as: alice; Home Folder: ${T_HOME}" "run context is logged"
# Processes: every documented process is killed, in order, before anything is removed.
t_expected=()
for target in "${T_PKILL_TARGETS[@]}"; do
	t_expected+=("$(t_fmt /usr/bin/pkill -9 "$target")")
done
t_expected+=("$(t_fmt /usr/bin/pkill -9 -f com.microsoft.autoupdate.helper)")
t_expected+=("$(t_fmt /usr/bin/pkill -9 -f com.microsoft.autoupdate.bootstrapper.helper)")
mofa_assert_eq "${(F)t_expected}" "$(mofa_calls /usr/bin/pkill)" "every Office, OneDrive, Teams and AutoUpdate process is stopped"
mofa_assert_called_before /usr/bin/pkill /bin/rm "processes are stopped before data is removed"
# launchd: items present on this Mac are booted out (stubbed); missing ones are logged and skipped.
for t_entry in "${T_LAUNCHD_ITEMS[@]}"; do
	t_domain="${t_entry%% *}"
	plist="${t_entry#* }"
	if [[ -e "$plist" ]]; then
		if [[ "$t_domain" == gui ]]; then
			mofa_assert_called /bin/launchctl bootout gui/501 "$plist"
		else
			mofa_assert_called /bin/launchctl bootout system "$plist"
		fi
	else
		mofa_assert_contains "$MOFA_STDOUT" "Skipping missing launchd item ${plist}" "missing launchd item ${plist:t} is skipped"
	fi
done
t_allowed=()
for t_entry in "${T_LAUNCHD_ITEMS[@]}"; do
	t_domain="${t_entry%% *}"
	[[ "$t_domain" == gui ]] && t_domain=gui/501
	t_allowed+=("$(t_fmt /bin/launchctl bootout "$t_domain" "${t_entry#* }")")
done
t_unexpected=()
for t_line in "${(@f)$(t_lines "$(mofa_calls /bin/launchctl)")}"; do
	[[ -z "$t_line" ]] && continue
	(( ${t_allowed[(Ie)$t_line]} )) || t_unexpected+=("$t_line")
done
mofa_assert_eq "" "${(F)t_unexpected}" "launchctl only boots out the documented jobs"
# Removal scope: the exact ordered target list, and rm only ever sees those targets.
mofa_assert_eq "$(t_expected_targets "$T_HOME")" "$(t_recorded_targets)" "main removes exactly the documented targets, in order"
t_assert_rm_only_documented "$T_HOME"
mofa_assert_eq "$(t_expected_sandbox_rm)" "$(t_sandbox_rm_calls)" "the console user's Office data is removed with the documented options"
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "com.apple.finder.plist" "other preferences are kept"
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "UBF8T346G9.OneDriveStandaloneSuite" "other group containers are kept"
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "Documents" "documents are kept"
# Receipts: only installed receipts are forgotten, after the apps are removed.
t_expected=(
	"$(t_fmt /usr/sbin/pkgutil --forget com.microsoft.Word)"
	"$(t_fmt /usr/sbin/pkgutil --forget com.microsoft.package.Frameworks)"
	"$(t_fmt /usr/sbin/pkgutil --forget com.microsoft.teams2)"
)
mofa_assert_eq "${(F)t_expected}" "$(t_forget_calls)" "only installed Microsoft receipts are forgotten, in order"
t_pkgs_checks=0
for t_line in "${(@f)$(mofa_calls /usr/sbin/pkgutil)}"; do
	[[ "$t_line" == "/usr/sbin/pkgutil --pkgs" ]] && (( t_pkgs_checks++ ))
done
mofa_assert_eq 24 "$t_pkgs_checks" "each of the 24 documented receipts is looked up"
mofa_assert_eq 27 "$(mofa_call_count /usr/sbin/pkgutil)" "24 lookups and 3 forgets, nothing else"
mofa_assert_called_before /bin/rm /usr/sbin/pkgutil "receipts are forgotten after the apps are removed"
# Section order matches the script.
t_out="$MOFA_STDOUT"
t_a="${t_out%%Office-Reset: Stopping services*}"
t_b="${t_out%%Office-Reset: Removing apps*}"
t_c="${t_out%%Office-Reset: Removing app data*}"
t_d="${t_out%%Office-Reset: Removing package receipts*}"
if (( ${#t_a} < ${#t_b} && ${#t_b} < ${#t_c} && ${#t_c} < ${#t_d} && ${#t_d} < ${#t_out} )); then
	mofa_pass "sections run in order: services, apps, app data, receipts"
else
	mofa_fail "sections run in order: services, apps, app data, receipts" "$t_out"
fi
mofa_assert_not_called /usr/bin/dscl "the test's SetHomeFolder was used"

mofa_case "main reports removal failures to Jamf and still finishes every step"
t_reset_globals
t_setup_user_fixtures
mofa_stub /usr/sbin/scutil 0 "  Name : alice"
mofa_stub_passthrough /usr/bin/awk
mofa_stub_passthrough /usr/bin/grep
mofa_stub_handler /usr/sbin/pkgutil t_fake_pkgutil
mofa_stub /bin/rm 1
T_RECEIPTS=(com.microsoft.Word)
mofa_run t_main_flow / computer alice
mofa_assert_status 1 "a removal failure exits 1"
mofa_assert_contains "$MOFA_STDERR" "removal failure(s)" "the failure count is logged"
mofa_assert_contains "$MOFA_STDERR" "Failed to remove ${T_HOME}/Library/Preferences/com.microsoft.Word.plist" "the failed path is logged"
mofa_assert_eq "$(t_expected_sandbox_rm)" "$(t_sandbox_rm_calls)" "every later removal is still attempted"
mofa_assert_eq "$(t_expected_targets "$T_HOME")" "$(t_recorded_targets)" "every documented target is still processed"
mofa_assert_called /usr/sbin/pkgutil --forget com.microsoft.Word

mofa_case "main without a console user removes no user data and skips gui launchd items"
t_reset_globals
mofa_stub /usr/sbin/scutil 0 "  Name : loginwindow"
mofa_stub_passthrough /usr/bin/awk
mofa_stub_passthrough /usr/bin/grep
mofa_stub_handler /usr/sbin/pkgutil t_fake_pkgutil
mofa_run t_main_flow_real_home / computer alice ignored-parameter-4
mofa_assert_status 0 "the flow exits 0 (and ignores Jamf parameters)"
mofa_assert_contains "$MOFA_STDOUT" "Running as: <none>; Home Folder: /var/empty" "no user is logged"
mofa_assert_not_called /usr/bin/dscl "no directory lookup without a console user"
mofa_assert_not_called /usr/bin/id "no user ID without a console user"
mofa_assert_eq "$(t_expected_targets /var/empty)" "$(t_recorded_targets)" "user paths resolve under /var/empty"
mofa_assert_not_contains "$(mofa_calls /bin/launchctl)" "gui/" "no gui domain is touched"
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "/var/empty" "nothing under /var/empty is removed"
t_assert_rm_only_documented /var/empty

mofa_case "main with a console user whose home is outside /Users removes no user data"
t_reset_globals
mofa_stub /usr/sbin/scutil 0 "  Name : alice"
mofa_stub /usr/bin/dscl 0 "NFSHomeDirectory: /private/var/mofa_test_home"
mofa_stub_passthrough /usr/bin/awk
mofa_stub_passthrough /usr/bin/grep
mofa_stub_handler /usr/sbin/pkgutil t_fake_pkgutil
mofa_run t_main_flow_real_home / computer alice
mofa_assert_status 0 "the flow continues without user data"
mofa_assert_contains "$MOFA_STDERR" "Home folder for alice is not under /Users" "the refused home is logged"
mofa_assert_contains "$MOFA_STDOUT" "Running as: <none>; Home Folder: /var/empty" "the user is dropped"
mofa_assert_eq "$(t_expected_targets /var/empty)" "$(t_recorded_targets)" "user paths resolve under /var/empty"
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "/private/var/mofa_test_home" "the refused home is never removed from"
mofa_assert_not_contains "$(mofa_calls /bin/launchctl)" "gui/" "no gui domain is touched"
mofa_assert_not_called /usr/bin/id "no user ID for a refused home"

mofa_case "main never removes Office data from an existing home outside /Users"
t_reset_globals
if [[ "$T_HOME" != /Users/* ]]; then
	t_setup_user_fixtures
	mofa_stub /usr/sbin/scutil 0 "  Name : alice"
	mofa_stub /usr/bin/dscl 0 "NFSHomeDirectory: ${T_HOME}"
	mofa_stub /usr/bin/id 0 "501"
	mofa_stub_passthrough /usr/bin/awk
	mofa_stub_passthrough /usr/bin/grep
	mofa_stub_handler /usr/sbin/pkgutil t_fake_pkgutil
	mofa_run t_main_flow_real_home / computer alice
	mofa_assert_status 0 "the flow continues without user data"
	mofa_assert_contains "$MOFA_STDERR" "Home folder for alice is not under /Users" "the refused home is logged"
	mofa_assert_contains "$MOFA_STDOUT" "Running as: <none>; Home Folder: /var/empty" "the user is dropped"
	mofa_assert_eq "$(t_expected_targets /var/empty)" "$(t_recorded_targets)" "user paths resolve under /var/empty"
	mofa_assert_eq "" "$(t_sandbox_rm_calls)" "no Office data in the refused home is removed"
	mofa_assert_not_contains "$(mofa_calls /bin/launchctl)" "gui/" "no gui domain is touched"
	mofa_assert_not_called /usr/bin/id "no user ID for a refused home"
	t_assert_rm_only_documented /var/empty
else
	print -r -- "# skip: the sandbox is under /Users (TMPDIR=${TMPDIR}), so it cannot stand in for a home outside /Users"
fi

mofa_finish
