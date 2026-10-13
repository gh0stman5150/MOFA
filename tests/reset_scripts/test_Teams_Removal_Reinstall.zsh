#!/bin/zsh --no-rcs
# Tests for office_reset_tools/mofa_community_maintained/scripts/MOFA_Community_Microsoft_Teams_Removal_Reinstall.zsh.
# Run as an unprivileged user: zsh tests/reset_scripts/test_Teams_Removal_Reinstall.zsh (or run_all.zsh).
# Every system command is a recording stub (see harness.zsh); nothing outside the sandbox changes.

source "${0:A:h}/harness.zsh"

mofa_source_script MOFA_Community_Microsoft_Teams_Removal_Reinstall.zsh
mofa_assert_source_clean
if [[ -o pipefail ]]; then
	mofa_fail "sourcing does not set PIPE_FAIL (main sets it)"
else
	mofa_pass "sourcing does not set PIPE_FAIL (main sets it)"
fi
setopt PIPE_FAIL # main sets this before calling anything, so the functions below run with it too
# Recording stubs that the t_ wrappers below call, so tests can see when and in what order they ran.
mofa_stub t_cleanup_probe 0
mofa_stub t_logging_probe 0
mofa_stub t_remove_probe 0
mofa_stub t_bootout_probe 0

integer T_CASE=0
typeset -gA T_DSCL_HOMES
T_SIGNED_BY_MICROSOFT=$'Package "MicrosoftTeams.pkg":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Certificate Chain:\n    1. Developer ID Installer: Microsoft Corporation (UBF8T346G9)'
T_SIGNED_BY_OTHER=$'Package "MicrosoftTeams.pkg":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Certificate Chain:\n    1. Developer ID Installer: Microsoft Corporation (ABCDE12345)'
T_BG_SUFFIX="Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/Backgrounds"

# --- Test helpers (t_ prefix: never clash with script functions) ---------------------
t_reset_globals() { # fresh script globals and per-case fixture paths inside the sandbox
	(( T_CASE++ ))
	T_DIR="$MOFA_TEST_ROOT/case${T_CASE}"
	T_USERS="$T_DIR/Users"
	T_HOME="$T_USERS/alice"
	T_WORK="$T_DIR/work"
	T_STAGE="$T_DIR/stage"
	T_APP="$T_DIR/Applications/Microsoft Teams.app"
	T_LOG="$T_DIR/log/MOFA_Community_Microsoft_Teams_Removal_Reinstall.log"
	T_BG="$T_HOME/$T_BG_SUFFIX"
	mofa_mkdir "$T_DIR" "$T_USERS"
	MODE="reinstall"
	DOWNLOAD_URL_TEAMS="https://go.microsoft.com/fwlink/?linkid=2249065"
	INSTALLATION_RETRIES=3
	DOWNLOAD_TIMEOUT=900
	WAIT_ATTEMPTS=20
	WAIT_DELAY=3
	CLEAN_ALL_USERS="true"
	TEMP_DIR=""
	PKG_PATH=""
	LoggedInUser=""
	LoggedInUserID=""
	CLEANUP_FAILURES=0
	BACKGROUND_BACKUP_DIR=""
	USER_HOMES_DIR="$T_USERS"
	EXPECTED_APP_PATH="$T_APP"
	LOG_FILE="$T_LOG"
	T_USER_TMP=""
	T_KEYCHAINS=""
	T_FIND_HITS=0
	T_DITTO_STATUS=0
	T_DSCL_LIST=""
	T_DSCL_HOMES=()
}

t_echo() { print -r -- "$*"; }

t_stub_logging() { # log() uses /bin/date, /bin/echo and logger; to_lower() uses tr
	mofa_stub /bin/date 0 "2026-01-01 00:00:00"
	mofa_stub_handler /bin/echo t_echo
	mofa_stub /usr/bin/logger 0
	mofa_stub_passthrough /usr/bin/tr
}

t_case() { # $1: title
	mofa_case "$1"
	t_reset_globals
	t_stub_logging
}

t_system_calls() { # recorded calls other than logging, case folding and t_ probes
	local line
	for line in "${(@f)$(mofa_calls)}"; do
		[[ -n "$line" ]] || continue
		case "$line" in
			(/bin/date|/bin/date\ *|/bin/echo\ *|/usr/bin/logger\ *|/usr/bin/tr\ *|t_*) ;;
			(*) print -r -- "$line" ;;
		esac
	done
}

t_assert_no_system_calls() { # $1: message
	local calls
	calls="$(t_system_calls)"
	if [[ -z "$calls" ]]; then
		mofa_pass "$1"
	else
		mofa_fail "$1" "recorded:"$'\n'"${calls}"
	fi
}

t_rm_targets() { # prints the last argument of every recorded /bin/rm call
	local line
	local -a words
	for line in "${(@f)$(mofa_calls /bin/rm)}"; do
		[[ -n "$line" ]] || continue
		words=("${(@Q)${(z)line}}")
		print -r -- "${words[-1]}"
	done
}

t_assert_rm_only_under() { # $1: message, then the folders rm may touch
	local msg="$1" target prefix bad=""
	local -i ok
	shift
	for target in "${(@f)$(t_rm_targets)}"; do
		[[ -n "$target" ]] || continue
		ok=0
		for prefix in "$@"; do
			[[ "$target" == "$prefix"/* ]] && ok=1
		done
		(( ok )) || bad+="${target}"$'\n'
	done
	if [[ -z "$bad" ]]; then
		mofa_pass "$msg"
	else
		mofa_fail "$msg" "unexpected rm targets:"$'\n'"${bad}"
	fi
}

t_assert_no_rm_under() { # $1: message, then folders rm must never touch
	local msg="$1" target prefix bad=""
	shift
	for target in "${(@f)$(t_rm_targets)}"; do
		[[ -n "$target" ]] || continue
		for prefix in "$@"; do
			[[ "$target" == "$prefix" || "$target" == "$prefix"/* ]] && bad+="${target}"$'\n'
		done
	done
	if [[ -z "$bad" ]]; then
		mofa_pass "$msg"
	else
		mofa_fail "$msg" "unexpected rm targets:"$'\n'"${bad}"
	fi
}

t_symlink() { # $1: link target, $2: link path; both inside the sandbox only
	if [[ "${1:a}" != "$MOFA_TEST_ROOT"/?* || "${2:a}" != "$MOFA_TEST_ROOT"/?* ]]; then
		mofa_fail "t_symlink refused a link outside the sandbox: $2 -> $1"
		return 1
	fi
	mofa_mkdir "${2:a:h}" || return 1
	command /bin/ln -s -- "$1" "$2"
}

t_show_args() { # parse_arguments, then print every setting it may change on one line
	parse_arguments "$@"
	print -r -- "SETTINGS MODE=${MODE} URL=${DOWNLOAD_URL_TEAMS} RETRIES=${INSTALLATION_RETRIES} TIMEOUT=${DOWNLOAD_TIMEOUT} ATTEMPTS=${WAIT_ATTEMPTS} DELAY=${WAIT_DELAY} CLEAN_ALL=${CLEAN_ALL_USERS} LOG=${LOG_FILE} APP=${EXPECTED_APP_PATH} HOMES=${USER_HOMES_DIR} HOMEVAR=${HOME} PATHVAR=${PATH}"
}

t_settings() { # the SETTINGS line t_show_args printed ((@) filters each line, not the joined text)
	print -r -- "${(@M)${(@f)MOFA_STDOUT}:#SETTINGS *}"
}

t_expect() { # $1 MODE, $2 URL, $3 RETRIES, $4 TIMEOUT, $5 ATTEMPTS, $6 DELAY, $7 CLEAN_ALL_USERS
	print -r -- "SETTINGS MODE=$1 URL=$2 RETRIES=$3 TIMEOUT=$4 ATTEMPTS=$5 DELAY=$6 CLEAN_ALL=$7 LOG=${T_LOG} APP=${T_APP} HOMES=${T_USERS} HOMEVAR=${MOFA_TEST_ROOT}/home PATHVAR=${MOFA_TEST_ROOT}/nopath"
}

# Runs main as if root, with a sandbox home for console user "alice". Only call through mofa_run.
t_main_flow() {
	RequireRoot() { :; }
	ensure_logging() { t_logging_probe; } # the real one redirects output through tee; tested on its own
	SetHomeFolder() {
		LoggedInUserID=""
		if [[ "$1" == alice ]]; then
			LoggedInUserID=501
			HOME="$T_HOME"
		else
			HOME="/var/empty"
		fi
	}
	cleanup() { t_cleanup_probe; } # recorded in the call log, so tests see when the EXIT trap ran
	main "$@"
}

# Runs the real main (and root check) as this unprivileged user. Only call through mofa_run.
t_main_unprivileged() {
	ensure_logging() { t_logging_probe; }
	cleanup() { t_cleanup_probe; }
	main "$@"
}

# Runs main as if root, with the real GetLoggedInUser and SetHomeFolder. Only call through mofa_run.
t_main_real_home() {
	RequireRoot() { :; }
	ensure_logging() { t_logging_probe; }
	cleanup() { t_cleanup_probe; }
	main "$@"
}

# Reports whether main has set PIPE_FAIL by the time logging starts. Only call through mofa_run.
t_main_options() {
	unsetopt PIPE_FAIL
	ensure_logging() { [[ -o pipefail ]] && print -r -- "PIPE_FAIL=on" || print -r -- "PIPE_FAIL=off"; }
	cleanup() { :; }
	main "$@"
}

t_file_text() { # $1: file; prints its contents (keeps $(<...) out of top-level code, which zsh -n expands)
	print -r -- "$(<"$1")"
}

t_find_generic_status() { # the first T_FIND_HITS keychain lookups find an item
	local -a found
	found=(${(M)${(f)"$(<"$MOFA_CALL_LOG")"}:#*find-generic-password*})
	(( ${#found} <= T_FIND_HITS ))
}

t_fake_launchctl() { # launchctl asuser UID /usr/bin/sudo -H -u USER CMD... (other forms succeed)
	[[ "$1" == asuser ]] || return 0
	shift 6
	case "$1" in
		/usr/bin/getconf)
			[[ -n "$T_USER_TMP" ]] && print -r -- "$T_USER_TMP"
			return 0
			;;
		/usr/bin/security)
			case "$2" in
				list-keychains)
					[[ "$*" == *" -s "* ]] || print -r -- "$T_KEYCHAINS"
					return 0
					;;
				find-generic-password) t_find_generic_status; return ;;
			esac
			return 0
			;;
		/usr/bin/ditto)
			(( T_DITTO_STATUS == 0 )) || return "$T_DITTO_STATUS"
			[[ "${@[-1]}" == "$MOFA_TEST_ROOT"/?* ]] || return 99
			mofa_mkdir "${@[-1]}"
			return
			;;
	esac
	return 0
}

t_fake_mktemp() { # mktemp -d TEMPLATE: hands out this case's sandbox folders
	case "${@[-1]}" in
		/private/var/tmp/teams-remove-reinstall.XXXXXX) print -r -- "$T_WORK" ;;
		/private/var/tmp/mofa-teams-backgrounds.XXXXXX) print -r -- "$T_STAGE" ;;
		*) return 1 ;;
	esac
}

t_fake_download() { # curl ... --output FILE -- URL: writes a fake package inside the sandbox only
	local out="" prev="" arg
	for arg in "$@"; do
		[[ "$prev" == --output ]] && out="$arg"
		prev="$arg"
	done
	[[ "$out" == "$MOFA_TEST_ROOT"/?* ]] || return 99
	print -r -- "fake package" >| "$out"
}

t_fake_dscl() { # dscl . -list /Users UniqueID, or dscl . -read /Users/NAME NFSHomeDirectory
	if [[ "$*" == ". -list /Users UniqueID" ]]; then
		print -r -- "$T_DSCL_LIST"
		return 0
	fi
	if [[ "$1" == . && "$2" == -read && "$4" == NFSHomeDirectory && -n "${T_DSCL_HOMES[${3#/Users/}]:-}" ]]; then
		print -r -- "NFSHomeDirectory: ${T_DSCL_HOMES[${3#/Users/}]}"
		return 0
	fi
	return 56
}

t_fake_tee() { # tee -a FILE: copy stdin to FILE (sandbox only) and to stdout
	local line
	[[ "$1" == -a && "$2" == "$MOFA_TEST_ROOT"/?* ]] || return 99
	while IFS= read -r line; do
		print -r -- "$line" >> "$2"
		print -r -- "$line"
	done
}

t_wait_for_text() { # $1: file, $2: text; waits up to ~5 s for an asynchronous writer
	local -i tries
	zmodload zsh/zselect 2>/dev/null || return 1
	for (( tries = 0; tries < 50; tries++ )); do
		[[ -f "$1" && "$(<"$1")" == *"$2"* ]] && return 0
		zselect -t 10
	done
	return 1
}

t_setup_console_user() {
	mofa_stub /usr/sbin/scutil 0 "  Name : alice"
	mofa_stub_passthrough /usr/bin/awk
	mofa_stub_passthrough /usr/bin/sed
	mofa_stub_handler /bin/launchctl t_fake_launchctl
	mofa_stub_handler /usr/bin/mktemp t_fake_mktemp
}

t_setup_download() { # $1: pkgutil output
	mofa_mkdir "$T_WORK" "$T_STAGE"
	mofa_stub /usr/bin/sw_vers 0 "15.5"
	mofa_stub_handler /usr/bin/mktemp t_fake_mktemp
	mofa_stub_handler /usr/bin/curl t_fake_download
	mofa_stub /usr/sbin/pkgutil 0 "$1"
	mofa_stub /usr/sbin/spctl 0
}

t_setup_healthy_app() {
	mofa_write_file "$T_APP/Contents/Info.plist" "plist"
	mofa_stub /usr/bin/codesign 0 "TeamIdentifier=UBF8T346G9"
	mofa_stub_passthrough /usr/bin/grep
	mofa_stub /usr/bin/defaults 0 "24295.605.3225.8804"
}

t_make_teams_data() { # $1: home folder inside the sandbox
	mofa_mkdir "$1/Library/Containers/com.microsoft.teams2" "$1/Library/Caches/com.microsoft.teams2"
	mofa_write_file "$1/Library/Preferences/com.microsoft.teams2.plist" "x"
	mofa_mkdir "$1/Library/Caches/com.microsoft.Outlook" # not Teams data; must be kept
}

t_list_system_paths() { # records what cleanup_system_paths would remove; only call through mofa_run
	remove_path() { t_remove_probe "$1"; }
	bootoutJob() { t_bootout_probe "$@"; }
	cleanup_system_paths "$@"
}

# --- Defaults and dedicated log -------------------------------------------------------
mofa_case "sourcing keeps the script's defaults and its dedicated log"
mofa_assert_eq "reinstall" "$MODE" "MODE defaults to reinstall"
mofa_assert_eq "/var/log/MOFA_Community_Microsoft_Teams_Removal_Reinstall.log" "$LOG_FILE" "the dedicated log path is unchanged"
mofa_assert_eq "/Users" "$USER_HOMES_DIR" "user data is limited to homes under /Users"
mofa_assert_eq "true" "$CLEAN_ALL_USERS" "reinstall cleans every user by default"
mofa_assert_eq "https://go.microsoft.com/fwlink/?linkid=2249065" "$DOWNLOAD_URL_TEAMS" "default download URL"
mofa_assert_eq "3 900 20 3" "$INSTALLATION_RETRIES $DOWNLOAD_TIMEOUT $WAIT_ATTEMPTS $WAIT_DELAY" "default retry and wait settings"
mofa_assert_eq "Microsoft Corporation (UBF8T346G9)" "$EXPECTED_INSTALLER_SIGNER" "the installer must come from Microsoft's team ID"

t_case "ensure_logging sends stdout and stderr to the dedicated log file"
mofa_mkdir "${T_LOG:h}"
mofa_stub_passthrough /usr/bin/dirname
mofa_stub_handler /usr/bin/tee t_fake_tee
t_logging_demo() { ensure_logging; log "logging probe line"; print -u2 -r -- "stderr probe line"; }
mofa_run t_logging_demo
mofa_assert_status 0 "ensure_logging succeeds"
mofa_assert_called /bin/mkdir -p "${T_LOG:h}"
mofa_assert_called /usr/bin/touch "$T_LOG"
mofa_assert_called /bin/chmod 600 "$T_LOG"
if t_wait_for_text "$T_LOG" "stderr probe line"; then
	mofa_pass "stderr reaches the log file"
else
	mofa_fail "stderr reaches the log file"
fi
mofa_assert_contains "$(t_file_text "$T_LOG")" "[MOFA Teams Remove/Reinstall] logging probe line" "log lines reach the log file"
mofa_assert_called /usr/bin/tee -a "$T_LOG"

# --- KEY=value argument contract ------------------------------------------------------
t_case "parse_arguments shifts Jamf's first three parameters and validates the rest"
mofa_run t_show_args / computer alice MODE=Force WAIT_DELAY=-1 BOGUS=1
mofa_assert_status 0 "the audit example parses"
mofa_assert_eq "$(t_expect reinstall "$DOWNLOAD_URL_TEAMS" 3 900 20 3 true)" "$(t_settings)" "MODE=Force gives reinstall and WAIT_DELAY=-1 falls back to 3"
mofa_assert_contains "$MOFA_STDOUT" "Shifting Jamf-style leading arguments." "the Jamf shift is logged"
mofa_assert_contains "$MOFA_STDOUT" "WARN: Ignoring unsupported argument: BOGUS" "an unsupported key is ignored with a warning"
t_assert_no_system_calls "argument parsing runs no system command"

t_case "parse_arguments accepts every allow-listed key"
mofa_run t_show_args / computer alice "DOWNLOAD_URL_TEAMS=https://cdn.example.com/Teams.pkg?a=b" INSTALLATION_RETRIES=5 \
	DOWNLOAD_TIMEOUT=60 WAIT_ATTEMPTS=2 WAIT_DELAY=0 CLEAN_ALL_USERS=false MODE=reset
mofa_assert_eq "$(t_expect reset "https://cdn.example.com/Teams.pkg?a=b" 5 60 2 0 false)" "$(t_settings)" "allow-listed keys are applied and only the first = splits"
for key in DOWNLOAD_URL_TEAMS INSTALLATION_RETRIES DOWNLOAD_TIMEOUT WAIT_ATTEMPTS WAIT_DELAY CLEAN_ALL_USERS MODE; do
	mofa_assert_contains "$MOFA_STDOUT" "Configured ${key} via script argument." "setting ${key} is logged"
done

t_case "parse_arguments clamps numeric settings"
mofa_run t_show_args / computer alice INSTALLATION_RETRIES=0 DOWNLOAD_TIMEOUT=abc WAIT_ATTEMPTS=-4 WAIT_DELAY=1.5
mofa_assert_eq "$(t_expect reinstall "$DOWNLOAD_URL_TEAMS" 3 900 20 3 true)" "$(t_settings)" "zero, negative and non-integer values fall back to the defaults"
mofa_run t_show_args / computer alice INSTALLATION_RETRIES=" 4" WAIT_ATTEMPTS="2;3"
mofa_assert_eq "$(t_expect reinstall "$DOWNLOAD_URL_TEAMS" 3 900 20 3 true)" "$(t_settings)" "padded or compound numbers fall back to the defaults"

t_case "parse_arguments normalises MODE and accepts bare mode words"
for raw expected in "MODE= Reset " reset "MODE=REINSTALL" reinstall "MODE=repair" reinstall "MODE=force" reinstall \
	reset reset Repair reinstall FORCE reinstall reinstall reinstall; do
	mofa_run t_show_args / computer alice "$raw"
	mofa_assert_status 0 "parse_arguments accepts '${raw}'"
	mofa_assert_eq "$(t_expect "$expected" "$DOWNLOAD_URL_TEAMS" 3 900 20 3 true)" "$(t_settings)" "'${raw}' gives MODE=${expected}"
done
mofa_run t_show_args
mofa_assert_eq "$(t_expect reinstall "$DOWNLOAD_URL_TEAMS" 3 900 20 3 true)" "$(t_settings)" "no arguments keep MODE=reinstall"
mofa_run t_show_args MODE=reset
mofa_assert_eq "$(t_expect reset "$DOWNLOAD_URL_TEAMS" 3 900 20 3 true)" "$(t_settings)" "arguments without the Jamf prefix are parsed"
mofa_assert_not_contains "$MOFA_STDOUT" "Shifting" "nothing is shifted without the Jamf prefix"
mofa_run t_show_args / computer alice "" "" MODE=reset "" ""
mofa_assert_eq "$(t_expect reset "$DOWNLOAD_URL_TEAMS" 3 900 20 3 true)" "$(t_settings)" "empty Jamf parameters are skipped"
mofa_run t_show_args / MODE=bogus BOGUS=1 MODE=reset
mofa_assert_eq "$(t_expect reset "$DOWNLOAD_URL_TEAMS" 3 900 20 3 true)" "$(t_settings)" "parameters 1-3 are discarded"
mofa_assert_not_contains "$MOFA_STDOUT" "Ignoring" "parameters 2 and 3 are not parsed"
mofa_run t_show_args / computer alice bogus
mofa_assert_eq "$(t_expect reinstall "$DOWNLOAD_URL_TEAMS" 3 900 20 3 true)" "$(t_settings)" "a stray word without = is ignored"
mofa_assert_not_contains "$MOFA_STDOUT" "Ignoring" "a stray word is ignored silently"

t_case "parse_arguments ignores keys outside the allow list"
mofa_run t_show_args / computer alice PATH=/tmp HOME=/ LOG_FILE=/tmp/mofa_test.log EXPECTED_APP_PATH=/ \
	USER_HOMES_DIR=/ mode=reset
mofa_assert_eq "$(t_expect reinstall "$DOWNLOAD_URL_TEAMS" 3 900 20 3 true)" "$(t_settings)" "no other variable can be set"
for key in PATH HOME LOG_FILE EXPECTED_APP_PATH USER_HOMES_DIR mode; do
	mofa_assert_contains "$MOFA_STDOUT" "Ignoring unsupported argument: ${key}" "${key} is ignored with a warning"
done

t_case "parse_arguments never evaluates a value"
mofa_run t_show_args / computer alice 'DOWNLOAD_URL_TEAMS=$(/usr/bin/touch /tmp/mofa_test_eval)' 'CLEAN_ALL_USERS=`id`'
mofa_assert_eq "$(t_expect reinstall '$(/usr/bin/touch /tmp/mofa_test_eval)' 3 900 20 3 '`id`')" "$(t_settings)" "values are stored literally"
mofa_assert_not_called /usr/bin/touch "a command substitution in a value is not run"

t_case "parse_arguments exits 2 for an unsupported MODE"
for raw in MODE=bogus "MODE=" "MODE=reset;rm" 'MODE=$(echo reset)' "MODE=delete"; do
	mofa_run t_show_args / computer alice "$raw"
	mofa_assert_status 2 "'${raw}' exits 2"
	mofa_assert_contains "$MOFA_STDOUT" "ERROR: Unsupported MODE" "'${raw}' explains the failure"
	mofa_assert_eq "" "$(t_settings)" "'${raw}' does not continue"
done
t_assert_no_system_calls "an invalid MODE runs no system command"

t_case "main reads its settings from the Jamf parameters and validates them before touching the system"
mofa_run t_main_flow / computer alice MODE=bogus
mofa_assert_status 2 "main exits 2 for an unsupported MODE"
t_assert_no_system_calls "an invalid MODE stops before any system command"
t_calls=("${(@f)$(mofa_calls)}")
mofa_assert_eq "t_logging_probe" "${t_calls[1]}" "logging starts before arguments are parsed"
mofa_assert_eq "t_cleanup_probe" "${t_calls[-1]}" "the EXIT trap still runs"

t_case "main refuses to run without root"
mofa_run t_main_unprivileged / computer alice MODE=reset
mofa_assert_status 1 "main exits 1 when not root"
mofa_assert_contains "$MOFA_STDOUT" "Beginning Microsoft Teams reset (script version: 1.2.0)." "the start banner precedes the root check"
mofa_assert_contains "$MOFA_STDOUT" "ERROR: This script must be run as root." "root check message"
t_assert_no_system_calls "nothing runs before the root check"
mofa_run t_main_unprivileged / computer alice MODE=bogus
mofa_assert_status 2 "arguments are still validated before the root check"

t_case "main sets PIPE_FAIL before it starts logging"
mofa_run t_main_options / computer alice MODE=bogus
mofa_assert_status 2 "the probe run stops at the invalid MODE"
mofa_assert_contains "$MOFA_STDOUT" "PIPE_FAIL=on" "pipelines fail when any command in them fails"

# --- Console user and home folder -----------------------------------------------------
t_case "GetLoggedInUser ignores root, _mbsetupuser and the login window"
mofa_stub_passthrough /usr/bin/awk
for console expected in "  Name : alice" alice "  Name : root" "" "  Name : _mbsetupuser" "" "  Name : loginwindow" "" "" ""; do
	mofa_stub /usr/sbin/scutil 0 "$console"
	mofa_assert_eq "$expected" "$(GetLoggedInUser)" "console '${console}' gives '${expected}'"
done

t_case "SetHomeFolder without a console user uses /var/empty"
mofa_capture SetHomeFolder ""
mofa_assert_status 0 "SetHomeFolder '' succeeds"
mofa_assert_eq "/var/empty" "$HOME" "HOME is /var/empty"
mofa_assert_eq "" "$LoggedInUserID" "no user ID"
mofa_assert_not_called /usr/bin/dscl "no directory lookup without a user"

t_case "SetHomeFolder reads the directory home and user ID"
mofa_stub /usr/bin/dscl 0 "NFSHomeDirectory: ${T_HOME}"
mofa_stub_passthrough /usr/bin/awk
mofa_stub /usr/bin/id 0 "501"
mofa_capture SetHomeFolder alice
mofa_assert_status 0 "SetHomeFolder alice succeeds"
mofa_assert_eq "$T_HOME" "$HOME" "HOME is the directory record's home"
mofa_assert_eq "501" "$LoggedInUserID" "the user ID comes from id -u"
mofa_assert_called /usr/bin/dscl . -read /Users/alice NFSHomeDirectory
mofa_assert_called /usr/bin/id -u alice

t_case "SetHomeFolder without a home record uses /var/empty"
mofa_stub /usr/bin/dscl 56
mofa_stub_passthrough /usr/bin/awk
mofa_capture SetHomeFolder "mofa_no_such_user_$$"
mofa_assert_status 1 "SetHomeFolder returns 1"
mofa_assert_eq "/var/empty" "$HOME" "HOME falls back to /var/empty"
mofa_assert_eq "" "$LoggedInUserID" "no user ID"
mofa_assert_not_called /usr/bin/id "no user ID is looked up"

t_case "home_cleanup_allowed accepts only existing homes under /Users"
mofa_mkdir "$T_HOME" "$T_USERS/Shared" "$T_DIR/outside/bob"
if home_cleanup_allowed "$T_HOME"; then
	mofa_pass "an existing home under the users folder is allowed"
else
	mofa_fail "an existing home under the users folder is allowed"
fi
for bad in "" "/" "$T_USERS" "$T_USERS/" "$T_USERS/Shared" "$T_USERS/shared" "$T_USERS/SHARED" "$T_HOME/" \
	"$T_USERS//alice" "$T_USERS/./alice" "$T_USERS/../outside/bob" "$T_USERS/missing" "$T_DIR/outside/bob" "/var/empty"; do
	if home_cleanup_allowed "$bad"; then
		mofa_fail "home_cleanup_allowed rejects '${bad}'"
	else
		mofa_pass "home_cleanup_allowed rejects '${bad}'"
	fi
done
USER_HOMES_DIR="/Users"
for bad in "/Users" "/Users/" "/Users/Shared" "/var/root" "/private/var/root" "/var/empty" "/Users/../var/root" "$T_HOME"; do
	if home_cleanup_allowed "$bad"; then
		mofa_fail "with the real /Users, home_cleanup_allowed rejects '${bad}'"
	else
		mofa_pass "with the real /Users, home_cleanup_allowed rejects '${bad}'"
	fi
done
t_assert_no_system_calls "home checks run no command"

t_case "run_reset requires a console user with a home under /Users"
mofa_run run_reset
mofa_assert_status 1 "no console user exits 1"
mofa_assert_contains "$MOFA_STDOUT" "A valid logged-in user with a /Users home is required for MODE=reset; no changes were made." "the refusal is logged"
LoggedInUser=alice
LoggedInUserID=501
mofa_mkdir "$T_DIR/outside/alice"
HOME="$T_DIR/outside/alice"
mofa_run run_reset
mofa_assert_status 1 "a home outside /Users exits 1"
t_assert_no_system_calls "nothing is changed without an eligible home"

t_case "main with root, _mbsetupuser or the login window at the console uses /var/empty and changes nothing"
mofa_stub_passthrough /usr/bin/awk
for console in "  Name : root" "  Name : _mbsetupuser" "  Name : loginwindow" ""; do
	mofa_reset_calls
	mofa_stub /usr/sbin/scutil 0 "$console"
	mofa_run t_main_real_home / computer alice MODE=reset
	mofa_assert_status 1 "console '${console}' exits 1 in reset mode"
	mofa_assert_contains "$MOFA_STDOUT" "Console user: none; Home Folder: /var/empty; Mode: reset" "console '${console}' gives HOME=/var/empty"
	mofa_assert_contains "$MOFA_STDOUT" "A valid logged-in user with a /Users home is required for MODE=reset; no changes were made." "console '${console}' is refused"
	mofa_assert_not_called /usr/bin/dscl "console '${console}' looks up no home"
	mofa_assert_not_called /bin/rm "console '${console}' removes nothing"
	mofa_assert_not_called /usr/bin/pkill "console '${console}' stops nothing"
done

t_case "main refuses MODE=reset when the console user's home is outside /Users"
mofa_stub /usr/sbin/scutil 0 "  Name : alice"
mofa_stub_passthrough /usr/bin/awk
mofa_stub /usr/bin/dscl 0 "NFSHomeDirectory: /private/var/x"
mofa_stub /usr/bin/id 0 "501"
mofa_run t_main_real_home / computer alice MODE=reset
mofa_assert_status 1 "a home outside /Users exits 1"
mofa_assert_contains "$MOFA_STDOUT" "Console user: alice; Home Folder: /private/var/x; Mode: reset" "the directory home is reported"
mofa_assert_contains "$MOFA_STDOUT" "A valid logged-in user with a /Users home is required for MODE=reset; no changes were made." "the refusal is logged"
mofa_assert_called /usr/bin/dscl . -read /Users/alice NFSHomeDirectory
mofa_assert_not_called /bin/rm "nothing is removed"
mofa_assert_not_called /usr/bin/pkill "Teams keeps running"
mofa_assert_not_called /bin/launchctl "nothing runs as the user"

# --- Removal wrapper ------------------------------------------------------------------
t_case "remove_path refuses root and relative targets"
mofa_mkdir "$MOFA_TEST_ROOT/relative/target"
for bad in "/" "relative/target" "." ".."; do
	CLEANUP_FAILURES=0
	mofa_capture remove_path "$bad"
	mofa_assert_status 1 "remove_path refuses '${bad}'"
	mofa_assert_eq 1 "$CLEANUP_FAILURES" "refusing '${bad}' counts as a cleanup failure"
	mofa_assert_contains "$MOFA_STDOUT" "Refusing to remove unsafe path: ${bad}" "refusing '${bad}' is logged"
done
CLEANUP_FAILURES=0
mofa_capture remove_path ""
mofa_assert_status 0 "an empty target is skipped"
mofa_capture remove_path "$T_DIR/missing"
mofa_assert_status 0 "a missing target is skipped"
mofa_assert_eq 0 "$CLEANUP_FAILURES" "skipped targets are not failures"
mofa_assert_not_called /bin/rm "rm never runs for an unsafe or missing target"

t_case "remove_path calls rm with -- and the exact path, and counts failures"
target="$T_HOME/Library/Group Containers/UBF8T346G9.com.microsoft.teams"
mofa_mkdir "$target"
mofa_capture remove_path "$target"
mofa_assert_status 0 "remove_path succeeds"
mofa_assert_called /bin/rm -rf -- "$target"
mofa_assert_contains "$MOFA_STDOUT" "Removed ${target}" "the removal is logged"
mofa_assert_eq 0 "$CLEANUP_FAILURES" "no failure counted"
[[ -d "$target" ]] && mofa_pass "the stub did not delete anything" || mofa_fail "the stub did not delete anything"
t_symlink "$T_DIR/missing-target" "$T_DIR/dangling"
mofa_capture remove_path "$T_DIR/dangling"
mofa_assert_called /bin/rm -rf -- "$T_DIR/dangling"
mofa_stub /bin/rm 1
mofa_capture remove_path "$target"
mofa_assert_eq 1 "$CLEANUP_FAILURES" "a failed rm is counted"
mofa_assert_contains "$MOFA_STDOUT" "WARN: Failed to remove ${target}" "a failed rm is logged"

t_case "cleanup removes only the script's own working folders"
mofa_mkdir "$T_WORK" "$T_STAGE"
TEMP_DIR="$T_WORK"
BACKGROUND_BACKUP_DIR="$T_STAGE"
mofa_capture cleanup
mofa_assert_called /bin/rm -rf -- "$T_WORK"
mofa_assert_called /bin/rm -rf -- "$T_STAGE"
mofa_reset_calls
TEMP_DIR=""
BACKGROUND_BACKUP_DIR="$T_DIR/missing"
mofa_capture cleanup
mofa_assert_not_called /bin/rm "unset or missing folders are not removed"

# --- Per-user cleanup -----------------------------------------------------------------
t_case "cleanup_user_paths removes the listed Teams data and nothing else"
t_make_teams_data "$T_HOME"
mofa_capture cleanup_user_paths alice "$T_HOME"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Containers/com.microsoft.teams2"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Caches/com.microsoft.teams2"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Preferences/com.microsoft.teams2.plist"
mofa_assert_eq 3 "$(mofa_call_count /bin/rm)" "only existing Teams paths are removed"
mofa_assert_not_contains "$(t_rm_targets)" "com.microsoft.Outlook" "other apps' data is kept"

t_case "cleanup_user_paths skips exempt homes"
mofa_mkdir "$T_USERS/Shared/Library/Caches/com.microsoft.teams2" "$T_DIR/outside/bob/Library/Caches/com.microsoft.teams2"
for home in "$T_USERS/Shared" "$T_DIR/outside/bob" "/var/empty" "/" "" "$T_USERS"; do
	mofa_capture cleanup_user_paths someone "$home"
	mofa_assert_contains "$MOFA_STDOUT" "Skipping cleanup for unsafe or unavailable home path" "home '${home}' is skipped"
done
mofa_assert_not_called /bin/rm "nothing is removed from an exempt home"

t_case "cleanup_target_users cleans every eligible user and never touches exempt homes"
t_make_teams_data "$T_HOME"
t_make_teams_data "$T_USERS/bob"
t_make_teams_data "$T_USERS/Shared"
t_make_teams_data "$T_DIR/outside/outsider"
T_DSCL_LIST=$'_mbsetupuser 248\nroot 0\nnobody -2\nalice 501\nbob 502\nshared 503\nemptyhome 504\noutsider 505\ndotdot 506\nusersroot 507\nslashhome 508\nmofa_ghost_'$$' 509'
T_DSCL_HOMES=(
	root /var/root
	_mbsetupuser /var/setup
	alice "$T_HOME"
	bob "$T_USERS/bob"
	shared "$T_USERS/Shared"
	emptyhome /var/empty
	outsider "$T_DIR/outside/outsider"
	dotdot "$T_USERS/../outside/outsider"
	usersroot "$T_USERS"
	slashhome /
)
mofa_stub_handler /usr/bin/dscl t_fake_dscl
mofa_stub_passthrough /usr/bin/awk
mofa_run cleanup_target_users
mofa_assert_status 0 "cleanup_target_users succeeds"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Containers/com.microsoft.teams2"
mofa_assert_called /bin/rm -rf -- "$T_USERS/bob/Library/Containers/com.microsoft.teams2"
t_assert_rm_only_under "rm only touches alice's and bob's homes" "$T_HOME" "$T_USERS/bob"
mofa_assert_eq 6 "$(mofa_call_count /bin/rm)" "three Teams paths are removed for each of the two users"
for skipped in shared emptyhome outsider dotdot usersroot slashhome "mofa_ghost_$$"; do
	mofa_assert_contains "$MOFA_STDOUT" "Skipping cleanup for unsafe or unavailable home path: ${skipped} ->" "${skipped} is skipped"
done
for system_user in root _mbsetupuser nobody; do
	mofa_assert_not_contains "$(mofa_calls /usr/bin/dscl)" "/Users/${system_user} " "${system_user}'s home is never looked up"
done
mofa_assert_contains "$MOFA_STDOUT" "No logged-in user detected; skipping TCC and keychain cleanup." "no console user means no keychain work"

t_case "cleanup_target_users with CLEAN_ALL_USERS=false cleans only the console user"
t_make_teams_data "$T_HOME"
t_make_teams_data "$T_USERS/bob"
mofa_stub_handler /usr/bin/dscl t_fake_dscl
CLEAN_ALL_USERS=false
LoggedInUser=alice
HOME="$T_HOME"
mofa_run cleanup_target_users
t_assert_rm_only_under "only the console user's home is cleaned" "$T_HOME"
mofa_assert_not_called /usr/bin/dscl "other users are not listed"
LoggedInUser=""
mofa_reset_calls
mofa_run cleanup_target_users
mofa_assert_contains "$MOFA_STDOUT" "no user data was removed" "no console user means no user data is removed"
mofa_assert_not_called /bin/rm "nothing is removed without a console user"

t_case "cleanup_logged_in_user_security_state works in the user's context"
LoggedInUser=alice
LoggedInUserID=501
HOME="$T_HOME"
T_KEYCHAINS='    "/Users/alice/Library/Keychains/other.keychain-db"'
T_FIND_HITS=1
mofa_stub_handler /bin/launchctl t_fake_launchctl
mofa_stub_passthrough /usr/bin/sed
mofa_run cleanup_logged_in_user_security_state
mofa_assert_status 0 "security cleanup succeeds"
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/tccutil reset All com.microsoft.teams2
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/security list-keychains -d user -s "$T_HOME/Library/Keychains/login.keychain-db" /Users/alice/Library/Keychains/other.keychain-db
t_deletes=(${(M)${(f)"$(mofa_calls /bin/launchctl)"}:#*delete-generic-password -l*Identities Cache*})
mofa_assert_eq 1 "${#t_deletes}" "the identities cache item is deleted once per match"
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/security delete-generic-password -l teamsKey
mofa_assert_not_called /usr/bin/security "nothing touches the keychain as root"
mofa_assert_not_called /usr/bin/tccutil "TCC is not reset as root"

t_case "cleanup_user_temp_paths accepts only the user's /var/folders temp folder"
LoggedInUser=alice
LoggedInUserID=501
mofa_stub_handler /bin/launchctl t_fake_launchctl
for T_USER_TMP in "/tmp/" "/Users/alice" "/" ""; do
	mofa_capture cleanup_user_temp_paths
done
mofa_assert_not_called /bin/rm "no temp folder outside /var/folders is cleaned"
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/getconf DARWIN_USER_TEMP_DIR
LoggedInUser=""
mofa_reset_calls
mofa_capture cleanup_user_temp_paths
mofa_assert_status 0 "no console user is not an error"
mofa_assert_not_called /bin/launchctl "without a console user the temp folder is never looked up"
LoggedInUser=alice
if [[ "$MOFA_TEST_ROOT" == /private/var/folders/?* ]]; then
	T_USER_TMP="$T_DIR/T"
	mofa_mkdir "$T_USER_TMP/com.microsoft.teams2" "$T_USER_TMP/v8-compile-cache-501"
	for reported in "${T_USER_TMP}/" "${${T_USER_TMP}#/private}/"; do
		mofa_reset_calls
		T_USER_TMP="$reported"
		mofa_capture cleanup_user_temp_paths
		mofa_assert_called /bin/rm -rf -- "${reported%/}/com.microsoft.teams2"
		mofa_assert_called /bin/rm -rf -- "${reported%/}/v8-compile-cache-501"
	done
	# A failed lookup is not trusted, even when it printed a /var/folders path.
	mofa_reset_calls
	mofa_stub /bin/launchctl 1 "$T_DIR/T/"
	mofa_capture cleanup_user_temp_paths
	mofa_assert_status 0 "a failed temp folder lookup is not an error"
	mofa_assert_not_called /bin/rm "a failed temp folder lookup removes nothing"
else
	print -r -- "# skip: the sandbox is not under /private/var/folders, so the accepted-path case cannot run"
fi

t_case "terminate_teams_processes stops every Teams process"
mofa_stub /usr/bin/pkill 1
mofa_capture terminate_teams_processes
mofa_assert_status 0 "no running process is not an error"
mofa_assert_eq 8 "$(mofa_call_count /usr/bin/pkill)" "eight process names are stopped"
mofa_assert_called /usr/bin/pkill -9 "Microsoft Teams"
mofa_assert_called /usr/bin/pkill -9 MSTeams
mofa_assert_called /usr/bin/pkill -9 com.microsoft.teams2.notificationcenter

t_case "cleanup_system_paths keeps the installed app only in reset mode"
mofa_run t_list_system_paths keep_app
mofa_assert_not_contains "$(mofa_calls t_remove_probe)" "'/Applications/Microsoft Teams.app'" "reset mode does not remove the current app"
mofa_assert_not_contains "$(mofa_calls t_remove_probe)" "(work preview).app" "reset mode keeps the preview app"
mofa_assert_called t_remove_probe "/Applications/Microsoft Teams classic.app"
mofa_assert_called t_remove_probe "/Library/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist"
mofa_assert_called t_bootout_probe system "/Library/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist"
mofa_reset_calls
mofa_run t_list_system_paths
mofa_assert_called t_remove_probe "/Applications/Microsoft Teams.app"
mofa_assert_called t_remove_probe "/Applications/Microsoft Teams (work preview).app"

t_case "bootoutJob falls back to unload and skips missing jobs"
plist="$T_DIR/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist"
mofa_capture bootoutJob system "$plist"
mofa_assert_not_called /bin/launchctl "a missing job is skipped"
mofa_write_file "$plist" "plist"
mofa_capture bootoutJob system "$plist"
mofa_assert_called /bin/launchctl bootout system "$plist"
mofa_assert_not_contains "$(mofa_calls /bin/launchctl)" " unload " "no unload after a successful bootout"
mofa_stub /bin/launchctl 5
mofa_capture bootoutJob system "$plist"
mofa_assert_status 0 "a failed bootout is not fatal"
mofa_assert_called /bin/launchctl unload "$plist"

# --- Teams backgrounds ------------------------------------------------------------------
t_case "backup_teams_backgrounds copies the folder as the console user, never as root"
LoggedInUser=alice
LoggedInUserID=501
HOME="$T_HOME"
mofa_write_file "$T_BG/custom.png" "png"
mofa_mkdir "$T_STAGE"
t_setup_console_user
mofa_run backup_teams_backgrounds
mofa_assert_status 0 "the backup succeeds"
mofa_assert_called /usr/bin/mktemp -d /private/var/tmp/mofa-teams-backgrounds.XXXXXX
mofa_assert_called /usr/sbin/chown alice "$T_STAGE"
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/ditto "$T_BG" "$T_STAGE/Backgrounds"
mofa_assert_called_before /usr/sbin/chown /bin/launchctl "the staging folder belongs to the user before the copy"
mofa_assert_not_called /usr/bin/ditto "ditto never runs as root"
mofa_assert_contains "$MOFA_STDOUT" "Staged custom Teams backgrounds for alice." "the backup is logged"

t_case "backup_teams_backgrounds skips a symlinked Backgrounds folder"
LoggedInUser=alice
LoggedInUserID=501
HOME="$T_HOME"
mofa_write_file "$T_DIR/elsewhere/secret.txt" "secret"
t_symlink "$T_DIR/elsewhere" "$T_BG"
t_setup_console_user
mofa_run backup_teams_backgrounds
mofa_assert_status 0 "a symlinked folder is not an error"
mofa_assert_contains "$MOFA_STDOUT" "the Backgrounds folder is a symbolic link" "the skip is logged"
mofa_assert_not_called /usr/bin/mktemp "no staging folder is created"
mofa_assert_not_called /usr/bin/ditto "nothing is copied as root"
mofa_assert_not_called /bin/launchctl "nothing is copied as the user"

t_case "backup_teams_backgrounds stops the run when the copy fails"
LoggedInUser=alice
LoggedInUserID=501
HOME="$T_HOME"
mofa_write_file "$T_BG/custom.png" "png"
mofa_mkdir "$T_STAGE"
t_setup_console_user
T_DITTO_STATUS=1
mofa_run backup_teams_backgrounds
mofa_assert_status 1 "a failed user-context copy exits 1"
mofa_assert_contains "$MOFA_STDOUT" "Unable to back up Teams backgrounds; no changes were made." "the failure is logged"
T_DITTO_STATUS=0
mofa_stub /usr/sbin/chown 1
mofa_reset_calls
mofa_run backup_teams_backgrounds
mofa_assert_status 1 "a failed ownership change exits 1"
mofa_assert_not_called /bin/launchctl "nothing is copied when the staging folder cannot be handed to the user"
LoggedInUser=""
mofa_reset_calls
mofa_run backup_teams_backgrounds
mofa_assert_status 0 "no console user skips the backup"
t_assert_no_system_calls "nothing runs without a console user"

t_case "restore_teams_backgrounds copies into a new folder in the home as the user"
LoggedInUser=alice
LoggedInUserID=501
HOME="$T_HOME"
BACKGROUND_BACKUP_DIR="$T_STAGE"
mofa_write_file "$T_STAGE/Backgrounds/custom.png" "png"
mofa_mkdir "$T_HOME/Teams_Backgrounds_Backup"
mofa_stub_handler /bin/launchctl t_fake_launchctl
mofa_capture restore_teams_backgrounds
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/ditto "$T_STAGE/Backgrounds" "$T_HOME/Teams_Backgrounds_Backup1"
mofa_assert_not_called /usr/bin/ditto "the restore never copies as root"
mofa_assert_not_called /usr/sbin/chown "the user's own copy needs no ownership change"
mofa_assert_eq 0 "$CLEANUP_FAILURES" "a successful restore is not a failure"
mofa_assert_contains "$MOFA_STDOUT" "Custom Teams backgrounds were saved to ${T_HOME}/Teams_Backgrounds_Backup1." "the destination is logged"
T_DITTO_STATUS=1
mofa_capture restore_teams_backgrounds
mofa_assert_eq 1 "$CLEANUP_FAILURES" "a failed restore is counted"

# --- Download, verification and install -----------------------------------------------
t_case "download_pkg passes the URL to curl after --"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_capture download_pkg
mofa_assert_status 0 "the download succeeds"
mofa_assert_eq "$T_WORK/MicrosoftTeams.pkg" "$PKG_PATH" "the package is saved in the private folder"
mofa_assert_called /usr/bin/curl --fail --silent --show-error --location --connect-timeout 30 --retry 5 --retry-delay 10 \
	--max-time 900 --output "$T_WORK/MicrosoftTeams.pkg" -- "https://go.microsoft.com/fwlink/?linkid=2249065"
DOWNLOAD_URL_TEAMS="--config=/tmp/mofa_test_curlrc"
DOWNLOAD_TIMEOUT=60
mofa_capture download_pkg
mofa_assert_called /usr/bin/curl --fail --silent --show-error --location --connect-timeout 30 --retry 5 --retry-delay 10 \
	--max-time 60 --output "$T_WORK/MicrosoftTeams.pkg" -- "--config=/tmp/mofa_test_curlrc"

t_case "download_pkg fails on a curl error, an empty file or no private folder"
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_stub /usr/bin/curl 22
mofa_capture download_pkg
mofa_assert_status 1 "a failed download returns 1"
mofa_assert_contains "$MOFA_STDOUT" "Failed to download Microsoft Teams package" "the failure is logged"
mofa_stub /usr/bin/curl 0
: >| "$T_WORK/MicrosoftTeams.pkg"
mofa_capture download_pkg
mofa_assert_status 1 "an empty download returns 1"
mofa_assert_contains "$MOFA_STDOUT" "Downloaded package is empty" "the empty download is logged"
mofa_stub /usr/bin/mktemp 1
mofa_reset_calls
mofa_capture download_pkg
mofa_assert_status 1 "no private folder returns 1"
mofa_assert_not_called /usr/bin/curl "nothing is downloaded without a private folder"

t_case "verify_pkg_signature requires Microsoft's installer certificate and Gatekeeper"
mofa_mkdir "$T_WORK"
PKG_PATH="$T_WORK/MicrosoftTeams.pkg"
mofa_stub /usr/sbin/pkgutil 0 "$T_SIGNED_BY_OTHER"
mofa_stub /usr/sbin/spctl 0
mofa_capture verify_pkg_signature
mofa_assert_status 1 "a non-Microsoft team ID fails"
mofa_assert_contains "$MOFA_STDOUT" "Downloaded package was not signed by Microsoft Corporation (UBF8T346G9)." "the mismatch is logged"
mofa_assert_called /usr/sbin/pkgutil --check-signature "$PKG_PATH"
mofa_assert_not_called /usr/sbin/spctl "Gatekeeper is not consulted after a signer mismatch"
mofa_stub /usr/sbin/pkgutil 1 "$T_SIGNED_BY_MICROSOFT"
mofa_capture verify_pkg_signature
mofa_assert_status 1 "a failing pkgutil check fails"
mofa_stub /usr/sbin/pkgutil 0 $'Package "MicrosoftTeams.pkg":\n   Status: no signature'
mofa_capture verify_pkg_signature
mofa_assert_status 1 "an unsigned package fails"
mofa_assert_not_called /usr/sbin/spctl "Gatekeeper is only consulted for a Microsoft-signed package"
mofa_stub /usr/sbin/pkgutil 0 "$T_SIGNED_BY_MICROSOFT"
mofa_capture verify_pkg_signature
mofa_assert_status 0 "a Microsoft-signed package that Gatekeeper accepts passes"
mofa_assert_called /usr/sbin/spctl -a -t install "$PKG_PATH"
mofa_stub /usr/sbin/spctl 3
mofa_capture verify_pkg_signature
mofa_assert_status 1 "a Gatekeeper rejection fails"
mofa_assert_contains "$MOFA_STDOUT" "Gatekeeper rejected the downloaded Microsoft Teams package." "the rejection is logged"

t_case "run_reinstall changes nothing until the package is verified"
mofa_mkdir "$T_APP"
LoggedInUser=alice
LoggedInUserID=501
HOME="$T_HOME"
mofa_write_file "$T_BG/custom.png" "png"
t_make_teams_data "$T_HOME"
for scenario in download signer gatekeeper macos; do
	t_setup_download "$T_SIGNED_BY_MICROSOFT"
	case "$scenario" in
		download) mofa_stub /usr/bin/curl 22 ;;
		signer) mofa_stub /usr/sbin/pkgutil 0 "$T_SIGNED_BY_OTHER" ;;
		gatekeeper) mofa_stub /usr/sbin/spctl 3 ;;
		macos) mofa_stub /usr/bin/sw_vers 0 "12.7.6" ;;
	esac
	mofa_reset_calls
	mofa_run run_reinstall
	mofa_assert_status 1 "a ${scenario} failure exits 1"
	mofa_assert_not_called /usr/bin/pkill "a ${scenario} failure leaves Teams running"
	mofa_assert_not_called /bin/rm "a ${scenario} failure removes nothing"
	mofa_assert_not_called /usr/sbin/installer "a ${scenario} failure installs nothing"
	mofa_assert_not_called /bin/launchctl "a ${scenario} failure does not back up or touch user data"
done
mofa_assert_contains "$MOFA_STDOUT" "reinstall requires macOS 13.0 or newer. Detected macOS 12.7.6." "an old macOS is refused"
mofa_assert_not_called /usr/bin/curl "nothing is downloaded on an unsupported macOS"

t_case "install_teams retries, removes a failed install and checks the team ID"
PKG_PATH="$T_WORK/MicrosoftTeams.pkg"
INSTALLATION_RETRIES=2
t_setup_healthy_app
mofa_stub /usr/sbin/installer 1
mofa_capture install_teams
mofa_assert_status 1 "every attempt failing returns 1"
mofa_assert_eq 2 "$(mofa_call_count /usr/sbin/installer)" "the installer is retried"
mofa_assert_eq 2 "$(mofa_call_count /bin/rm)" "the app is removed after each failed attempt"
mofa_assert_called /bin/rm -rf -- "$T_APP"
mofa_assert_contains "$MOFA_STDOUT" "installer returned a non-zero status on attempt 2" "the failure is logged"
mofa_reset_calls
INSTALLATION_RETRIES=1
WAIT_ATTEMPTS=2
WAIT_DELAY=0
mofa_stub /usr/sbin/installer 0
mofa_stub /usr/bin/codesign 0 "TeamIdentifier=ABCDE12345"
mofa_capture install_teams
mofa_assert_status 1 "an app from another team is not healthy"
mofa_assert_eq 2 "$(mofa_call_count /bin/sleep)" "health is polled WAIT_ATTEMPTS times"
mofa_assert_called /bin/sleep 0
mofa_assert_contains "$MOFA_STDOUT" "did not become healthy in time" "the unhealthy app is logged"
mofa_reset_calls
mofa_stub /usr/bin/codesign 0 "TeamIdentifier=UBF8T346G9"
mofa_capture install_teams
mofa_assert_status 0 "a healthy Microsoft-signed app passes"
mofa_assert_called /usr/sbin/installer -pkg "$PKG_PATH" -target /
mofa_assert_not_called /bin/sleep "no wait for an app that is already healthy"
mofa_assert_contains "$MOFA_STDOUT" "installed successfully. Bundle ID: 24295.605.3225.8804; Version: 24295.605.3225.8804" "the installed app is logged"

# --- Exit status ----------------------------------------------------------------------
t_case "finish exits nonzero after a cleanup failure"
CLEANUP_FAILURES=2
MODE=reset
mofa_run finish
mofa_assert_status 1 "finish exits 1"
mofa_assert_contains "$MOFA_STDOUT" "ERROR: Microsoft Teams reset completed with 2 cleanup failure(s)." "the failure count is logged"
CLEANUP_FAILURES=0
mofa_run finish
mofa_assert_status 0 "finish exits 0 without failures"

# --- End-to-end flows with every command stubbed -----------------------------------------
t_case "main reset flow removes the console user's Teams data and keeps the app"
mofa_mkdir "$T_APP" "$T_STAGE" "$T_HOME/Library/Group Containers/UBF8T346G9.com.microsoft.oneauth"
t_make_teams_data "$T_HOME"
mofa_write_file "$T_BG/custom.png" "png"
t_setup_console_user
mofa_run t_main_flow / computer alice MODE=reset
mofa_assert_status 0 "the reset flow exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Beginning Microsoft Teams reset (script version: 1.2.0)." "the start banner is logged"
mofa_assert_contains "$MOFA_STDOUT" "Console user: alice; Home Folder: ${T_HOME}; Mode: reset; Clean all users: true" "the run context is logged"
mofa_assert_called /usr/bin/pkill -9 "Microsoft Teams"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Containers/com.microsoft.teams2"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Group Containers/UBF8T346G9.com.microsoft.oneauth"
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/ditto "$T_BG" "$T_STAGE/Backgrounds"
mofa_assert_called /bin/launchctl asuser 501 /usr/bin/sudo -H -u alice /usr/bin/ditto "$T_STAGE/Backgrounds" "$T_HOME/Teams_Backgrounds_Backup"
mofa_assert_called_before /bin/launchctl /usr/bin/pkill "backgrounds are staged before Teams is stopped"
mofa_assert_called_before /usr/bin/pkill /bin/rm "Teams is stopped before its data is removed"
t_assert_no_rm_under "the installed app is kept" "/Applications/Microsoft Teams.app" "$T_APP"
mofa_assert_not_contains "$(t_rm_targets)" "com.microsoft.Outlook" "other apps' data is kept"
mofa_assert_not_called /usr/bin/curl "reset mode downloads nothing"
mofa_assert_not_called /usr/sbin/installer "reset mode installs nothing"
mofa_assert_not_called /usr/bin/dscl "reset mode does not list other users"
mofa_assert_not_called /usr/bin/ditto "nothing is copied as root"
mofa_assert_contains "$MOFA_STDOUT" "Microsoft Teams reset completed." "completion is logged"
t_calls=("${(@f)$(mofa_calls)}")
mofa_assert_eq "t_logging_probe" "${t_calls[1]}" "logging starts first"
mofa_assert_eq "t_cleanup_probe" "${t_calls[-1]}" "the EXIT trap cleans up after main finishes, not before"

t_case "main reset flow exits 1 when a removal fails"
mofa_mkdir "$T_APP"
t_make_teams_data "$T_HOME"
t_setup_console_user
mofa_stub /bin/rm 1
mofa_run t_main_flow / computer alice MODE=reset
mofa_assert_status 1 "a removal failure is reported to Jamf"
mofa_assert_contains "$MOFA_STDOUT" "cleanup failure(s)" "the failure count is logged"

t_case "main reinstall flow keeps everything when the download fails"
mofa_mkdir "$T_APP"
t_make_teams_data "$T_HOME"
t_setup_console_user
t_setup_download "$T_SIGNED_BY_MICROSOFT"
mofa_stub /usr/bin/curl 22
mofa_run t_main_flow / computer alice
mofa_assert_status 1 "a failed download exits 1"
mofa_assert_not_called /bin/rm "nothing is removed"
mofa_assert_not_called /usr/bin/pkill "Teams keeps running"
mofa_assert_not_called /usr/sbin/installer "nothing is installed"
mofa_assert_called_before /usr/bin/curl t_cleanup_probe "the EXIT trap cleans up after a failure exit"

t_case "main reinstall flow verifies, cleans every eligible user, then installs"
t_make_teams_data "$T_HOME"
t_make_teams_data "$T_USERS/bob"
t_make_teams_data "$T_USERS/Shared"
mofa_write_file "$T_BG/custom.png" "png"
T_DSCL_LIST=$'alice 501\nbob 502\nshared 503'
T_DSCL_HOMES=(alice "$T_HOME" bob "$T_USERS/bob" shared "$T_USERS/Shared")
t_setup_console_user
t_setup_download "$T_SIGNED_BY_MICROSOFT"
t_setup_healthy_app
mofa_stub_handler /usr/bin/dscl t_fake_dscl
mofa_run t_main_flow / computer alice "" MODE=reinstall
mofa_assert_status 0 "a successful reinstall exits 0"
mofa_assert_contains "$MOFA_STDOUT" "Console user: alice; Home Folder: ${T_HOME}; Mode: reinstall; Clean all users: true" "the run context is logged"
mofa_assert_called /usr/sbin/spctl -a -t install "$T_WORK/MicrosoftTeams.pkg"
mofa_assert_called /bin/rm -rf -- "$T_HOME/Library/Containers/com.microsoft.teams2"
mofa_assert_called /bin/rm -rf -- "$T_USERS/bob/Library/Containers/com.microsoft.teams2"
t_assert_no_rm_under "the shared home is never cleaned" "$T_USERS/Shared"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/MicrosoftTeams.pkg" -target /
mofa_assert_called_before /usr/sbin/spctl /usr/bin/pkill "the package is verified before Teams is stopped"
mofa_assert_called_before /usr/sbin/spctl /bin/rm "the package is verified before anything is removed"
mofa_assert_called_before /usr/bin/pkill /bin/rm "Teams is stopped before its data is removed"
mofa_assert_called_before /bin/rm /usr/sbin/installer "old data is removed before installing"
mofa_assert_not_called /usr/bin/ditto "nothing is copied as root"
mofa_assert_contains "$MOFA_STDOUT" "Microsoft Teams removal and reinstall completed." "completion is logged"
t_calls=("${(@f)$(mofa_calls)}")
mofa_assert_eq "t_cleanup_probe" "${t_calls[-1]}" "the EXIT trap cleans up after main finishes"

t_case "main reinstall flow exits 1 when a removal fails, after installing"
t_make_teams_data "$T_HOME"
T_DSCL_LIST=$'alice 501'
T_DSCL_HOMES=(alice "$T_HOME")
t_setup_console_user
t_setup_download "$T_SIGNED_BY_MICROSOFT"
t_setup_healthy_app
mofa_stub_handler /usr/bin/dscl t_fake_dscl
mofa_stub /bin/rm 1
mofa_run t_main_flow / computer alice MODE=reinstall
mofa_assert_status 1 "a removal failure is reported to Jamf"
mofa_assert_called /usr/sbin/installer -pkg "$T_WORK/MicrosoftTeams.pkg" -target /
mofa_assert_contains "$MOFA_STDOUT" "WARN: Failed to remove ${T_HOME}/Library/Containers/com.microsoft.teams2" "the failed removal is logged"
# No exact count: cleanup_system_paths checks literal /Applications and /Library paths on this Mac.
mofa_assert_contains "$MOFA_STDOUT" "ERROR: Microsoft Teams reinstall completed with" "the failure count is logged"
mofa_assert_contains "$MOFA_STDOUT" "cleanup failure(s)." "the failure is reported as a cleanup failure"

mofa_finish
