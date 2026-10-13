#!/bin/zsh --no-rcs
# ============================================================
# Runs every tests/reset_scripts/test_*.zsh (or the named ones) in its own zsh process with a
# minimal environment, prints a summary and exits nonzero if any test file fails.
#
#   zsh tests/reset_scripts/run_all.zsh                         # all test files
#   zsh tests/reset_scripts/run_all.zsh test_Excel_Reset.zsh    # selected files
#
# Never run as root: the tests stub destructive commands and the harness refuses root too.
# Each test file re-runs itself under /usr/bin/sandbox-exec (see harness.zsh). Only
# MOFA_KEEP_SANDBOX and MOFA_ALLOW_NO_KERNEL_SANDBOX pass through from the caller's environment.
# ============================================================

emulate -R zsh

if (( EUID == 0 || UID == 0 )); then
	print -u2 -r -- "run_all: refusing to run as root"
	exit 1
fi

tests_dir="${${(%):-%x}:A:h}"
typeset -a test_files failed passthrough_env
requested=""
[[ -n "${MOFA_KEEP_SANDBOX:-}" ]] && passthrough_env+=("MOFA_KEEP_SANDBOX=${MOFA_KEEP_SANDBOX}")
[[ -n "${MOFA_ALLOW_NO_KERNEL_SANDBOX:-}" ]] \
	&& passthrough_env+=("MOFA_ALLOW_NO_KERNEL_SANDBOX=${MOFA_ALLOW_NO_KERNEL_SANDBOX}")

if (( $# > 0 )); then
	for requested in "$@"; do
		requested="${requested:t}"
		if [[ "$requested" != test_*.zsh || ! -f "${tests_dir}/${requested}" ]]; then
			print -u2 -r -- "run_all: no such test file: ${requested}"
			exit 1
		fi
		test_files+=("${tests_dir}/${requested}")
	done
else
	test_files=("${tests_dir}"/test_*.zsh(N))
fi

if (( ${#test_files} == 0 )); then
	print -u2 -r -- "run_all: no test files found in ${tests_dir}"
	exit 1
fi

for test_file in "${test_files[@]}"; do
	print -r -- "=== ${test_file:t}"
	/usr/bin/env -i \
		HOME="${HOME:-/var/empty}" \
		USER="${USER:-}" \
		LOGNAME="${LOGNAME:-}" \
		TMPDIR="${TMPDIR:-/tmp}" \
		LANG="${LANG:-C}" \
		PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
		"${passthrough_env[@]}" \
		/bin/zsh --no-rcs "$test_file"
	rc=$?
	if (( rc != 0 )); then
		failed+=("${test_file:t} (status ${rc})")
	fi
done

print -r -- "=== ${#test_files} test file(s), ${#failed} failed"
if (( ${#failed} > 0 )); then
	print -rl -- "FAILED: "${^failed}
	exit 1
fi
exit 0
