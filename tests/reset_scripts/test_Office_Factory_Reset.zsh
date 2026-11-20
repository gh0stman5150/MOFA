#!/bin/zsh --no-rcs
# Tests for office_reset_tools/mofa_community_maintained/scripts/MOFA_Community_Microsoft_Office_Factory_Reset.zsh.
# Run as an unprivileged user: zsh tests/reset_scripts/test_Office_Factory_Reset.zsh (or run_all.zsh).
# Every system command is a recording stub (see harness.zsh); nothing outside the sandbox changes.
# The script's system-wide targets (/Library/..., /var/root/...) are fixed literals, so the tests
# only check them for existence (read-only) and expect a recorded rm call exactly for those present.
# The full ordered target list, system-wide targets included, is checked from main's own log
# ("Removing PATH" / "Skipping missing path PATH"), so it does not depend on what the test Mac has.

source "${0:A:h}/harness.zsh"

mofa_source_script MOFA_Community_Microsoft_Office_Factory_Reset.zsh
mofa_assert_source_clean
for t_fn in RequireRoot FinishRun GetLoggedInUser SetHomeFolder removeTarget removePathList removeFileList; do
	mofa_assert_function_defined "$t_fn"
done
mofa_assert_eq 0 "$REMOVAL_FAILURES" "sourcing sets the removal failure count to 0"

integer T_CASE=0

# Every removal main makes, in script order, as "RM_OPTION:TARGET". @HOME stands for the console
# user's home folder; the other targets are system-wide.
T_EXPECTED_REMOVALS=(
	"-rf:/Library/Logs/Microsoft/autoupdate.log"
	"-rf:/Library/Logs/Microsoft/InstallLogs"
	"-rf:/Library/Logs/Microsoft/Teams"
	"-rf:/Library/Logs/Microsoft/OneDrive"
	"-f:@HOME/Library/Preferences/com.microsoft.autoupdate2.plist"
	"-f:@HOME/Library/Preferences/com.microsoft.autoupdate.fba.plist"
	"-f:@HOME/Library/Preferences/com.microsoft.shared.plist"
	"-f:@HOME/Library/Preferences/com.microsoft.office.plist"
	"-f:/Library/Preferences/com.microsoft.autoupdate.fba.plist"
	"-f:/Library/Preferences/com.microsoft.shared.plist"
	"-f:/Library/Preferences/com.microsoft.office.plist"
	"-f:/Library/Preferences/com.microsoft.teams.plist"
	"-f:/Library/Preferences/com.microsoft.teams2.plist"
	"-f:/Library/Managed Preferences/com.microsoft.shared.plist"
	"-f:/Library/Managed Preferences/com.microsoft.office.plist"
	"-f:/var/root/Library/Preferences/com.microsoft.autoupdate2.plist"
	"-f:/var/root/Library/Preferences/com.microsoft.autoupdate.fba.plist"
	"-rf:@HOME/Library/Application Support/Microsoft"
	"-rf:@HOME/Library/Caches/com.microsoft.autoupdate2"
	"-rf:@HOME/Library/Caches/com.microsoft.autoupdate.fba"
	"-rf:/Library/Application Support/Microsoft/Office365"
	"-rf:@HOME/Library/Group Containers/UBF8T346G9.Office"
	"-rf:@HOME/Library/Group Containers/UBF8T346G9.ms"
	"-rf:@HOME/Library/Group Containers/UBF8T346G9.OfficeOsfWebHost"
	"-rf:@HOME/Library/Application Scripts/UBF8T346G9.com.microsoft.oneauth"
	"-rf:@HOME/Library/Application Scripts/UBF8T346G9.Office"
	"-rf:@HOME/Library/Application Scripts/UBF8T346G9.ms"
	"-rf:@HOME/Library/Application Scripts/UBF8T346G9.OfficeOsfWebHost"
	"-rf:@HOME/Library/Application Scripts/UBF8T346G9.OfficeOneDriveSyncIntegration"
	"-f:@HOME/Library/Cookies/com.microsoft.OneDrive.binarycookies"
	"-f:@HOME/Library/Cookies/com.microsoft.OneDriveUpdater.binarycookies"
	"-f:@HOME/Library/Cookies/com.microsoft.OneDriveStandaloneUpdater.binarycookies"
	"-f:@HOME/Library/Cookies/com.microsoft.teams.binarycookies"
	"-f:@HOME/Library/Cookies/com.microsoft.teams2.binarycookies"
	"-rf:@HOME/Library/HTTPStorages/com.microsoft.autoupdate.fba"
	"-rf:@HOME/Library/HTTPStorages/com.microsoft.autoupdate2"
	"-rf:@HOME/Library/HTTPStorages/com.microsoft.OneDrive"
	"-rf:@HOME/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater"
	"-rf:@HOME/Library/HTTPStorages/com.microsoft.teams"
	"-rf:@HOME/Library/HTTPStorages/com.microsoft.teams2"
	"-f:@HOME/Library/HTTPStorages/com.microsoft.autoupdate.fba.binarycookies"
	"-f:@HOME/Library/HTTPStorages/com.microsoft.autoupdate2.binarycookies"
	"-f:@HOME/Library/HTTPStorages/com.microsoft.OneDrive.binarycookies"
	"-f:@HOME/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater.binarycookies"
	"-f:@HOME/Library/HTTPStorages/com.microsoft.teams.binarycookies"
	"-f:@HOME/Library/HTTPStorages/com.microsoft.teams2.binarycookies"
	"-rf:@HOME/Library/Containers/com.microsoft.errorreporting"
	"-rf:@HOME/Library/Containers/com.microsoft.netlib.shipassertprocess"
	"-rf:@HOME/Library/Containers/com.microsoft.Office365ServiceV2"
	"-rf:@HOME/Library/Containers/com.microsoft.RMS-XPCService"
)

# Every pkill main runs, in script order, as one argv per entry (words separated by "|").
T_EXPECTED_PKILLS=(
	"-9|Microsoft Word"
	"-9|Microsoft Excel"
	"-9|Microsoft PowerPoint"
	"-9|Microsoft Outlook"
	"-9|Microsoft OneNote"
	"-9|OneDrive"
	"-9|FinderSync"
	"-9|OneDriveStandaloneUpdater"
	"-9|OneDriveUpdater"
	"-9|MSTeams"
	"-9|Microsoft Teams"
	"-9|Microsoft Teams Helper"
	"-9|Microsoft AutoUpdate"
	"-9|Microsoft Update Assistant"
	"-9|Microsoft AU Daemon"
	"-9|Microsoft AU Bootstrapper"
	"-9|-f|com.microsoft.autoupdate.helper"
	"-9|-f|com.microsoft.autoupdate.bootstrapper.helper"
)

# --- Test helpers (t_ prefix: never clash with script functions) ---------------------
t_reset_globals() { # fresh script globals and per-case fixture paths inside the sandbox
	(( T_CASE++ ))
	T_DIR="$MOFA_TEST_ROOT/case${T_CASE}"
	T_HOME="$T_DIR/home/alice"
	mofa_mkdir "$T_DIR"
	unset MODE
	REMOVAL_FAILURES=0
	LoggedInUser=""
	LoggedInUserID=""
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
t_main_as_root() {
	RequireRoot() { :; }
	main "$@"
}

t_expected_target() { # $1: entry from T_EXPECTED_REMOVALS, $2: home folder; prints the target
	local rel="${1#*:}"
	print -r -- "${rel/#@HOME/$2}"
}

t_create_home_fixtures() { # creates every @HOME target under $1 (files for -f, folders for -rf)
	local entry target
	for entry in "${T_EXPECTED_REMOVALS[@]}"; do
		[[ "$entry" == *:@HOME/* ]] || continue
		target="$(t_expected_target "$entry" "$1")"
		if [[ "${entry%%:*}" == -f ]]; then
			mofa_write_file "$target" "x"
		else
			mofa_mkdir "$target"
		fi
	done
}

t_expected_rm_calls() { # $1: home folder; prints "OPTION:TARGET" for each target that exists, in order
	local entry target
	for entry in "${T_EXPECTED_REMOVALS[@]}"; do
		target="$(t_expected_target "$entry" "$1")"
		[[ -e "$target" || -L "$target" ]] && print -r -- "${entry%%:*}:${target}"
	done
	return 0
}

t_expected_targets() { # $1: home folder; prints every target main must try to remove, in script order
	local entry
	for entry in "${T_EXPECTED_REMOVALS[@]}"; do
		t_expected_target "$entry" "$1"
	done
	return 0
}

# Prints each target main tried to remove, in order, from its log in MOFA_STDOUT. removeTarget logs
# every target it accepts as "Removing PATH" or "Skipping missing path PATH", so this also covers the
# system-wide targets that do not exist on the test Mac and therefore never reach rm.
t_attempted_targets() {
	local line
	for line in "${(@f)MOFA_STDOUT}"; do
		case "$line" in
			"Office-Reset: Removing /"*) print -r -- "${line#Office-Reset: Removing }" ;;
			"Office-Reset: Skipping missing path "*) print -r -- "${line#Office-Reset: Skipping missing path }" ;;
		esac
	done
	return 0
}

t_rm_calls() { # prints "OPTION:TARGET" for each recorded removal, in order (zf_rm's -rs and
	# -s shown as the script's -rf and -f)
	local line
	local -a t_words
	for line in "${(@f)$(mofa_removal_calls)}"; do
		[[ -n "$line" ]] || continue
		t_words=("${(@Q)${(@z)line}}")
		if [[ ${#t_words} -ne 4 || "${t_words[3]}" != "--" ]]; then
			print -r -- "unexpected rm argv: ${line}"
			continue
		fi
		case "${t_words[1]}:${t_words[2]}" in
			(zf_rm:-rs) t_words[2]=-rf ;;
			(zf_rm:-s) t_words[2]=-f ;;
		esac
		print -r -- "${t_words[2]}:${t_words[4]}"
	done
	return 0
}

t_assert_all_pkills() { # $1: message prefix
	local entry
	for entry in "${T_EXPECTED_PKILLS[@]}"; do
		mofa_assert_called /usr/bin/pkill "${(@s:|:)entry}"
	done
	mofa_assert_eq "${#T_EXPECTED_PKILLS}" "$(mofa_call_count /usr/bin/pkill)" "$1: every listed process is stopped once"
}

# --- Parameters and root check ------------------------------------------------------
mofa_case "main refuses to run without root"
t_reset_globals
mofa_run main / computer alice
mofa_assert_status 1 "main exits 1 when not root"
mofa_assert_eq "Office-Reset: Starting postinstall for Reset_Factory" "$MOFA_STDOUT" "only the start banner precedes the root check"
mofa_assert_contains "$MOFA_STDERR" "This script must be run as root." "root check message"
mofa_assert_no_calls "nothing runs before the root check"

mofa_case "main takes no custom parameters"
t_reset_globals
MODE=bogus mofa_run t_main_flow / computer alice bogus
mofa_assert_status 0 "parameter 4 and a MODE environment value are ignored"
mofa_assert_not_contains "$MOFA_OUTPUT" "Unsupported mode" "no mode is parsed"
t_assert_all_pkills "with an unused parameter 4"

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
mofa_stub /usr/bin/dscl 1
mofa_capture SetHomeFolder "mofa_no_such_user_$$"
mofa_assert_status 1 "SetHomeFolder returns 1 when there is no directory record or /Users folder"
mofa_assert_eq "/var/empty" "$HOME" "HOME falls back to /var/empty without a record"

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

	mofa_case "SetHomeFolder falls back to /Users/NAME when the record has no home"
	t_reset_globals
	mofa_stub /usr/bin/dscl 1
	mofa_stub_passthrough /usr/bin/awk
	mofa_stub /usr/bin/id 0 "503"
	LoggedInUser=Shared
	mofa_capture SetHomeFolder Shared
	mofa_assert_status 0 "SetHomeFolder accepts the existing /Users/Shared folder"
	mofa_assert_eq "/Users/Shared" "$HOME" "HOME falls back to /Users/NAME"
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
mofa_assert_nothing_removed "rm never runs for an unsafe target"

mofa_case "removeTarget removes with zsh's paranoid rm (zf_rm -s), the option and the full path"
t_reset_globals
target="$T_HOME/Library/Group Containers/UBF8T346G9.Office"
mofa_mkdir "$target"
mofa_capture removeTarget -rf "$target"
mofa_assert_status 0 "removeTarget succeeds"
mofa_assert_removed -rf "$target"
mofa_assert_eq 1 "$(mofa_removal_count)" "rm runs once"
mofa_assert_eq 0 "$REMOVAL_FAILURES" "no failure counted"
mofa_assert_contains "$MOFA_STDOUT" "Removing $target" "the removal is logged"
[[ -d "$target" ]] && mofa_pass "the stub did not delete anything" || mofa_fail "the stub did not delete anything"
plist="$T_HOME/Library/Preferences/com.microsoft.office.plist"
mofa_write_file "$plist" "x"
mofa_capture removeFileList "$plist"
mofa_assert_removed -f "$plist"

mofa_case "removeTarget counts rm failures and skips missing paths"
t_reset_globals
plist="$T_HOME/Library/Preferences/com.microsoft.office.plist"
mofa_write_file "$plist" "x"
mofa_stub_removals 1
mofa_capture removeTarget -f "$plist"
mofa_assert_status 1 "a failed rm returns 1"
mofa_assert_eq 1 "$REMOVAL_FAILURES" "a failed rm is counted"
mofa_assert_contains "$MOFA_STDERR" "Failed to remove" "a failed rm is logged"
mofa_reset_calls
mofa_capture removeTarget -rf "$T_HOME/Library/Containers/missing"
mofa_assert_status 0 "a missing path is not an error"
mofa_assert_contains "$MOFA_STDOUT" "Skipping missing path" "a missing path is logged"
mofa_assert_nothing_removed "rm does not run for a missing path"

mofa_case "removePathList and removeFileList keep going after a refused target"
t_reset_globals
folder="$T_HOME/Library/Caches/com.microsoft.autoupdate2"
plist="$T_HOME/Library/Preferences/com.microsoft.shared.plist"
mofa_mkdir "$folder"
mofa_write_file "$plist" "x"
mofa_capture removePathList "" "$folder"
mofa_capture removeFileList "relative.plist" "$plist"
mofa_assert_eq 2 "$REMOVAL_FAILURES" "both refusals are counted"
mofa_assert_removed -rf "$folder"
mofa_assert_removed -f "$plist"
mofa_assert_eq 2 "$(mofa_removal_count)" "only the safe targets reach rm"

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
mofa_assert_eq "" "$MOFA_OUTPUT" "a clean finish prints nothing"

# --- End-to-end flow with every command stubbed ---------------------------------------
mofa_case "main stops Office, then removes the shared data in script order"
t_reset_globals
mofa_stub /usr/sbin/scutil 0 "  Name : alice"
mofa_stub_passthrough /usr/bin/awk
t_create_home_fixtures "$T_HOME"
mofa_write_file "$T_HOME/Library/Preferences/com.microsoft.Word.plist" "keep"
mofa_mkdir "$T_HOME/Library/Containers/com.microsoft.Word" "$T_HOME/Documents"
mofa_write_file "$T_HOME/Documents/Report.docx" "keep"
t_expected="$(t_expected_rm_calls "$T_HOME")"
mofa_run t_main_flow / computer alice
mofa_assert_status 0 "the factory reset exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Running as: alice; Home Folder: ${T_HOME}" "run context is logged"
mofa_assert_contains "$MOFA_STDOUT" "Stopping apps and services" "stopping apps is logged"
mofa_assert_contains "$MOFA_STDOUT" "Removing preferences and containers" "removal is logged"
t_assert_all_pkills "reset flow"
mofa_assert_called_before /usr/bin/pkill zf_rm "apps are stopped before their data is removed"
mofa_assert_eq "$t_expected" "$(t_rm_calls)" "every target is removed once, with its option, in script order"
mofa_assert_eq "$(t_expected_targets "$T_HOME")" "$(t_attempted_targets)" \
	"all ${#T_EXPECTED_REMOVALS} targets, system-wide ones included, are attempted once in script order"
mofa_assert_not_contains "$MOFA_STDERR" "Refusing to remove unsafe path" "no target main builds is refused"
t_home_calls=(${(M)${(f)"$(t_rm_calls)"}:#*:${T_HOME}/*})
mofa_assert_eq 36 "${#t_home_calls}" "all 36 user-data targets in the home folder are removed"
t_rm_text="$(mofa_removal_calls)"
mofa_assert_not_contains "$t_rm_text" "com.microsoft.Word" "Word's own preferences and container are kept"
mofa_assert_not_contains "$t_rm_text" "Report.docx" "documents are kept"
mofa_assert_not_called /usr/bin/curl "nothing is downloaded"
mofa_assert_not_called /usr/sbin/installer "nothing is installed"

mofa_case "main skips user data when no one is logged in"
t_reset_globals
mofa_stub /usr/sbin/scutil 0 "  Name : loginwindow"
mofa_stub_passthrough /usr/bin/awk
t_expected="$(t_expected_rm_calls /var/empty)"
mofa_run t_main_as_root / computer ""
mofa_assert_status 0 "the run succeeds without a console user"
mofa_assert_contains "$MOFA_STDOUT" "Running as: <none>; Home Folder: /var/empty" "the missing console user is logged"
mofa_assert_not_called /usr/bin/dscl "no directory lookup without a console user"
t_assert_all_pkills "no console user"
mofa_assert_eq "$t_expected" "$(t_rm_calls)" "only existing system-wide targets are removed"
mofa_assert_eq "$(t_expected_targets /var/empty)" "$(t_attempted_targets)" \
	"every system-wide target is still attempted, in script order, without a console user"
mofa_assert_not_contains "$(mofa_removal_calls)" "/var/empty" "nothing under /var/empty is removed"

mofa_case "main skips user data when the console user's home is outside /Users"
t_reset_globals
mofa_stub /usr/sbin/scutil 0 "  Name : mofatestuser"
mofa_stub_passthrough /usr/bin/awk
mofa_stub /usr/bin/dscl 0 "NFSHomeDirectory: /private/var/mofa_test_home"
t_expected="$(t_expected_rm_calls /var/empty)"
mofa_run t_main_as_root / computer mofatestuser
mofa_assert_status 0 "the run continues with system-wide cleanup"
mofa_assert_contains "$MOFA_STDERR" "not under /Users; skipping user data" "the skipped home is logged"
mofa_assert_contains "$MOFA_STDOUT" "Running as: <none>; Home Folder: /var/empty" "user data is skipped"
mofa_assert_eq "$t_expected" "$(t_rm_calls)" "only existing system-wide targets are removed"
mofa_assert_eq "$(t_expected_targets /var/empty)" "$(t_attempted_targets)" "user targets resolve under /var/empty, never the refused home"
mofa_assert_not_contains "$(mofa_removal_calls)" "mofa_test_home" "the refused home is never touched"

mofa_case "main exits 1 when a removal fails, after attempting every target"
t_reset_globals
mofa_stub /usr/sbin/scutil 0 "  Name : alice"
mofa_stub_passthrough /usr/bin/awk
t_create_home_fixtures "$T_HOME"
t_expected="$(t_expected_rm_calls "$T_HOME")"
mofa_stub_removals 1
mofa_run t_main_flow / computer alice
mofa_assert_status 1 "a removal failure is reported to Jamf"
mofa_assert_eq "$t_expected" "$(t_rm_calls)" "a failed removal does not stop the remaining removals"
mofa_assert_eq "$(t_expected_targets "$T_HOME")" "$(t_attempted_targets)" "every target is still attempted after a failure"
mofa_assert_contains "$MOFA_STDERR" "Completed with $(mofa_removal_count) removal failure(s)" "every failure is counted"

# --- 1.3.0: root never follows a link planted above or below a removal target ----------
# The cases marked "real zf_rm" run zsh's own rm (a builtin, not a stub) on fixtures, and only
# inside the kernel sandbox, which confines every write to this test's folder.
t_link_fixture() { # $1: link target, $2: link path inside the sandbox
	if [[ "${2:a}" != "$MOFA_TEST_ROOT"/?* ]]; then
		mofa_fail "t_link_fixture refused a link outside the sandbox: $2"
		return 1
	fi
	command /bin/ln -s -- "$1" "$2"
}

mofa_case "removeTarget refuses unsafe target spellings"
mofa_mkdir "$MOFA_TEST_ROOT/spelled"
for bad in "$MOFA_TEST_ROOT/spelled/" "$MOFA_TEST_ROOT/spelled/." "$MOFA_TEST_ROOT/spelled/.."; do
	REMOVAL_FAILURES=0
	mofa_capture removeTarget -rf "$bad"
	mofa_assert_status 1 "removeTarget refuses '${bad}'"
	mofa_assert_eq 1 "$REMOVAL_FAILURES" "refusing '${bad}' counts as a removal failure"
done
mofa_assert_nothing_removed "nothing is removed for an unsafe spelling"

mofa_case "removeTarget maps macOS's own /var and /tmp links to /private"
REMOVAL_FAILURES=0
if [[ "$MOFA_TEST_ROOT" == /private/(var|tmp)/* ]]; then
	mofa_mkdir "$MOFA_TEST_ROOT/system_link/com.microsoft.App"
	mofa_capture removeTarget -rf "${MOFA_TEST_ROOT#/private}/system_link/com.microsoft.App"
	mofa_assert_status 0 "removeTarget accepts a path through macOS's own link"
	mofa_assert_called zf_rm -rs -- "$MOFA_TEST_ROOT/system_link/com.microsoft.App"
else
	mofa_pass "skipped: the sandbox is not under /private/var or /private/tmp"
fi

mofa_case "removeTarget reports a locked file instead of letting zf_rm skip it"
REMOVAL_FAILURES=0
mofa_write_file "$MOFA_TEST_ROOT/locked/file.plist" "x"
mofa_stub zf_rm 0 "zf_rm: remove \`$MOFA_TEST_ROOT/locked/file.plist', overriding mode 0444? "
mofa_capture removeTarget -f "$MOFA_TEST_ROOT/locked/file.plist"
mofa_assert_status 1 "removeTarget fails when zf_rm asks to override a locked file"
mofa_assert_eq 1 "$REMOVAL_FAILURES" "the locked file counts as a removal failure"
mofa_assert_contains "$MOFA_STDERR" "it holds a locked or read-only file" "the reason is logged"

mofa_case "removeTarget fails closed when zsh's files module is unavailable"
REMOVAL_FAILURES=0
mofa_mkdir "$MOFA_TEST_ROOT/no_module/target"
mofa_stub zmodload 1
mofa_capture removeTarget -rf "$MOFA_TEST_ROOT/no_module/target"
unfunction zmodload
mofa_assert_status 1 "removeTarget fails without zf_rm"
mofa_assert_contains "$MOFA_STDERR" "zsh's files module is unavailable" "the reason is logged"
mofa_assert_nothing_removed "nothing falls back to /bin/rm"

if (( MOFA_KERNEL_SANDBOX )); then
	mofa_case "removeTarget refuses a target below a symbolically linked folder (real zf_rm)"
	REMOVAL_FAILURES=0
	t_link_dir="$MOFA_TEST_ROOT/linked_parent"
	mofa_mkdir "$t_link_dir/other_user/Containers/com.microsoft.App" "$t_link_dir/home/Library"
	mofa_write_file "$t_link_dir/other_user/Containers/com.microsoft.App/keep" "other user's data"
	t_link_fixture "$t_link_dir/other_user/Containers" "$t_link_dir/home/Library/Containers"
	unfunction zf_rm
	mofa_capture removeTarget -rf "$t_link_dir/home/Library/Containers/com.microsoft.App"
	mofa_stub zf_rm
	mofa_assert_status 1 "removeTarget refuses a target reached through a planted link"
	mofa_assert_eq 1 "$REMOVAL_FAILURES" "the refusal counts as a removal failure"
	mofa_assert_contains "$MOFA_STDERR" \
		"Refusing to remove $t_link_dir/home/Library/Containers/com.microsoft.App: a folder in its path is a symbolic link" \
		"the refusal is logged"
	[[ -e "$t_link_dir/other_user/Containers/com.microsoft.App/keep" ]] \
		&& mofa_pass "the other user's data is kept" || mofa_fail "the other user's data is kept"

	mofa_case "removeTarget removes a folder but not what a link inside it points to (real zf_rm)"
	REMOVAL_FAILURES=0
	t_link_dir="$MOFA_TEST_ROOT/link_inside"
	mofa_mkdir "$t_link_dir/target/inner" "$t_link_dir/other_user"
	mofa_write_file "$t_link_dir/other_user/keep" "other user's data"
	t_link_fixture "$t_link_dir/other_user" "$t_link_dir/target/inner/link"
	unfunction zf_rm
	mofa_capture removeTarget -rf "$t_link_dir/target"
	mofa_stub zf_rm
	mofa_assert_status 0 "removeTarget removes the folder"
	[[ ! -e "$t_link_dir/target" ]] && mofa_pass "the folder is gone" || mofa_fail "the folder is gone"
	[[ -e "$t_link_dir/other_user/keep" ]] \
		&& mofa_pass "the link's target is kept" || mofa_fail "the link's target is kept"

	mofa_case "removeTarget reports a read-only file that zf_rm keeps unasked (real zf_rm)"
	REMOVAL_FAILURES=0
	mofa_mkdir "$MOFA_TEST_ROOT/readonly"
	( umask 0277; print -r -- x >| "$MOFA_TEST_ROOT/readonly/file.plist" )
	unfunction zf_rm
	mofa_capture removeTarget -f "$MOFA_TEST_ROOT/readonly/file.plist"
	mofa_stub zf_rm
	mofa_assert_status 1 "removeTarget fails for a file zf_rm will not delete unasked"
	mofa_assert_contains "$MOFA_STDERR" "it holds a locked or read-only file" "the reason is logged"
	[[ -e "$MOFA_TEST_ROOT/readonly/file.plist" ]] && mofa_pass "the file is kept" || mofa_fail "the file is kept"
else
	mofa_pass "skipped: the real zf_rm cases need the kernel sandbox"
fi

mofa_case "SetHomeFolder keeps HOME out of root's child processes"
mofa_assert_contains "${(t)HOME}" export "the harness exports HOME before the call"
mofa_capture SetHomeFolder ""
mofa_assert_not_contains "${(t)HOME}" export "without a console user, HOME is no longer exported"
if [[ -d /Users/Shared ]]; then
	export HOME
	mofa_stub /usr/bin/dscl 0 "NFSHomeDirectory: /Users/Shared"
	mofa_stub_passthrough /usr/bin/awk
	mofa_stub /usr/bin/id 0 "501"
	mofa_capture SetHomeFolder mofatestuser
	mofa_assert_eq "/Users/Shared" "$HOME" "SetHomeFolder points HOME at the user's home"
	mofa_assert_not_contains "${(t)HOME}" export "with a console user, HOME is no longer exported"
fi

mofa_finish
