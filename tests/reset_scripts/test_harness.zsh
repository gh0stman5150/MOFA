#!/bin/zsh --no-rcs
# Self-test for harness.zsh: stubs deny by default, record argv, the command scan finds
# absolute paths, and sourcing detects top-level side effects. Uses synthetic scripts only.
# Run as an unprivileged user: zsh tests/reset_scripts/test_harness.zsh (or run_all.zsh).

source "${0:A:h}/harness.zsh"

T_FIXTURES="$MOFA_TEST_ROOT/fixtures"
mofa_mkdir "$T_FIXTURES"

# Runs "$@" with assertion results diverted, so a deliberately failing harness check can be
# inspected without failing this test. Prints the diverted results.
t_expect_failure() {
	local saved="$MOFA_RESULTS"
	MOFA_RESULTS="$MOFA_TEST_ROOT/out/diverted.results"
	: >| "$MOFA_RESULTS"
	"$@" >/dev/null 2>&1
	MOFA_RESULTS="$saved"
	print -r -- "$(<"$MOFA_TEST_ROOT/out/diverted.results")"
}

mofa_case "sandbox, HOME and PATH"
[[ "$MOFA_TEST_ROOT" == /?*/mofa_reset_tests.?????? && -d "$MOFA_TEST_ROOT" ]] \
	&& mofa_pass "sandbox exists" || mofa_fail "sandbox exists"
mofa_assert_eq "$MOFA_SANDBOX_BASE" "${MOFA_TEST_ROOT:h}" "the test root is inside the sandbox base"
mofa_assert_eq "$MOFA_TEST_ROOT/home" "$HOME" "HOME is inside the sandbox"
mofa_assert_eq "$MOFA_TEST_ROOT/tmp/" "$TMPDIR" "TMPDIR is inside the sandbox"
mofa_assert_eq "$MOFA_TEST_ROOT/tmp/zsh" "$TMPPREFIX" "zsh temp files stay inside the sandbox"
mofa_assert_eq "$MOFA_TEST_ROOT/nopath" "$PATH" "PATH holds no executables"
mofa_assert_eq "$MOFA_TEST_ROOT" "$PWD" "the working directory is the sandbox"

if (( MOFA_KERNEL_SANDBOX )); then
	mofa_case "the kernel sandbox confines exec, writes and signals"
	mofa_assert_eq "$MOFA_SANDBOX_BASE" "$MOFA_KERNEL_SANDBOX_BASE" "the sandbox base came from the outer stage"
	# Probes are harmless if the sandbox were missing: true does nothing, SIGURG is ignored by
	# default, and an unexpected probe file is removed again.
	command /usr/bin/true 2>/dev/null
	(( $? != 0 )) && mofa_pass "a program outside the allow-list cannot run" \
		|| mofa_fail "a program outside the allow-list cannot run"
	command /usr/bin/id -u >/dev/null 2>&1
	(( $? != 0 )) && mofa_pass "system tools such as id cannot run" || mofa_fail "system tools such as id cannot run"
	probe="${MOFA_SANDBOX_BASE:h}/mofa_reset_write_probe.$$"
	if ( print -r -- probe >| "$probe" ) 2>/dev/null; then
		command /bin/rm -f -- "$probe"
		mofa_fail "a write outside the sandbox base is denied"
	else
		mofa_pass "a write outside the sandbox base is denied"
	fi
	print -r -- inside >| "$MOFA_TEST_ROOT/inside" && mofa_pass "a write inside the sandbox works" \
		|| mofa_fail "a write inside the sandbox works"
	builtin kill -URG "$PPID" 2>/dev/null && mofa_fail "signals to other processes are denied" \
		|| mofa_pass "signals to other processes are denied"
	mofa_assert_eq "here" "$(command /bin/cat <<< here)" "here-strings and allow-listed tools work"
else
	mofa_case "the kernel sandbox is disabled"
	mofa_pass "MOFA_ALLOW_NO_KERNEL_SANDBOX=1 disabled the kernel sandbox; only function stubs apply"
fi

mofa_case "default stubs record argv and never run the real command"
keep="$MOFA_TEST_ROOT/keep me"
mofa_mkdir "$keep"
/bin/rm -rf -- "$keep"
rm -rf -- "$keep"
/usr/bin/sudo -u nobody /bin/rm -rf /
/bin/launchctl bootout system/com.example.test
[[ -d "$keep" ]] && mofa_pass "the directory survives stubbed rm" || mofa_fail "the directory survives stubbed rm"
mofa_assert_called /bin/rm -rf -- "$keep"
mofa_assert_called rm -rf -- "$keep"
mofa_assert_called /usr/bin/sudo -u nobody /bin/rm -rf /
mofa_assert_eq 4 "$(mofa_call_count)" "four calls recorded"
mofa_assert_eq 1 "$(mofa_call_count /bin/rm)" "calls are filtered by command"

mofa_case "stub status, output and handlers"
mofa_stub /usr/bin/defaults 3 "value"
out="$(/usr/bin/defaults read x y)"
rc=$?
mofa_assert_eq "value" "$out" "stub output"
mofa_assert_eq 3 "$rc" "stub status"
t_handler() { print -r -- "handled:$#:$2"; return 4; }
mofa_stub_handler /usr/bin/defaults t_handler
out="$(/usr/bin/defaults read "a b")"
rc=$?
mofa_assert_eq "handled:2:a b" "$out" "handler receives the argv"
mofa_assert_eq 4 "$rc" "handler status is the stub status"
mofa_reset_stubs
out="$(/usr/bin/defaults read x)"
rc=$?
mofa_assert_eq "" "$out" "reset stubs print nothing"
mofa_assert_eq 0 "$rc" "reset stubs return the default status"

mofa_case "an unstubbed external command is reported, not run"
results="$(t_expect_failure ls "$MOFA_TEST_ROOT")"
mofa_assert_contains "$results" "not ok	unstubbed command was called: ls" "an unstubbed command fails the test"
mofa_assert_contains "$(mofa_calls)" "!notfound ls" "the attempt is logged"

mofa_case "passthrough is limited to read-only text filters"
mofa_stub_passthrough /usr/bin/awk
mofa_assert_eq "b" "$(print -r -- 'a b' | /usr/bin/awk '{ print $2 }')" "awk passthrough works"
results="$(t_expect_failure mofa_stub_passthrough /usr/bin/xargs)"
mofa_assert_contains "$results" "not ok	harness refused passthrough for /usr/bin/xargs" "xargs is refused"
results="$(t_expect_failure mofa_stub_passthrough /bin/rm)"
mofa_assert_contains "$results" "not ok	harness refused passthrough for /bin/rm" "rm is refused"
results="$(t_expect_failure /usr/bin/awk 'BEGIN { system("echo unsafe") }')"
mofa_assert_contains "$results" "not ok	harness refused awk passthrough program" "awk system() is refused"
mofa_stub_passthrough /usr/bin/sed
results="$(t_expect_failure /usr/bin/sed -i '' 's/a/b/' "$MOFA_TEST_ROOT/x")"
mofa_assert_contains "$results" "not ok	harness refused sed passthrough argument: -i" "sed -i is refused"

mofa_case "mofa_scan_commands finds absolute command paths"
mofa_write_file "$T_FIXTURES/scan.zsh" '#!/bin/zsh --no-rcs
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
x=$(/usr/bin/awk "{print}" | /usr/sbin/scutil)
"${PREFIX}/usr/local/bin/jq" .
/usr/libexec/PlistBuddy -c Print "$plist"
"/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate" --list
"$HOME/Contents/MacOS/dynamic" --skip'
scanned="$(mofa_scan_commands "$T_FIXTURES/scan.zsh")"
for expected in /bin/zsh /usr/bin/awk /usr/sbin/scutil /usr/local/bin/jq /usr/libexec/PlistBuddy \
	"/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"; do
	mofa_assert_contains $'\n'"${scanned}"$'\n' $'\n'"${expected}"$'\n' "scan finds ${expected}"
done
mofa_assert_not_contains "$scanned" "dynamic" "paths built from variables are not guessed"
mofa_assert_not_contains $'\n'"${scanned}"$'\n' $'\n'"/usr/bin"$'\n' "directories alone are not commands"

mofa_case "mofa_source_script stubs scanned paths and honours the guard"
mofa_write_file "$T_FIXTURES/guarded.zsh" '#!/bin/zsh --no-rcs
SETTING="default"
helper() { "/Applications/Fixture.app/Contents/MacOS/fixture" --run "$1"; }
main() { /usr/bin/touch "$HOME/ran"; helper "$4"; }
if [[ "${ZSH_EVAL_CONTEXT}" != *:file ]]; then main "$@"; fi'
mofa_source_script "$T_FIXTURES/guarded.zsh"
mofa_assert_source_clean
mofa_assert_eq "default" "$SETTING" "top-level defaults are set"
helper value
mofa_assert_called /Applications/Fixture.app/Contents/MacOS/fixture --run value
mofa_run main a b c d
mofa_assert_called /usr/bin/touch "$HOME/ran"
[[ ! -e "$HOME/ran" ]] && mofa_pass "stubbed touch created nothing" || mofa_fail "stubbed touch created nothing"

mofa_case "the guard line runs main with Jamf's parameters when the file is executed"
mofa_write_file "$T_FIXTURES/executed.zsh" "#!/bin/zsh --no-rcs
main() { print -r -- \"main ran with \$# parameters; 4=[\$4]\"; exit 7; }
${MOFA_GUARD_LINE}"
child_output="$(command /bin/zsh --no-rcs "$T_FIXTURES/executed.zsh" / computer alice "MODE= Repair " 2>&1)"
child_status=$?
mofa_assert_eq "main ran with 4 parameters; 4=[MODE= Repair ]" "$child_output" "executing the file runs main \"\$@\""
mofa_assert_eq 7 "$child_status" "main's exit status is the script's exit status"

mofa_case "mofa_source_script reports top-level commands, output and traps"
mofa_write_file "$T_FIXTURES/noisy.zsh" '#!/bin/zsh --no-rcs
echo "starting"
/usr/bin/pkill -9 Fixture
trap "/bin/rm -rf -- /tmp/x" INT
main() { :; }'
mofa_source_script "$T_FIXTURES/noisy.zsh"
mofa_assert_eq "starting" "$MOFA_SOURCE_OUTPUT" "top-level output is captured"
mofa_assert_called /usr/bin/pkill -9 Fixture
mofa_assert_eq 1 "$MOFA_SOURCE_TRAPS_CHANGED" "a top-level trap is detected"
trap - INT
results="$(t_expect_failure mofa_assert_source_clean)"
mofa_assert_contains "$results" "not ok	last line is the source guard" "a missing guard fails"
mofa_assert_contains "$results" "not ok	sourcing prints nothing" "top-level output fails"
mofa_assert_contains "$results" "not ok	sourcing runs no stubbed command" "top-level commands fail"
mofa_assert_contains "$results" "not ok	sourcing sets no trap" "top-level traps fail"

mofa_case "a script that exits while sourced aborts its test with a clear message"
mofa_write_file "$T_FIXTURES/exits.zsh" '#!/bin/zsh --no-rcs
exit 1'
mofa_write_file "$T_FIXTURES/test_exits.zsh" "source ${(q)MOFA_HARNESS_DIR}/harness.zsh
mofa_source_script ${(q)T_FIXTURES}/exits.zsh
mofa_pass unreachable
mofa_finish"
# The child shares this kernel sandbox (or its opt-out) and creates its own test root.
child_output="$(command /usr/bin/env -i HOME="$HOME" TMPDIR="$TMPDIR" PATH=/usr/bin:/bin \
	MOFA_KERNEL_SANDBOX_BASE="${MOFA_KERNEL_SANDBOX_BASE:-}" \
	MOFA_ALLOW_NO_KERNEL_SANDBOX="${MOFA_ALLOW_NO_KERNEL_SANDBOX:-}" \
	/bin/zsh --no-rcs "$T_FIXTURES/test_exits.zsh" 2>&1)"
child_status=$?
mofa_assert_eq 1 "$child_status" "the child test fails"
mofa_assert_contains "$child_output" "the script exited while being sourced" "the reason is reported"
mofa_assert_not_contains "$child_output" "unreachable" "nothing after the exit runs"

mofa_finish
