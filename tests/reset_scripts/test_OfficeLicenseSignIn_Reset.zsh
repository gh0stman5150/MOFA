#!/bin/zsh --no-rcs
# Tests for office_reset_tools/mofa_community_maintained/scripts/MOFA_Community_Microsoft_OfficeLicenseSignIn_Reset.zsh.
# Run as an unprivileged user: zsh tests/reset_scripts/test_OfficeLicenseSignIn_Reset.zsh (or run_all.zsh).
# Every system command is a recording stub (see harness.zsh); nothing outside the sandbox changes.
# The only real commands are a read-only find and ln -s, both confined to the sandbox by the
# t_sandbox_find and t_sandbox_symlink helpers below.

source "${0:A:h}/harness.zsh"

mofa_source_script MOFA_Community_Microsoft_OfficeLicenseSignIn_Reset.zsh
mofa_assert_source_clean

integer T_CASE=0
T_ONEAUTH_SQL="DELETE FROM genp WHERE agrp='UBF8T346G9.com.microsoft.identity.universalstorage'; SELECT changes();"
T_AS_ALICE=(/bin/launchctl asuser 501 /usr/bin/sudo -H -u alice)

# --- Test helpers (t_ prefix: never clash with script functions) ---------------------
t_reset_globals() { # fresh script globals and per-case fixture paths inside the sandbox
	(( T_CASE++ ))
	T_DIR="$MOFA_TEST_ROOT/case${T_CASE}"
	T_HOME="$T_DIR/home/alice"
	T_KEYCHAINS="$T_HOME/Library/Keychains"
	T_OFFICE="$T_HOME/Library/Group Containers/UBF8T346G9.Office"
	mofa_mkdir "$T_DIR"
	REMOVAL_FAILURES=0
	LoggedInUser=""
	LoggedInUserID=""
	T_KEYCHAIN_ITEMS=0
	T_SEARCH_LIST=""
	T_DB_LOCKED=""
}

t_fmt() { # formats argv the way the call log does
	print -r -- "${(j: :)${(q+)@}}"
}

t_count_calls_matching() { # $1: glob pattern; prints how many call log lines match
	local -a lines matching
	lines=("${(@f)$(mofa_calls)}")
	matching=(${(M)lines:#$~1})
	print -r -- "${#matching}"
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

t_fake_launchctl() { # launchctl asuser UID /usr/bin/sudo -H -u USER CMD...
	local -a cmd
	cmd=("${@[7,-1]}")
	case "${cmd[1]}:${cmd[2]:-}" in
		/usr/bin/security:list-keychains)
			# Only the read form (list-keychains -d user) prints the search list.
			(( ${#cmd} == 4 )) && print -r -- "$T_SEARCH_LIST"
			;;
		/usr/bin/security:find-generic-password)
			(( T_KEYCHAIN_ITEMS > 0 )) || return 44
			;;
		/usr/bin/security:delete-generic-password)
			(( T_KEYCHAIN_ITEMS > 0 )) && (( T_KEYCHAIN_ITEMS-- ))
			;;
	esac
	return 0
}

t_fake_delete_fails() { # find-generic-password succeeds, delete-generic-password fails
	[[ "$8" == delete-generic-password ]] && return 1
	return 0
}

t_fake_sqlite3() { # sqlite3 -cmd ".timeout N" DB SQL; T_DB_LOCKED fails like a busy database
	if [[ "$3" == "$T_DB_LOCKED" ]]; then
		print -r -- "Error: database is locked"
		return 5
	fi
	print -r -- "1"
}

# Runs the real find, which only reads, but only below the sandbox and never with an action
# primary, so the script's own find arguments can be checked against real find semantics.
t_sandbox_find() {
	local arg
	if [[ "${1:a}" != "$MOFA_TEST_ROOT"/?* ]]; then
		mofa_fail "t_sandbox_find refused a start path outside the sandbox: $1"
		return 1
	fi
	for arg in "${@[2,-1]}"; do
		case "$arg" in
			-delete|-exec|-execdir|-ok|-okdir|-fprint*|-fls|-L|-H|-follow)
				mofa_fail "t_sandbox_find refused find primary: $arg"
				return 1
				;;
		esac
	done
	command /usr/bin/find "$@"
}

t_sandbox_symlink() { # $1: target, $2: link; both inside the sandbox
	if [[ "${1:a}" != "$MOFA_TEST_ROOT"/?* || "${2:a}" != "$MOFA_TEST_ROOT"/?* ]]; then
		mofa_fail "t_sandbox_symlink refused a path outside the sandbox: $1 -> $2"
		return 1
	fi
	command /bin/ln -s -- "$1" "$2"
}

t_setup_console_user() { # scutil reports alice; user-context commands go to t_fake_launchctl
	mofa_stub /usr/sbin/scutil 0 "  Name : alice"
	mofa_stub_passthrough /usr/bin/awk
	mofa_stub_passthrough /usr/bin/sed
	mofa_stub_handler /bin/launchctl t_fake_launchctl
}

# --- Parameters and root check ------------------------------------------------------
mofa_case "main refuses to run without root"
t_reset_globals
mofa_run main / computer alice
mofa_assert_status 1 "main exits 1 when not root"
mofa_assert_contains "$MOFA_STDOUT" "Starting postinstall for Reset_OfficeLicenseSignIn" "start banner precedes the root check"
mofa_assert_contains "$MOFA_STDERR" "must be run as root" "root check message"
mofa_assert_no_calls "nothing runs before the root check"

mofa_case "main has no custom parameters and ignores parameter 4"
t_reset_globals
mofa_stub /usr/sbin/scutil 0 ""
mofa_stub_passthrough /usr/bin/awk
mofa_run t_main_flow / computer alice bogus
mofa_assert_status 0 "an unexpected parameter 4 does not change the run"
mofa_assert_contains "$MOFA_STDOUT" "Running as: <none>; Home Folder: /var/empty" "the run continues without a console user"

# --- Home folder safety -------------------------------------------------------------
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

mofa_case "runAsUser without a console user runs nothing"
t_reset_globals
mofa_capture runAsUser /usr/bin/security list-keychains -d user
mofa_assert_status 1 "runAsUser returns 1"
mofa_assert_contains "$MOFA_STDERR" "No logged-in user detected" "the skip is logged"
mofa_assert_no_calls "no user-context command runs"

# --- Removal wrappers ---------------------------------------------------------------
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
target="$T_HOME/Library/Group Containers/UBF8T346G9.com.microsoft.oneauth"
mofa_mkdir "$target"
mofa_capture removeTarget -rf "$target"
mofa_assert_status 0 "removeTarget succeeds"
mofa_assert_called /bin/rm -rf -- "$target"
mofa_assert_eq 1 "$(mofa_call_count /bin/rm)" "rm runs once"
mofa_assert_eq 0 "$REMOVAL_FAILURES" "no failure counted"
[[ -d "$target" ]] && mofa_pass "the stub did not delete anything" || mofa_fail "the stub did not delete anything"
plist="$T_HOME/Library/Preferences/com.microsoft.msa-login-hint.plist"
mofa_write_file "$plist" "x"
mofa_capture removeFileList "$plist"
mofa_assert_called /bin/rm -f -- "$plist"

mofa_case "removeTarget counts rm failures and skips missing paths"
t_reset_globals
plist="$T_OFFICE/DRM_Evo.plist"
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

mofa_case "MoveIfPresent moves an existing file, counts a failed move and skips a missing one"
t_reset_globals
source_plist="$T_OFFICE/com.microsoft.Office365V2.plist"
backup_plist="$T_OFFICE/com.microsoft.Office365V2.backup"
mofa_write_file "$source_plist" "x"
mofa_capture MoveIfPresent "$source_plist" "$backup_plist"
mofa_assert_called /bin/mv -f -- "$source_plist" "$backup_plist"
mofa_assert_eq 0 "$REMOVAL_FAILURES" "a successful move counts no failure"
mofa_stub /bin/mv 1
mofa_capture MoveIfPresent "$source_plist" "$backup_plist"
mofa_assert_eq 1 "$REMOVAL_FAILURES" "a failed move is counted"
mofa_assert_contains "$MOFA_STDERR" "Failed to move" "a failed move is logged"
mofa_reset_calls
mofa_capture MoveIfPresent "$T_OFFICE/missing.plist" "$backup_plist"
mofa_assert_contains "$MOFA_STDOUT" "Skipping missing path" "a missing source is logged"
mofa_assert_not_called /bin/mv "mv does not run for a missing source"

# --- Keychain item loops ------------------------------------------------------------
mofa_case "DeleteAllGenericPasswords deletes until no item is found"
t_reset_globals
LoggedInUser=alice
LoggedInUserID=501
mofa_stub_handler /bin/launchctl t_fake_launchctl
T_KEYCHAIN_ITEMS=2
mofa_capture DeleteAllGenericPasswords -G 'MSOpenTech.ADAL.1'
mofa_assert_status 0 "the loop ends when no item is left"
mofa_assert_eq 2 "$(t_count_calls_matching '*delete-generic-password*')" "each found item is deleted once"
mofa_assert_eq 3 "$(t_count_calls_matching '*find-generic-password*')" "the loop checks once more after the last delete"
mofa_assert_called "${T_AS_ALICE[@]}" /usr/bin/security delete-generic-password -G MSOpenTech.ADAL.1

mofa_case "DeleteAllGenericPasswords stops at the attempt limit and on a failed delete"
t_reset_globals
LoggedInUser=alice
LoggedInUserID=501
mofa_stub /bin/launchctl 0
mofa_capture DeleteAllGenericPasswords -l 'Exchange'
mofa_assert_status 1 "an item that never goes away stops the loop"
mofa_assert_eq 50 "$(t_count_calls_matching '*delete-generic-password*')" "at most KEYCHAIN_DELETE_LIMIT deletes run"
mofa_assert_contains "$MOFA_STDERR" "Stopped deleting 'Exchange' after 50 attempts" "the limit is logged"
mofa_reset_calls
mofa_stub_handler /bin/launchctl t_fake_delete_fails
mofa_capture DeleteAllGenericPasswords -l 'Exchange'
mofa_assert_status 1 "a failed delete stops the loop"
mofa_assert_eq 1 "$(t_count_calls_matching '*delete-generic-password*')" "a failed delete is not retried"

# --- Data protection keychain (keychain-2.db) ---------------------------------------
mofa_case "RemoveOneAuthDataProtectionItems does nothing without a console user"
t_reset_globals
HOME="/var/empty"
mofa_capture RemoveOneAuthDataProtectionItems
mofa_assert_status 0 "no console user is not an error"
mofa_assert_contains "$MOFA_STDOUT" "skipping data protection keychain cleanup" "the skip is logged"
mofa_assert_no_calls "neither find nor sqlite3 runs without a console user"

mofa_case "RemoveOneAuthDataProtectionItems searches only the user's own files in Keychains/<UUID>"
t_reset_globals
LoggedInUser=alice
LoggedInUserID=501
HOME="$T_HOME"
db_one="$T_KEYCHAINS/11111111-AAAA/keychain-2.db"
db_two="$T_KEYCHAINS/22222222-BBBB/keychain-2.db"
mofa_stub /usr/bin/find 0 "${db_one}"$'\n'"${db_two}"
mofa_stub /usr/bin/sqlite3 0 "3"
mofa_capture RemoveOneAuthDataProtectionItems
mofa_assert_status 0 "successful deletes return 0"
mofa_assert_called /usr/bin/find "$T_KEYCHAINS" -mindepth 2 -maxdepth 2 -type f -name keychain-2.db -user alice
mofa_assert_called /usr/bin/sqlite3 -cmd ".timeout 10000" "$db_one" "$T_ONEAUTH_SQL"
mofa_assert_called /usr/bin/sqlite3 -cmd ".timeout 10000" "$db_two" "$T_ONEAUTH_SQL"
mofa_assert_eq 2 "$(mofa_call_count /usr/bin/sqlite3)" "sqlite3 runs once per database"
mofa_assert_contains "$MOFA_STDOUT" "Removed 3 OneAuth item(s) from ${db_one}" "the number of deleted items is logged"
mofa_assert_eq 0 "$REMOVAL_FAILURES" "no failure counted"
mofa_assert_not_called /usr/bin/head "the first match is no longer picked blindly"

mofa_case "RemoveOneAuthDataProtectionItems reports and counts a failed delete"
t_reset_globals
LoggedInUser=alice
LoggedInUserID=501
HOME="$T_HOME"
db_one="$T_KEYCHAINS/11111111-AAAA/keychain-2.db"
mofa_stub /usr/bin/find 0 "$db_one"
mofa_stub /usr/bin/sqlite3 5 "Error: database is locked"
mofa_capture RemoveOneAuthDataProtectionItems
mofa_assert_status 1 "a failed delete returns 1"
mofa_assert_eq 1 "$REMOVAL_FAILURES" "a failed delete is counted as a removal failure"
mofa_assert_contains "$MOFA_STDERR" "Failed to remove OneAuth items from ${db_one}: Error: database is locked" "the sqlite3 error is logged"
mofa_assert_not_contains "$MOFA_STDOUT" "Removed" "a failed delete is not reported as a success"

mofa_case "RemoveOneAuthDataProtectionItems still cleans later databases after a failed delete"
t_reset_globals
LoggedInUser=alice
LoggedInUserID=501
HOME="$T_HOME"
db_one="$T_KEYCHAINS/11111111-AAAA/keychain-2.db"
db_two="$T_KEYCHAINS/22222222-BBBB/keychain-2.db"
T_DB_LOCKED="$db_one"
mofa_stub /usr/bin/find 0 "${db_one}"$'\n'"${db_two}"
mofa_stub_handler /usr/bin/sqlite3 t_fake_sqlite3
mofa_capture RemoveOneAuthDataProtectionItems
mofa_assert_status 1 "one failed database makes the cleanup return 1"
mofa_assert_called /usr/bin/sqlite3 -cmd ".timeout 10000" "$db_two" "$T_ONEAUTH_SQL"
mofa_assert_eq 2 "$(mofa_call_count /usr/bin/sqlite3)" "the failure does not stop the loop"
mofa_assert_eq 1 "$REMOVAL_FAILURES" "only the failed database is counted"
mofa_assert_contains "$MOFA_STDERR" "Failed to remove OneAuth items from ${db_one}: Error: database is locked" "the locked database is logged"
mofa_assert_contains "$MOFA_STDOUT" "Removed 1 OneAuth item(s) from ${db_two}" "the later database is still cleaned"

mofa_case "RemoveOneAuthDataProtectionItems logs when no database is found"
t_reset_globals
LoggedInUser=alice
LoggedInUserID=501
HOME="$T_HOME"
mofa_stub /usr/bin/find 0
mofa_capture RemoveOneAuthDataProtectionItems
mofa_assert_status 0 "no database is not an error"
mofa_assert_contains "$MOFA_STDOUT" "No data protection keychain found for alice" "the missing database is logged"
mofa_assert_not_called /usr/bin/sqlite3 "sqlite3 does not run without a database"

mofa_case "RemoveOneAuthDataProtectionItems ignores shallow, nested and symlinked keychain-2.db files"
t_reset_globals
LoggedInUser="$USERNAME" # real find checks -user, and the sandbox files belong to the test user
LoggedInUserID=501
HOME="$T_HOME"
db_real="$T_KEYCHAINS/11111111-AAAA/keychain-2.db"
mofa_write_file "$db_real" "db"
mofa_write_file "$T_KEYCHAINS/keychain-2.db" "too shallow"
mofa_write_file "$T_KEYCHAINS/11111111-AAAA/nested/keychain-2.db" "too deep"
mofa_write_file "$T_DIR/elsewhere/keychain-2.db" "outside the keychain folder"
mofa_mkdir "$T_KEYCHAINS/33333333-LINK"
t_sandbox_symlink "$T_DIR/elsewhere/keychain-2.db" "$T_KEYCHAINS/33333333-LINK/keychain-2.db"
t_sandbox_symlink "$T_DIR/elsewhere" "$T_KEYCHAINS/44444444-DIRLINK"
mofa_stub_handler /usr/bin/find t_sandbox_find
mofa_stub /usr/bin/sqlite3 0 "1"
mofa_capture RemoveOneAuthDataProtectionItems
mofa_assert_status 0 "the cleanup succeeds"
mofa_assert_eq "$(t_fmt /usr/bin/sqlite3 -cmd ".timeout 10000" "$db_real" "$T_ONEAUTH_SQL")" "$(mofa_calls /usr/bin/sqlite3)" "only the regular file directly inside Keychains/<UUID> is opened"

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
mofa_case "main resets the console user's sign-in state after quitting the apps"
t_reset_globals
t_setup_console_user
T_SEARCH_LIST='    "/Library/Keychains/System.keychain"'
db_real="$T_KEYCHAINS/11111111-AAAA/keychain-2.db"
mofa_stub /usr/bin/find 0 "$db_real"
mofa_stub /usr/bin/sqlite3 0 "2"
mofa_mkdir "$T_HOME/Library/Group Containers/UBF8T346G9.com.microsoft.oneauth" "$T_OFFICE/Licenses" \
	"$T_HOME/Library/Containers/com.microsoft.Word/Data/Library/Preferences"
mofa_write_file "$T_OFFICE/com.microsoft.Office365V2.plist" "x"
mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.office.plist" "x"
mofa_write_file "$T_KEYCHAINS/Microsoft_Entity_Certificates-db" "x"
mofa_run t_main_flow / computer alice
mofa_assert_status 0 "the reset exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Running as: alice; Home Folder: ${T_HOME}" "run context is logged"
for app in 'Microsoft Word' 'Microsoft Excel' 'Microsoft PowerPoint' 'Microsoft Outlook' 'Microsoft OneNote' MSTeams OneDrive; do
	mofa_assert_called /usr/bin/pkill -HUP "$app"
done
mofa_assert_called "${T_AS_ALICE[@]}" /usr/bin/security list-keychains -d user -s "$T_KEYCHAINS/login.keychain-db" /Library/Keychains/System.keychain
mofa_assert_called "${T_AS_ALICE[@]}" /usr/bin/security delete-generic-password -s OneAuthAccount
mofa_assert_called "${T_AS_ALICE[@]}" /usr/bin/security delete-generic-password -s com.microsoft.onedrive.cookies
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Group Containers/UBF8T346G9.com.microsoft.oneauth"
mofa_assert_called /bin/rm -rf -- "$T_OFFICE/Licenses"
mofa_assert_called /bin/rm -f -- "$T_KEYCHAINS/Microsoft_Entity_Certificates-db"
mofa_assert_called /bin/mv -f -- "$T_OFFICE/com.microsoft.Office365V2.plist" "$T_OFFICE/com.microsoft.Office365V2.backup"
mofa_assert_called "${T_AS_ALICE[@]}" /usr/bin/defaults write "$T_HOME/Library/Preferences/com.microsoft.office" OfficeAutoSignIn -bool TRUE
mofa_assert_called "${T_AS_ALICE[@]}" /usr/bin/defaults write "$T_HOME/Library/Containers/com.microsoft.Word/Data/Library/Preferences/com.microsoft.Word" kSubUIAppCompletedFirstRunSetup1507 -bool FALSE
mofa_assert_called /usr/bin/find "$T_KEYCHAINS" -mindepth 2 -maxdepth 2 -type f -name keychain-2.db -user alice
mofa_assert_called /usr/bin/sqlite3 -cmd ".timeout 10000" "$db_real" "$T_ONEAUTH_SQL"
mofa_assert_contains "$MOFA_STDOUT" "Removed 2 OneAuth item(s) from ${db_real}" "the keychain-2.db result is logged"
mofa_assert_called_before /usr/bin/pkill /bin/launchctl "the apps are quit before keychain items are removed"
mofa_assert_called_before /usr/bin/pkill /bin/rm "the apps are quit before files are removed"
mofa_assert_called_before /usr/bin/pkill /usr/bin/sqlite3 "the apps are quit before keychain-2.db is changed"
t_calls=("${(@f)$(mofa_calls)}")
mofa_assert_eq "$(t_fmt "${T_AS_ALICE[@]}" /usr/bin/killall cfprefsd)" "${t_calls[-1]}" "preferences are flushed last"

mofa_case "main keeps a search list that already holds the login keychain"
t_reset_globals
t_setup_console_user
T_SEARCH_LIST="    \"${T_KEYCHAINS}/login.keychain-db\""
mofa_stub /usr/bin/find 0
mofa_run t_main_flow / computer alice
mofa_assert_status 0 "the reset exits 0"
mofa_assert_not_contains "$(mofa_calls /bin/launchctl)" "list-keychains -d user -s" "the search list is not rewritten"

mofa_case "main exits 1 when the keychain-2.db delete fails"
t_reset_globals
t_setup_console_user
db_real="$T_KEYCHAINS/11111111-AAAA/keychain-2.db"
mofa_stub /usr/bin/find 0 "$db_real"
mofa_stub /usr/bin/sqlite3 1 "Error: unable to open database file"
mofa_run t_main_flow / computer alice
mofa_assert_status 1 "a failed keychain-2.db delete is reported to Jamf"
mofa_assert_contains "$MOFA_STDERR" "Failed to remove OneAuth items from ${db_real}" "the failed delete is logged"
mofa_assert_contains "$MOFA_STDERR" "Completed with 1 removal failure(s)" "the failure count is logged"

mofa_case "main exits 1 when a removal fails"
t_reset_globals
t_setup_console_user
mofa_stub /usr/bin/find 0
mofa_write_file "$T_OFFICE/DRM_Evo.plist" "x"
mofa_stub /bin/rm 1
mofa_run t_main_flow / computer alice
mofa_assert_status 1 "a removal failure is reported to Jamf"
mofa_assert_contains "$MOFA_STDERR" "removal failure(s)" "the failure count is logged"

mofa_case "main without a console user skips all user-context work"
t_reset_globals
mofa_stub /usr/sbin/scutil 0 ""
mofa_stub_passthrough /usr/bin/awk
mofa_run t_main_flow / computer alice
mofa_assert_status 0 "the run succeeds"
mofa_assert_contains "$MOFA_STDOUT" "skipping user keychain cleanup" "the keychain skip is logged"
mofa_assert_contains "$MOFA_STDOUT" "skipping data protection keychain cleanup" "the keychain-2.db skip is logged"
mofa_assert_not_called /bin/launchctl "nothing runs in a user context"
mofa_assert_not_called /usr/bin/find "no keychain folder is searched"
mofa_assert_not_called /usr/bin/sqlite3 "no keychain database is opened"
mofa_assert_not_contains "$(mofa_calls /bin/rm)" "$MOFA_TEST_ROOT" "no sandbox user data is removed"

mofa_finish
