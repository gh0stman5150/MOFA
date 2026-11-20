#!/bin/zsh --no-rcs

# ============================================================
# Script Name: MOFA_Community_Microsoft_Outlook_Data_Removal.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Removes the Microsoft Outlook Data
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
# 1.1.0 - MOFA refresh: require a console user with a home under /Users, guard removal targets,
#         and return nonzero when a removal fails. Removed unused helpers.
# 1.2.0 - All work now runs from main(), which starts only when the file is executed (as Jamf
#         does); sourcing the file only defines its functions, so tests can exercise them with
#         stubbed commands. Messages, exit codes and the order of operations are unchanged.
# 1.3.0 - Security: removals use zsh's own rm in paranoid mode (zf_rm -s), which refuses a
#         symbolic link the console user planted in any folder above or below a target (for
#         example ~/Library/Containers), even one swapped in while it runs; a refusal fails the
#         policy. A locked or read-only file that zf_rm would leave in place also fails the
#         policy, and a target ending in "/", "." or ".." is refused as unsafe. The console
#         user's home is no longer exported to root's child processes.
#
# Jamf parameters: none. Parameters 4 and later are ignored.
#
# WARNING: permanently deletes the console user's local Outlook data store
# (~/Library/Group Containers/UBF8T346G9.Office/Outlook), including "On My Computer" mail.
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

REMOVAL_FAILURES=0

RequireRoot() {
	if [[ $EUID -ne 0 ]]; then
		echo "Office-Reset: This script must be run as root." >&2
		exit 1
	fi
}

FinishRun() {
	if (( REMOVAL_FAILURES > 0 )); then
		echo "Office-Reset: Completed with ${REMOVAL_FAILURES} removal failure(s)" >&2
		exit 1
	fi
	exit 0
}

GetLoggedInUser() {
	/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && !/loginwindow/ { print $3 }'
}

SetHomeFolder() {
	local target_user="$1"

	# HOME holds the console user's home for the path lists, but root's child processes must not
	# inherit it (curl, for example, would read that user's ~/.curlrc), so it stays unexported.
	typeset -g +x HOME
	LoggedInUserID=""
	if [[ -z "$target_user" || "$target_user" == "root" || "$target_user" == "_mbsetupuser" ]]; then
		LoggedInUser=""
		HOME="/var/empty"
		return 0
	fi

	HOME=$(/usr/bin/dscl . -read "/Users/${target_user}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk -F': ' 'NR==1 { print $2 }')
	if [[ -z "$HOME" && -d "/Users/${target_user}" ]]; then
		HOME="/Users/${target_user}"
	fi
	if [[ "$HOME" != /Users/?* || ! -d "$HOME" ]]; then
		echo "Office-Reset: Home folder for ${target_user} is not under /Users; skipping user data" >&2
		LoggedInUser=""
		HOME="/var/empty"
		return 1
	fi

	LoggedInUserID=$(/usr/bin/id -u "$target_user" 2>/dev/null)
}

removeTarget() { # $1: rm option (-rf or -f), $2: target
	local target="$2"
	local physical_target physical_parent component component_path="" zf_output
	local -i linked=0 zf_status

	if [[ -z "$target" || "$target" == "/" || "$target" != /* || "$target" == */ \
		|| "${target:t}" == "." || "${target:t}" == ".." ]]; then
		echo "Office-Reset: Refusing to remove unsafe path '${target}'" >&2
		(( REMOVAL_FAILURES++ ))
		return 1
	fi
	if [[ ! -e "$target" && ! -L "$target" ]]; then
		echo "Office-Reset: Skipping missing path $target"
		return 0
	fi
	# The console user owns the folders in their home and temp folder and could replace one with a
	# symbolic link (for example ~/Library/Containers -> another user's Library/Containers) to make
	# root delete data elsewhere. zsh's own rm in paranoid mode (zf_rm -s) refuses a link in any
	# folder above or below the target and checks each folder it enters, so a link swapped in while
	# it runs is refused too. macOS's /var, /tmp and /etc links are resolved first, as zf_rm -s
	# would refuse them.
	if ! zmodload -F zsh/files b:zf_rm 2>/dev/null; then
		echo "Office-Reset: Failed to remove $target: zsh's files module is unavailable" >&2
		(( REMOVAL_FAILURES++ ))
		return 1
	fi
	physical_target="$target"
	case "$physical_target" in
		/var/*|/tmp/*|/etc/*) physical_target="/private${physical_target}" ;;
	esac
	echo "Office-Reset: Removing $target"
	# zf_rm asks before deleting a locked or read-only file; with no answer it keeps the file and
	# still succeeds, so its question counts as a failure.
	zf_output="$( ( zf_rm "${1//f/}s" -- "$physical_target" ) </dev/null 2>&1 )"
	zf_status=$?
	[[ -n "$zf_output" ]] && print -r -- "$zf_output" >&2
	if (( zf_status != 0 )) || [[ "$zf_output" == *"overriding mode"* ]]; then
		physical_parent="${physical_target:h}"
		for component in ${(s:/:)physical_parent}; do
			component_path+="/${component}"
			[[ -L "$component_path" ]] && linked=1
		done
		if (( linked )); then
			echo "Office-Reset: Refusing to remove $target: a folder in its path is a symbolic link" >&2
		elif [[ "$zf_output" == *"overriding mode"* ]]; then
			echo "Office-Reset: Failed to remove $target: it holds a locked or read-only file" >&2
		else
			echo "Office-Reset: Failed to remove $target" >&2
		fi
		(( REMOVAL_FAILURES++ ))
		return 1
	fi
}

removePathList() {
	local target
	for target in "$@"; do
		removeTarget -rf "$target"
	done
}

removeFileList() {
	local target
	for target in "$@"; do
		removeTarget -f "$target"
	done
}

main() { # Jamf passes $1-$3; this script has no custom parameters
	echo "Office-Reset: Starting postinstall for Remove_Outlook_Data"
	RequireRoot

	LoggedInUser=$(GetLoggedInUser)
	SetHomeFolder "$LoggedInUser"
	if [[ -z "$LoggedInUser" ]]; then
		echo "Office-Reset: No eligible console user with a home under /Users; skipping Outlook data removal"
		exit 0
	fi
	echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME"

	/usr/bin/pkill -9 'Microsoft Outlook'

	removeFileList \
		"$HOME/Library/Preferences/com.microsoft.Outlook.plist" \
		"$HOME/Library/Group Containers/UBF8T346G9.Office/OutlookProfile.plist"

	removePathList "$HOME/Library/Group Containers/UBF8T346G9.Office/Outlook"

	FinishRun
}

# Run only when executed (Jamf). Sourcing this file, as tests/reset_scripts does, defines functions only.
if [[ "${ZSH_EVAL_CONTEXT}" != *:file ]]; then main "$@"; fi
