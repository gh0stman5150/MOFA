#!/bin/zsh --no-rcs
# Tests for office_reset_tools/mofa_community_maintained/scripts/MOFA_Community_Microsoft_Outlook_Data_Removal.zsh.
# Run as an unprivileged user: zsh tests/reset_scripts/test_Outlook_Data_Removal.zsh (or run_all.zsh).
# Every system command is a recording stub (see harness.zsh); nothing outside the sandbox changes.
# The only real command is ln -s, confined to the sandbox by the t_sandbox_symlink helper below.

source "${0:A:h}/harness.zsh"

mofa_source_script MOFA_Community_Microsoft_Outlook_Data_Removal.zsh
mofa_assert_source_clean

integer T_CASE=0

# --- Test helpers (t_ prefix: never clash with script functions) ---------------------
t_reset_globals() { # fresh script globals and per-case fixture paths inside the sandbox
	(( T_CASE++ ))
	T_DIR="$MOFA_TEST_ROOT/case${T_CASE}"
	T_HOME="$T_DIR/home/alice"
	T_OFFICE="$T_HOME/Library/Group Containers/UBF8T346G9.Office"
	T_PREFS_PLIST="$T_HOME/Library/Preferences/com.microsoft.Outlook.plist"
	T_PROFILE_PLIST="$T_OFFICE/OutlookProfile.plist"
	T_DATA_STORE="$T_OFFICE/Outlook"
	mofa_mkdir "$T_DIR"
	REMOVAL_FAILURES=0
	LoggedInUser=""
	LoggedInUserID=""
}

t_fmt() { # formats argv the way the call log does
	print -r -- "${(j: :)${(q+)@}}"
}

t_make_outlook_data() { # the three Outlook targets plus shared Office data that must be kept
	mofa_write_file "$T_PREFS_PLIST" "prefs"
	mofa_write_file "$T_PROFILE_PLIST" "profile"
	mofa_write_file "$T_DATA_STORE/Main Profile/Data/Outlook.sqlite" "mail"
	mofa_write_file "$T_OFFICE/MicrosoftRegistrationDB.reg" "shared"
	mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.Word.plist" "word"
}

t_sandbox_symlink() { # $1: target, $2: link; both inside the sandbox
	if [[ "${1:a}" != "$MOFA_TEST_ROOT"/?* || "${2:a}" != "$MOFA_TEST_ROOT"/?* ]]; then
		mofa_fail "t_sandbox_symlink refused a path outside the sandbox: $1 -> $2"
		return 1
	fi
	command /bin/ln -s -- "$1" "$2"
}

t_console_user() { # $1: the name scutil reports for the console session
	mofa_stub /usr/sbin/scutil 0 "<dictionary> {
  GID : 20
  Name : $1
  UID : 501
}"
	mofa_stub_passthrough /usr/bin/awk
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
	main "$@"
}

# Runs main as if root with the script's own SetHomeFolder. Only call through mofa_run.
t_main_flow_real_home() {
	RequireRoot() { :; }
	main "$@"
}

# --- Parameters and root check ------------------------------------------------------
mofa_case "main refuses to run without root"
t_reset_globals
mofa_run main / computer alice
mofa_assert_status 1 "main exits 1 when not root"
mofa_assert_contains "$MOFA_STDOUT" "Starting postinstall for Remove_Outlook_Data" "start banner precedes the root check"
mofa_assert_contains "$MOFA_STDERR" "must be run as root" "root check message"
mofa_assert_no_calls "nothing runs before the root check"

mofa_case "main has no custom parameters and ignores parameters 1-4"
t_reset_globals
t_make_outlook_data
t_console_user alice
# Parameter 3 names another user: the console session, not Jamf's parameter, picks the home.
mofa_run t_main_flow / computer mallory bogus
mofa_assert_status 0 "an unexpected parameter 4 does not change the run"
mofa_assert_contains "$MOFA_STDOUT" "Running as: alice; Home Folder: ${T_HOME}" "the console user is used, not Jamf parameter 3"
mofa_assert_called /bin/rm -rf -- "$T_DATA_STORE"
t_first_run_calls="$(mofa_calls)"
mofa_reset_calls
mofa_run t_main_flow bogus bogus bogus
mofa_assert_status 0 "parameters 1-3 are ignored"
mofa_assert_contains "$MOFA_STDOUT" "Running as: alice; Home Folder: ${T_HOME}" "bogus parameters 1-3 do not change the user"
mofa_assert_eq "$t_first_run_calls" "$(mofa_calls)" "parameters 1-4 do not change which commands run"

# --- Console user and home folder safety --------------------------------------------
mofa_case "GetLoggedInUser reports the console user and ignores loginwindow"
t_reset_globals
t_console_user alice
mofa_assert_eq "alice" "$(GetLoggedInUser)" "the console user name is read from scutil"
mofa_assert_called /usr/sbin/scutil
t_console_user loginwindow
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
mofa_stub /usr/bin/dscl 1
LoggedInUser="mofa_no_such_user_$$"
mofa_capture SetHomeFolder "mofa_no_such_user_$$"
mofa_assert_status 1 "SetHomeFolder returns 1 when the directory has no home and /Users/<name> is missing"
mofa_assert_eq "/var/empty" "$HOME" "HOME falls back to /var/empty without a directory record"

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
mofa_mkdir "$T_DATA_STORE"
mofa_capture removeTarget -rf "$T_DATA_STORE"
mofa_assert_status 0 "removeTarget succeeds"
mofa_assert_called /bin/rm -rf -- "$T_DATA_STORE"
mofa_assert_eq 1 "$(mofa_call_count /bin/rm)" "rm runs once"
mofa_assert_eq 0 "$REMOVAL_FAILURES" "no failure counted"
[[ -d "$T_DATA_STORE" ]] && mofa_pass "the stub did not delete anything" || mofa_fail "the stub did not delete anything"
mofa_reset_calls
mofa_write_file "$T_PREFS_PLIST" "x"
mofa_capture removeFileList "$T_PREFS_PLIST"
mofa_assert_eq "$(t_fmt /bin/rm -f -- "$T_PREFS_PLIST")" "$(mofa_calls /bin/rm)" "removeFileList uses rm -f"
mofa_reset_calls
mofa_capture removePathList "$T_DATA_STORE"
mofa_assert_eq "$(t_fmt /bin/rm -rf -- "$T_DATA_STORE")" "$(mofa_calls /bin/rm)" "removePathList uses rm -rf"

mofa_case "removeTarget removes a symlink without following it"
t_reset_globals
mofa_mkdir "$T_OFFICE"
t_sandbox_symlink "$T_DIR/elsewhere" "$T_DATA_STORE" || mofa_fail "sandbox symlink fixture"
mofa_capture removeTarget -rf "$T_DATA_STORE"
mofa_assert_status 0 "a dangling symlink is removed"
mofa_assert_called /bin/rm -rf -- "$T_DATA_STORE"

mofa_case "removeTarget counts rm failures and skips missing paths"
t_reset_globals
mofa_write_file "$T_PREFS_PLIST" "x"
mofa_stub /bin/rm 1
mofa_capture removeTarget -f "$T_PREFS_PLIST"
mofa_assert_status 1 "a failed rm returns 1"
mofa_assert_eq 1 "$REMOVAL_FAILURES" "a failed rm is counted"
mofa_assert_contains "$MOFA_STDERR" "Failed to remove" "a failed rm is logged"
mofa_reset_calls
mofa_capture removeTarget -rf "$T_HOME/Library/Containers/missing"
mofa_assert_status 0 "a missing path is not an error"
mofa_assert_contains "$MOFA_STDOUT" "Skipping missing path" "a missing path is logged"
mofa_assert_not_called /bin/rm "rm does not run for a missing path"
mofa_assert_eq 1 "$REMOVAL_FAILURES" "a missing path is not counted as a failure"

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
mofa_case "main removes the console user's Outlook data after quitting Outlook"
t_reset_globals
t_make_outlook_data
t_console_user alice
mofa_run t_main_flow / computer alice
mofa_assert_status 0 "the removal exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Running as: alice; Home Folder: ${T_HOME}" "run context is logged"
mofa_assert_called /usr/bin/pkill -9 "Microsoft Outlook"
mofa_assert_eq "$(t_fmt /bin/rm -f -- "$T_PREFS_PLIST")"$'\n'"$(t_fmt /bin/rm -f -- "$T_PROFILE_PLIST")"$'\n'"$(t_fmt /bin/rm -rf -- "$T_DATA_STORE")" \
	"$(mofa_calls /bin/rm)" "exactly the Outlook preferences, profile list and data store are removed, in order"
mofa_assert_called_before /usr/sbin/scutil /usr/bin/pkill "the console user is identified before Outlook is quit"
mofa_assert_called_before /usr/bin/pkill /bin/rm "Outlook is stopped before its data is removed"
t_calls=("${(@f)$(mofa_calls)}")
mofa_assert_eq "$(t_fmt /bin/rm -rf -- "$T_DATA_STORE")" "${t_calls[-1]}" "the data store is the last thing touched"

mofa_case "main skips missing Outlook data without failing"
t_reset_globals
mofa_mkdir "$T_HOME"
t_console_user alice
mofa_run t_main_flow / computer alice
mofa_assert_status 0 "nothing to remove still exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Skipping missing path ${T_DATA_STORE}" "the missing data store is logged"
mofa_assert_called /usr/bin/pkill -9 "Microsoft Outlook"
mofa_assert_not_called /bin/rm "rm does not run for missing paths"

mofa_case "main exits 1 when a removal fails"
t_reset_globals
t_make_outlook_data
t_console_user alice
mofa_stub /bin/rm 1
mofa_run t_main_flow / computer alice
mofa_assert_status 1 "a removal failure is reported to Jamf"
mofa_assert_contains "$MOFA_STDERR" "Completed with 3 removal failure(s)" "every failed removal is counted"
mofa_assert_eq 3 "$(mofa_call_count /bin/rm)" "a failure does not stop the remaining removals"

mofa_case "main without a console user exits 0 before quitting Outlook or removing anything"
t_reset_globals
for reported in "" loginwindow; do
	mofa_reset_calls
	if [[ -n "$reported" ]]; then
		t_console_user "$reported"
	else
		mofa_stub /usr/sbin/scutil 0 ""
		mofa_stub_passthrough /usr/bin/awk
	fi
	mofa_run t_main_flow / computer alice
	mofa_assert_status 0 "console session '${reported}' exits 0"
	mofa_assert_contains "$MOFA_STDOUT" "No eligible console user with a home under /Users; skipping Outlook data removal" "console session '${reported}' logs the skip"
	mofa_assert_not_contains "$MOFA_STDOUT" "Running as:" "console session '${reported}' does not continue"
	mofa_assert_not_called /usr/bin/pkill "console session '${reported}' leaves Outlook running"
	mofa_assert_not_called /bin/rm "console session '${reported}' removes nothing"
done

mofa_case "main skips a console user whose home is outside /Users"
t_reset_globals
t_console_user mofatestuser
mofa_stub /usr/bin/dscl 0 "NFSHomeDirectory: /private/var/mofa_test_home"
mofa_run t_main_flow_real_home / computer alice
mofa_assert_status 0 "a refused home exits 0"
mofa_assert_contains "$MOFA_STDERR" "not under /Users" "the refused home is logged"
mofa_assert_contains "$MOFA_STDOUT" "skipping Outlook data removal" "the skip is logged"
mofa_assert_called /usr/bin/dscl . -read /Users/mofatestuser NFSHomeDirectory
mofa_assert_not_called /usr/bin/pkill "Outlook is left running"
mofa_assert_not_called /bin/rm "nothing is removed"

mofa_finish
