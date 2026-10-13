# ============================================================
# MOFA reset script test harness (zsh). Source it from a test file:
#
#   source "${0:A:h}/harness.zsh"
#   mofa_source_script MOFA_Community_Microsoft_Excel_Reset.zsh
#   mofa_assert_source_clean
#   mofa_case "removeTarget refuses /"
#   removeTarget -rf "/"
#   mofa_assert_not_called /bin/rm
#   mofa_finish
#
# The reset scripts delete user data and run as root under Jamf, so this harness is
# deny-by-default, in two layers:
#   1. Kernel sandbox. A test file run as "zsh FILE" re-runs itself under
#      /usr/bin/sandbox-exec. The profile allows writes only inside a fresh private directory
#      (MOFA_SANDBOX_BASE), runs only the programs in MOFA_KERNEL_EXEC_ALLOWED (zsh, file
#      utilities whose writes the profile confines, read-only text filters), lets a process
#      signal only itself and denies network access. This also covers what function stubs
#      cannot: file redirections, builtins and executable paths assembled at run time.
#      Without sandbox-exec the harness refuses to run unless MOFA_ALLOW_NO_KERNEL_SANDBOX=1.
#   2. Function stubs. The harness refuses to run as root; creates a private sandbox
#      (MOFA_TEST_ROOT) and points HOME, TMPDIR, TMPPREFIX and the working directory into it;
#      before any script is sourced it replaces common destructive or system commands (bare
#      names and their /bin, /sbin, /usr/bin, /usr/sbin and /usr/libexec paths) with
#      recording stubs, and mofa_source_script also stubs every absolute command path the
#      script text mentions; PATH points at an empty directory, so any external command that
#      is not stubbed fails with status 127 and is reported as a test failure.
# A stub records its argv in the call log and returns a status the test chooses (default 0)
# with optional output. Nothing a stub receives is executed.
# Limit: an executable path assembled from variables at run time ("$DIR/tool") is not in the
# script text, so it is not stubbed automatically; stub such paths with mofa_stub before use
# (the kernel sandbox makes a missed one fail with "operation not permitted").
#
# Public API (all names start with mofa_ / MOFA_):
#   mofa_source_script NAME|PATH    stub the script's commands, then source it (library mode)
#   mofa_assert_source_clean        shebang, guard line, and no output/calls/traps/exit on source
#   mofa_case "title"               start a case: reset HOME/TMPDIR/PATH, call log and stub settings
#   mofa_stub CMD [STATUS [OUTPUT]] set a stub's exit status and stdout (creates the stub if needed)
#   mofa_stub_handler CMD FUNC      call FUNC "$@" for CMD instead (FUNC prints / returns status)
#   mofa_stub_passthrough CMD       run the real binary for a read-only text filter
#                                   (awk grep sed tr cut head tail sort uniq wc basename dirname
#                                   echo date printf); sed -i and awk system()/getline/pipes/
#                                   redirection are refused
#   mofa_reset_stubs / mofa_reset_calls
#   mofa_scan_commands FILE         print the absolute command paths a file mentions
#   mofa_calls [CMD]                print recorded calls (one per line, argv quoted with (q+))
#   mofa_call_count [CMD]           print the number of recorded calls
#   mofa_run CMD [ARGS...]          run in a subshell; sets MOFA_STATUS MOFA_STDOUT MOFA_STDERR
#                                   MOFA_OUTPUT (use for anything that may exit)
#   mofa_capture CMD [ARGS...]      same, in the current shell, so globals persist (never for code
#                                   that may call exit)
#   mofa_mkdir DIR... / mofa_write_file FILE [CONTENT]   create sandbox-only fixtures
#   Assertions: mofa_assert_eq EXPECTED ACTUAL MSG, mofa_assert_contains TEXT NEEDLE MSG,
#     mofa_assert_not_contains TEXT NEEDLE MSG, mofa_assert_status EXPECTED MSG,
#     mofa_assert_called CMD [ARGS...] (exact argv), mofa_assert_not_called CMD [MSG],
#     mofa_assert_no_calls MSG, mofa_assert_called_before CMD_A CMD_B MSG,
#     mofa_assert_function_defined NAME, mofa_pass MSG, mofa_fail MSG [DETAILS]
#   mofa_finish                     print the summary, clean the sandbox, exit 0 or 1
#   MOFA_KERNEL_SANDBOX             1 inside the kernel sandbox, 0 when it was disabled
# Set MOFA_KEEP_SANDBOX=1 to keep the sandbox for debugging.
# ============================================================

# --- Refuse unsafe contexts (builtins only) ------------------------------------------
if (( EUID == 0 || UID == 0 )); then
	print -u2 -r -- "harness: refusing to run as root; run the reset script tests as an unprivileged user"
	exit 1
fi
if [[ "${ZSH_EVAL_CONTEXT}" != *:file ]]; then
	print -u2 -r -- "harness: source this file from a test file; do not execute it"
	exit 1
fi

emulate -R zsh
unalias -m '*' 2>/dev/null
unalias -s -m '*' 2>/dev/null
zmodload zsh/parameter || exit 1
unset MODE

typeset -g MOFA_HARNESS_DIR="${${(%):-%x}:A:h}"
typeset -g MOFA_REPO_ROOT="${MOFA_HARNESS_DIR:h:h}"
typeset -g MOFA_SCRIPTS_DIR="${MOFA_REPO_ROOT}/office_reset_tools/mofa_community_maintained/scripts"
typeset -g MOFA_GUARD_LINE='if [[ "${ZSH_EVAL_CONTEXT}" != *:file ]]; then main "$@"; fi'
typeset -g MOFA_SHEBANG='#!/bin/zsh --no-rcs'

# --- Kernel sandbox -----------------------------------------------------------------
# Programs the sandboxed test may run. Each one either only reads (text filters, find, stat)
# or writes files, which the profile confines to MOFA_SANDBOX_BASE. Never add a program that
# talks to a system service (defaults, launchctl, security, dscl, sudo, installer, curl ...).
typeset -ga MOFA_KERNEL_EXEC_ALLOWED
MOFA_KERNEL_EXEC_ALLOWED=(
	/bin/zsh /usr/bin/env
	/bin/mkdir /bin/rm /bin/rmdir /bin/ln /bin/cp /bin/mv /bin/cat /bin/ls /bin/chmod
	/usr/bin/touch /usr/bin/mktemp /usr/bin/find /usr/bin/stat /usr/bin/readlink /usr/bin/plutil
	/usr/bin/awk /usr/bin/grep /usr/bin/sed /usr/bin/tr /usr/bin/cut /usr/bin/head /usr/bin/tail
	/usr/bin/sort /usr/bin/uniq /usr/bin/wc /usr/bin/basename /usr/bin/dirname /bin/echo /bin/date
	/usr/bin/printf
)
typeset -gi MOFA_KERNEL_SANDBOX=0
typeset -g MOFA_SANDBOX_BASE=""

__mofa_kernel_profile() { # prints the sandbox-exec profile; the writable base is param MOFA_BASE
	local __mofa_prog
	print -r -- '(version 1)'
	print -r -- '(allow default)'
	print -r -- '(deny network*)'
	print -r -- '(deny signal)'
	print -r -- '(allow signal (target self))'
	print -r -- '(deny file-write* (require-not (require-any (subpath (param "MOFA_BASE"))'
	print -r -- '	(regex #"^/dev/(null|zero|tty|stdout|stderr|dtracehelper|fd/[0-9]+)$"))))'
	print -rn -- '(deny process-exec* (require-not (require-any'
	for __mofa_prog in "${MOFA_KERNEL_EXEC_ALLOWED[@]}"; do
		print -rn -- " (literal \"${__mofa_prog}\")"
	done
	print -r -- ')))'
}

if [[ -n "${MOFA_KERNEL_SANDBOX_BASE:-}" ]]; then
	# Inner stage: the outer stage below started this process under sandbox-exec.
	MOFA_SANDBOX_BASE="$MOFA_KERNEL_SANDBOX_BASE"
	if [[ "$MOFA_SANDBOX_BASE" != /?*/mofa_reset_sandbox.?????? || ! -d "$MOFA_SANDBOX_BASE" \
		|| ! -O "$MOFA_SANDBOX_BASE" ]]; then
		print -u2 -r -- "harness: invalid MOFA_KERNEL_SANDBOX_BASE ${MOFA_SANDBOX_BASE}"
		exit 1
	fi
	# /usr/bin/true is not on the allow-list, so it runs only when the sandbox is missing.
	if command /usr/bin/true 2>/dev/null; then
		print -u2 -r -- "harness: MOFA_KERNEL_SANDBOX_BASE is set but this process is not in the kernel sandbox"
		exit 1
	fi
	MOFA_KERNEL_SANDBOX=1
elif [[ "${MOFA_ALLOW_NO_KERNEL_SANDBOX:-}" == 1 ]]; then
	print -u2 -r -- "harness: WARNING: MOFA_ALLOW_NO_KERNEL_SANDBOX=1, so only function stubs protect this Mac"
	MOFA_SANDBOX_BASE="${${${TMPDIR:-/tmp}%/}:A}"
else
	# Outer stage: run this test file again inside the kernel sandbox, clean up and exit with
	# its status. The rest of the test file never runs outside the sandbox.
	typeset -g __mofa_test_file="${ZSH_ARGZERO:A}" __mofa_base="" __mofa_profile=""
	typeset -gi __mofa_outer_rc=0
	if [[ ! -f "$__mofa_test_file" || "${__mofa_test_file:t}" != *.zsh ]]; then
		print -u2 -r -- "harness: run the test file itself (zsh tests/reset_scripts/test_NAME.zsh) so it can re-run in the kernel sandbox"
		exit 1
	fi
	if [[ ! -x /usr/bin/sandbox-exec ]]; then
		print -u2 -r -- "harness: /usr/bin/sandbox-exec is missing; set MOFA_ALLOW_NO_KERNEL_SANDBOX=1 to rely on function stubs only"
		exit 1
	fi
	__mofa_base="$(command /usr/bin/mktemp -d "${${TMPDIR:-/tmp}%/}/mofa_reset_sandbox.XXXXXX")" || __mofa_base=""
	if [[ -z "$__mofa_base" || ! -d "$__mofa_base" || ! -O "$__mofa_base" ]]; then
		print -u2 -r -- "harness: unable to create a private sandbox directory"
		exit 1
	fi
	__mofa_base="${__mofa_base:A}" # the profile needs the real path (/var -> /private/var)
	__mofa_outer_cleanup() {
		if [[ -n "${MOFA_KEEP_SANDBOX:-}" ]]; then
			print -u2 -r -- "harness: kept sandbox ${__mofa_base}"
		elif [[ "$__mofa_base" == /?*/mofa_reset_sandbox.?????? && -d "$__mofa_base" && -O "$__mofa_base" ]]; then
			command /bin/rm -rf -- "$__mofa_base"
		fi
	}
	trap '__mofa_outer_cleanup; exit 130' INT
	trap '__mofa_outer_cleanup; exit 143' TERM HUP
	__mofa_profile="$(__mofa_kernel_profile)"
	# Preflight: the profile must apply and must stop a program that is not allow-listed.
	if ! command /usr/bin/sandbox-exec -D "MOFA_BASE=${__mofa_base}" -p "$__mofa_profile" \
		/bin/zsh --no-rcs -c 'command /usr/bin/true 2>/dev/null && exit 3; exit 0' 2>/dev/null; then
		print -u2 -r -- "harness: the kernel sandbox could not be applied; set MOFA_ALLOW_NO_KERNEL_SANDBOX=1 to rely on function stubs only"
		__mofa_outer_cleanup
		exit 1
	fi
	export MOFA_KERNEL_SANDBOX_BASE="$__mofa_base" TMPPREFIX="${__mofa_base}/zsh"
	command /usr/bin/sandbox-exec -D "MOFA_BASE=${__mofa_base}" -p "$__mofa_profile" \
		/bin/zsh --no-rcs "$__mofa_test_file" "$@"
	__mofa_outer_rc=$?
	__mofa_outer_cleanup
	exit $__mofa_outer_rc
fi

# --- Sandbox ------------------------------------------------------------------------
typeset -g MOFA_TEST_ROOT=""
MOFA_TEST_ROOT="$(command /usr/bin/mktemp -d "${MOFA_SANDBOX_BASE}/mofa_reset_tests.XXXXXX")" || MOFA_TEST_ROOT=""
if [[ -z "$MOFA_TEST_ROOT" || ! -d "$MOFA_TEST_ROOT" || ! -O "$MOFA_TEST_ROOT" ]]; then
	print -u2 -r -- "harness: unable to create a private temporary directory"
	exit 1
fi
MOFA_TEST_ROOT="${MOFA_TEST_ROOT:A}"
if [[ "$MOFA_TEST_ROOT" != /?*/mofa_reset_tests.?????? ]]; then
	print -u2 -r -- "harness: unexpected sandbox path ${MOFA_TEST_ROOT}"
	exit 1
fi
umask 077
command /bin/mkdir -p -- "$MOFA_TEST_ROOT/home" "$MOFA_TEST_ROOT/tmp" "$MOFA_TEST_ROOT/nopath" \
	"$MOFA_TEST_ROOT/log" "$MOFA_TEST_ROOT/out" || exit 1

typeset -g MOFA_CALL_LOG="$MOFA_TEST_ROOT/log/calls.log"
typeset -g MOFA_RESULTS="$MOFA_TEST_ROOT/log/results.log"
: >| "$MOFA_CALL_LOG"
: >| "$MOFA_RESULTS"

typeset -g MOFA_SCRIPT_PATH="" MOFA_SOURCE_OUTPUT="" MOFA_STDOUT="" MOFA_STDERR="" MOFA_OUTPUT=""
typeset -gi MOFA_STATUS=0 MOFA_SOURCE_STATUS=0 MOFA_SOURCE_TRAPS_CHANGED=0 MOFA_STUB_DEFAULT_STATUS=0
typeset -gi __mofa_finished=0 __mofa_sourcing=0
typeset -gA __mofa_stub_status __mofa_stub_output __mofa_stub_handler __mofa_stub_passthrough
typeset -ga MOFA_STUBBED_COMMANDS
typeset -ga __mofa_passthrough_allowed
__mofa_passthrough_allowed=(awk grep sed tr cut head tail sort uniq wc basename dirname echo date printf)

# Bare command names that are always stubbed, together with their system-directory paths.
typeset -ga __mofa_default_stubs
__mofa_default_stubs=(
	rm rmdir unlink srm mv cp ditto ln mkdir touch install chown chgrp chmod chflags xattr
	pkill killall kill launchctl defaults plutil PlistBuddy security dscl dseditgroup sysadminctl
	createhomedir sqlite3 curl wget nscurl installer pkgutil spctl codesign sudo su osascript open
	profiles jamf shutdown reboot halt diskutil tccutil scutil id mktemp find xargs env nohup tee
	logger sw_vers stat getconf tar unzip zip dd networksetup systemsetup softwareupdate fdesetup
	kmutil pmset lsregister sleep sh bash zsh python3 perl ruby
)

__mofa_reset_env() {
	export HOME="$MOFA_TEST_ROOT/home"
	export TMPDIR="$MOFA_TEST_ROOT/tmp/"
	export TMPPREFIX="$MOFA_TEST_ROOT/tmp/zsh" # here-documents and =(...) temp files
	export PATH="$MOFA_TEST_ROOT/nopath"
	builtin cd -q -- "$MOFA_TEST_ROOT"
}

__mofa_cleanup_sandbox() {
	if [[ -n "${MOFA_KEEP_SANDBOX:-}" ]]; then
		print -u2 -r -- "harness: kept sandbox ${MOFA_TEST_ROOT}"
		return 0
	fi
	builtin cd -q /
	if [[ "$MOFA_TEST_ROOT" == /?*/mofa_reset_tests.?????? && -d "$MOFA_TEST_ROOT" && -O "$MOFA_TEST_ROOT" ]]; then
		command /bin/rm -rf -- "$MOFA_TEST_ROOT"
	fi
}

__mofa_on_exit() {
	local -i __mofa_rc=$?
	(( ZSH_SUBSHELL == 0 )) || return 0
	if (( ! __mofa_finished )); then
		if (( __mofa_sourcing )); then
			print -u2 -r -- "harness: the script exited while being sourced; top-level code must not run (status ${__mofa_rc})"
		else
			print -u2 -r -- "harness: test exited before mofa_finish (status ${__mofa_rc})"
		fi
		(( __mofa_rc == 0 )) && __mofa_rc=1
	fi
	__mofa_cleanup_sandbox
	exit $__mofa_rc
}
trap __mofa_on_exit EXIT

# --- Results ------------------------------------------------------------------------
# Results go to a file so assertions made inside subshells (mofa_run, stub handlers) count.
mofa_pass() { # $1: message
	print -r -- "ok - $1"
	print -r -- "ok	${1//$'\n'/ }" >> "$MOFA_RESULTS"
}

mofa_fail() { # $1: message, $2: optional details
	local __mofa_line
	print -r -- "not ok - $1"
	if [[ -n "${2:-}" ]]; then
		for __mofa_line in "${(@f)2}"; do
			print -r -- "#   ${__mofa_line}"
		done
	fi
	print -r -- "not ok	${1//$'\n'/ }" >> "$MOFA_RESULTS"
}

mofa_finish() {
	local -a __mofa_lines __mofa_failed
	local -i __mofa_npass __mofa_nfail
	__mofa_lines=(${(f)"$(<"$MOFA_RESULTS")"})
	__mofa_failed=(${(M)__mofa_lines:#not ok*})
	__mofa_nfail=${#__mofa_failed}
	__mofa_npass=$(( ${#__mofa_lines} - __mofa_nfail ))
	if (( MOFA_KERNEL_SANDBOX )); then
		print -r -- "# kernel sandbox: active (writes confined to ${MOFA_SANDBOX_BASE})"
	else
		print -r -- "# kernel sandbox: DISABLED (MOFA_ALLOW_NO_KERNEL_SANDBOX=1)"
	fi
	print -r -- "# ${__mofa_npass} passed, ${__mofa_nfail} failed"
	if (( __mofa_nfail > 0 )); then
		print -r -- "# failed: ${(j:; :)${(@)__mofa_failed#not ok	}}"
	fi
	__mofa_finished=1
	__mofa_cleanup_sandbox
	if (( __mofa_nfail > 0 || ${#__mofa_lines} == 0 )); then
		(( ${#__mofa_lines} == 0 )) && print -r -- "# no assertions ran"
		exit 1
	fi
	exit 0
}

# --- Stubs --------------------------------------------------------------------------
__mofa_format_argv() {
	print -r -- "${(j: :)${(q+)@}}"
}

__mofa_install_stub() { # $1: command name or path
	local __mofa_name="$1"
	[[ -n "$__mofa_name" ]] || return 1
	functions[$__mofa_name]="__mofa_stub_dispatch ${(q)__mofa_name} \"\$@\""
	(( ${MOFA_STUBBED_COMMANDS[(Ie)$__mofa_name]} )) || MOFA_STUBBED_COMMANDS+=("$__mofa_name")
}

__mofa_stub_dispatch() { # $1: stubbed name, then argv
	local __mofa_name="$1"
	shift
	__mofa_format_argv "$__mofa_name" "$@" >> "$MOFA_CALL_LOG"
	if [[ -n "${__mofa_stub_handler[$__mofa_name]:-}" ]]; then
		"${__mofa_stub_handler[$__mofa_name]}" "$@"
		return
	fi
	if [[ -n "${__mofa_stub_passthrough[$__mofa_name]:-}" ]]; then
		__mofa_run_passthrough "$__mofa_name" "${__mofa_stub_passthrough[$__mofa_name]}" "$@"
		return
	fi
	if [[ -n "${__mofa_stub_output[$__mofa_name]:-}" ]]; then
		print -r -- "${__mofa_stub_output[$__mofa_name]}"
	fi
	return "${__mofa_stub_status[$__mofa_name]:-$MOFA_STUB_DEFAULT_STATUS}"
}

__mofa_run_passthrough() { # $1: stubbed name, $2: real binary, then argv
	local __mofa_name="$1" __mofa_real="$2" __mofa_arg
	shift 2
	for __mofa_arg in "$@"; do
		case "${__mofa_real:t}" in
			sed)
				if [[ "$__mofa_arg" == -i* || "$__mofa_arg" == --in-place* \
					|| "$__mofa_arg" == w[[:space:]]* || "$__mofa_arg" == *[^[:alnum:]]w[[:space:]]* ]]; then
					mofa_fail "harness refused sed passthrough argument: ${__mofa_arg}"
					return 125
				fi
				;;
			awk)
				if [[ "$__mofa_arg" == *system* || "$__mofa_arg" == *getline* || "$__mofa_arg" == *\|* \
					|| "$__mofa_arg" == *print*\>* ]]; then
					mofa_fail "harness refused awk passthrough program: ${__mofa_arg}"
					return 125
				fi
				;;
		esac
	done
	command "$__mofa_real" "$@"
}

command_not_found_handler() {
	print -r -- "!notfound $(__mofa_format_argv "$@")" >> "$MOFA_CALL_LOG"
	mofa_fail "unstubbed command was called: ${1} (stub it with mofa_stub)"
	return 127
}

mofa_stub() { # $1: command, $2: status (default 0), $3: stdout
	[[ -n "${functions[$1]:-}" && "${functions[$1]}" == *__mofa_stub_dispatch* ]] || __mofa_install_stub "$1"
	__mofa_stub_status[$1]="${2:-0}"
	if (( $# >= 3 )); then
		__mofa_stub_output[$1]="$3"
	else
		unset "__mofa_stub_output[$1]"
	fi
	unset "__mofa_stub_handler[$1]" "__mofa_stub_passthrough[$1]"
}

mofa_stub_handler() { # $1: command, $2: function called with the stub's argv
	[[ -n "${functions[$1]:-}" && "${functions[$1]}" == *__mofa_stub_dispatch* ]] || __mofa_install_stub "$1"
	__mofa_stub_handler[$1]="$2"
	unset "__mofa_stub_passthrough[$1]"
}

mofa_stub_passthrough() { # $1: read-only text filter (bare name or /bin|/usr/bin path)
	local __mofa_name="$1" __mofa_base="${1:t}" __mofa_real="" __mofa_dir
	if (( ! ${__mofa_passthrough_allowed[(Ie)$__mofa_base]} )); then
		mofa_fail "harness refused passthrough for ${__mofa_name}: not a read-only text filter"
		return 1
	fi
	if [[ "$__mofa_name" == /* ]]; then
		[[ "${__mofa_name:h}" == /bin || "${__mofa_name:h}" == /usr/bin ]] && __mofa_real="$__mofa_name"
	else
		for __mofa_dir in /usr/bin /bin; do
			if [[ -x "$__mofa_dir/$__mofa_base" ]]; then
				__mofa_real="$__mofa_dir/$__mofa_base"
				break
			fi
		done
	fi
	if [[ -z "$__mofa_real" || ! -x "$__mofa_real" ]]; then
		mofa_fail "harness refused passthrough for ${__mofa_name}: no system binary"
		return 1
	fi
	[[ "${functions[$__mofa_name]:-}" == *__mofa_stub_dispatch* ]] || __mofa_install_stub "$__mofa_name"
	__mofa_stub_passthrough[$__mofa_name]="$__mofa_real"
	unset "__mofa_stub_handler[$__mofa_name]"
}

mofa_reset_stubs() {
	__mofa_stub_status=()
	__mofa_stub_output=()
	__mofa_stub_handler=()
	__mofa_stub_passthrough=()
}

mofa_reset_calls() {
	: >| "$MOFA_CALL_LOG"
}

mofa_calls() { # $1: optional command; prints matching call lines
	local -a __mofa_lines
	local __mofa_q __mofa_line
	__mofa_lines=(${(f)"$(<"$MOFA_CALL_LOG")"})
	if (( $# == 0 )); then
		(( ${#__mofa_lines} )) && print -rl -- "${__mofa_lines[@]}"
		return 0
	fi
	__mofa_q="${(q+)1}"
	for __mofa_line in "${__mofa_lines[@]}"; do
		[[ "$__mofa_line" == "$__mofa_q" || "$__mofa_line" == "$__mofa_q "* ]] && print -r -- "$__mofa_line"
	done
	return 0
}

mofa_call_count() { # $1: optional command
	local -a __mofa_lines
	__mofa_lines=(${(f)"$(mofa_calls "$@")"})
	print -r -- "${#__mofa_lines}"
}

# Prints the absolute command paths a script mentions: every literal path containing a bin,
# sbin or libexec directory, plus quoted app-bundle executables (".../Contents/MacOS/...").
# Paths built from variables at run time cannot be found this way; stub them with mofa_stub.
mofa_scan_commands() { # $1: script path
	local __mofa_text __mofa_quoted __mofa_word __mofa_segment __mofa_nl=$'\n'
	local -a __mofa_found
	__mofa_text="$(<"$1")" || return 1
	# Every character that cannot be part of a plain path becomes a word separator.
	for __mofa_word in ${=__mofa_text//[^A-Za-z0-9_.+\/-]/ }; do
		# "${PREFIX}/usr/bin/x" leaves "PREFIX/usr/bin/x"; stub its absolute tail too.
		[[ "$__mofa_word" == /* ]] || __mofa_word="/${__mofa_word#*/}"
		[[ "$__mofa_word" != */ ]] || continue
		if [[ "$__mofa_word" == */bin/?* || "$__mofa_word" == */sbin/?* || "$__mofa_word" == */libexec/?* ]]; then
			__mofa_found+=("$__mofa_word")
		fi
	done
	# Quoted strings may hold app-bundle executables with spaces in their paths.
	__mofa_quoted=${__mofa_text//[\"\']/$__mofa_nl}
	for __mofa_segment in "${(@f)__mofa_quoted}"; do
		[[ "$__mofa_segment" == /* && "$__mofa_segment" != *[\$\`]* ]] || continue
		if [[ "$__mofa_segment" == */Contents/(MacOS|Resources|SharedSupport|Helpers)/?* ]]; then
			__mofa_found+=("$__mofa_segment")
		fi
	done
	(( ${#__mofa_found} )) && print -rl -- "${(u)__mofa_found[@]}"
	return 0
}

__mofa_install_default_stubs() {
	local __mofa_cmd __mofa_dir
	for __mofa_cmd in "${__mofa_default_stubs[@]}"; do
		__mofa_install_stub "$__mofa_cmd"
		for __mofa_dir in /bin /sbin /usr/bin /usr/sbin /usr/libexec; do
			__mofa_install_stub "$__mofa_dir/$__mofa_cmd"
		done
	done
}

# --- Sourcing -----------------------------------------------------------------------
mofa_source_script() { # $1: script file name in the scripts directory, or a path
	local __mofa_file="$1" __mofa_cmd __mofa_before __mofa_after
	local -i __mofa_rc
	[[ "$__mofa_file" == */* ]] || __mofa_file="${MOFA_SCRIPTS_DIR}/${__mofa_file}"
	if [[ ! -f "$__mofa_file" ]]; then
		mofa_fail "script not found: ${__mofa_file}"
		mofa_finish
	fi
	MOFA_SCRIPT_PATH="${__mofa_file:A}"
	for __mofa_cmd in ${(f)"$(mofa_scan_commands "$MOFA_SCRIPT_PATH")"}; do
		__mofa_install_stub "$__mofa_cmd"
	done
	__mofa_reset_env
	mofa_reset_calls
	trap >| "$MOFA_TEST_ROOT/out/traps.before"
	__mofa_sourcing=1
	set --
	source "$MOFA_SCRIPT_PATH" >| "$MOFA_TEST_ROOT/out/source.out" 2>&1
	__mofa_rc=$?
	__mofa_sourcing=0
	trap >| "$MOFA_TEST_ROOT/out/traps.after"
	MOFA_SOURCE_STATUS=$__mofa_rc
	MOFA_SOURCE_OUTPUT="$(<"$MOFA_TEST_ROOT/out/source.out")"
	__mofa_before="$(<"$MOFA_TEST_ROOT/out/traps.before")"
	__mofa_after="$(<"$MOFA_TEST_ROOT/out/traps.after")"
	# An EXIT trap set while sourcing is scoped to this function and cannot replace the
	# harness's global one; never set an EXIT trap here for the same reason.
	MOFA_SOURCE_TRAPS_CHANGED=0
	[[ "$__mofa_before" != "$__mofa_after" ]] && MOFA_SOURCE_TRAPS_CHANGED=1
	# The script's top level sets PATH (and may set HOME); put the sandbox back.
	__mofa_reset_env
	return 0
}

mofa_assert_source_clean() {
	local -a __mofa_lines
	local __mofa_last=""
	__mofa_lines=("${(@f)$(<"$MOFA_SCRIPT_PATH")}")
	mofa_assert_eq "$MOFA_SHEBANG" "${__mofa_lines[1]}" "first line is the Jamf shebang"
	for __mofa_last in "${(@Oa)__mofa_lines}"; do
		[[ -n "${__mofa_last//[[:space:]]/}" ]] && break
	done
	mofa_assert_eq "$MOFA_GUARD_LINE" "$__mofa_last" "last line is the source guard"
	mofa_assert_eq 0 "$MOFA_SOURCE_STATUS" "sourcing returns 0"
	mofa_assert_eq "" "$MOFA_SOURCE_OUTPUT" "sourcing prints nothing"
	mofa_assert_no_calls "sourcing runs no stubbed command"
	mofa_assert_eq 0 "$MOFA_SOURCE_TRAPS_CHANGED" "sourcing sets no trap"
	mofa_assert_function_defined main
}

# --- Running code under test --------------------------------------------------------
mofa_run() { # run "$@" in a subshell and capture status and output
	( "$@" ) >| "$MOFA_TEST_ROOT/out/run.stdout" 2>| "$MOFA_TEST_ROOT/out/run.stderr"
	MOFA_STATUS=$?
	__mofa_collect_output
	return 0
}

mofa_capture() { # run "$@" in the current shell (globals persist); never for code that may exit
	"$@" >| "$MOFA_TEST_ROOT/out/run.stdout" 2>| "$MOFA_TEST_ROOT/out/run.stderr"
	MOFA_STATUS=$?
	__mofa_collect_output
	return 0
}

__mofa_collect_output() {
	MOFA_STDOUT="$(<"$MOFA_TEST_ROOT/out/run.stdout")"
	MOFA_STDERR="$(<"$MOFA_TEST_ROOT/out/run.stderr")"
	MOFA_OUTPUT="${MOFA_STDOUT}"
	[[ -n "$MOFA_STDOUT" && -n "$MOFA_STDERR" ]] && MOFA_OUTPUT+=$'\n'
	MOFA_OUTPUT+="${MOFA_STDERR}"
}

mofa_case() { # $1: title; resets environment, call log and stub settings
	print -r -- "# --- $1"
	__mofa_reset_env
	mofa_reset_calls
	mofa_reset_stubs
}

__mofa_in_sandbox() { # $1: path
	[[ "${1:a}" == "$MOFA_TEST_ROOT"/?* ]]
}

mofa_mkdir() { # creates directories inside the sandbox only
	local __mofa_dir
	for __mofa_dir in "$@"; do
		if ! __mofa_in_sandbox "$__mofa_dir"; then
			mofa_fail "mofa_mkdir refused a path outside the sandbox: ${__mofa_dir}"
			return 1
		fi
		command /bin/mkdir -p -- "${__mofa_dir:a}" || return 1
	done
}

mofa_write_file() { # $1: file inside the sandbox, $2: content
	if ! __mofa_in_sandbox "$1"; then
		mofa_fail "mofa_write_file refused a path outside the sandbox: $1"
		return 1
	fi
	mofa_mkdir "${1:a:h}" || return 1
	print -r -- "${2:-}" >| "${1:a}"
}

# --- Assertions ---------------------------------------------------------------------
mofa_assert_eq() { # $1: expected, $2: actual, $3: message
	if [[ "$2" == "$1" ]]; then
		mofa_pass "$3"
	else
		mofa_fail "$3" "expected: [$1]"$'\n'"actual:   [$2]"
	fi
}

mofa_assert_contains() { # $1: text, $2: needle, $3: message
	if [[ "$1" == *"$2"* ]]; then
		mofa_pass "$3"
	else
		mofa_fail "$3" "missing:  [$2]"$'\n'"in text:  [$1]"
	fi
}

mofa_assert_not_contains() { # $1: text, $2: needle, $3: message
	if [[ "$1" != *"$2"* ]]; then
		mofa_pass "$3"
	else
		mofa_fail "$3" "unexpected: [$2]"$'\n'"in text:    [$1]"
	fi
}

mofa_assert_status() { # $1: expected MOFA_STATUS, $2: message
	if (( MOFA_STATUS == $1 )); then
		mofa_pass "$2"
	else
		mofa_fail "$2" "expected status $1, got ${MOFA_STATUS}"$'\n'"output: ${MOFA_OUTPUT}"
	fi
}

mofa_assert_called() { # $1: command, then the exact expected arguments
	local __mofa_expected
	local -a __mofa_lines
	__mofa_expected="$(__mofa_format_argv "$@")"
	__mofa_lines=(${(f)"$(<"$MOFA_CALL_LOG")"})
	if (( ${__mofa_lines[(Ie)$__mofa_expected]} )); then
		mofa_pass "called: ${__mofa_expected}"
	else
		mofa_fail "called: ${__mofa_expected}" "recorded calls:"$'\n'"$(mofa_calls)"
	fi
}

mofa_assert_not_called() { # $1: command, $2: optional message
	local __mofa_calls
	__mofa_calls="$(mofa_calls "$1")"
	if [[ -z "$__mofa_calls" ]]; then
		mofa_pass "${2:-not called: $1}"
	else
		mofa_fail "${2:-not called: $1}" "recorded:"$'\n'"${__mofa_calls}"
	fi
}

mofa_assert_no_calls() { # $1: message
	local __mofa_calls
	__mofa_calls="$(mofa_calls)"
	if [[ -z "$__mofa_calls" ]]; then
		mofa_pass "$1"
	else
		mofa_fail "$1" "recorded:"$'\n'"${__mofa_calls}"
	fi
}

mofa_assert_called_before() { # $1: first command, $2: later command, $3: message
	local -a __mofa_lines
	local -i __mofa_i __mofa_a=0 __mofa_b=0
	local __mofa_qa="${(q+)1}" __mofa_qb="${(q+)2}"
	__mofa_lines=(${(f)"$(<"$MOFA_CALL_LOG")"})
	for (( __mofa_i = 1; __mofa_i <= ${#__mofa_lines}; __mofa_i++ )); do
		if (( ! __mofa_a )) && [[ "${__mofa_lines[__mofa_i]}" == "$__mofa_qa" || "${__mofa_lines[__mofa_i]}" == "$__mofa_qa "* ]]; then
			__mofa_a=__mofa_i
		fi
		if (( ! __mofa_b )) && [[ "${__mofa_lines[__mofa_i]}" == "$__mofa_qb" || "${__mofa_lines[__mofa_i]}" == "$__mofa_qb "* ]]; then
			__mofa_b=__mofa_i
		fi
	done
	if (( __mofa_a && __mofa_b && __mofa_a < __mofa_b )); then
		mofa_pass "$3"
	else
		mofa_fail "$3" "first $1 call: ${__mofa_a}; first $2 call: ${__mofa_b}"$'\n'"$(mofa_calls)"
	fi
}

mofa_assert_function_defined() { # $1: function name
	if (( ${+functions[$1]} )); then
		mofa_pass "function defined: $1"
	else
		mofa_fail "function defined: $1"
	fi
}

__mofa_install_default_stubs
__mofa_reset_env
