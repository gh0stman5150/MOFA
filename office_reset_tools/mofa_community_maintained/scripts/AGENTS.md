---
title: MOFA Jamf Reset Script Guidance
description: Endpoint-specific invariants and validation for active reset tools.
---

## Scope and authority

This file owns contributor guidance for active community reset scripts in
this directory. For repository layout and Python test context, see
[MOFA AGENTS.md](../../../AGENTS.md). In MacProjects, shared rules are in the
[workspace AGENTS.md](../../../../AGENTS.md#shared-rules).
[README.md](README.md) owns the operator parameter and log reference.

## Jamf execution requirement

Every active endpoint script here must run successfully through Jamf Pro
as root using #!/bin/zsh --no-rcs. Scripts upload directly as Script objects
and must be standalone, without sibling files or a developer checkout.
No terminal or interactive privilege elevation may be required.

User-data reset operations require an eligible console user with a home
under /Users. Preserve existing user/home validation and cancellation/skip
behavior. Use Self Service or login context for these operations.

## Parameters, safety and error handling

- Preserve each script's argument parser. Custom inputs begin at $4; most
  reset tools accept reset/repair/reinstall/force. Teams variants have their
  own KEY=value contracts. Do not evaluate parameters as shell code.
- Keep signature validation for downloaded Microsoft packages and explicit
  nonzero exits for download, cleanup and installation failures.
- Reset/removal can delete user state or credentials. Preserve target/path
  safeguards and validate changes on a disposable managed Mac with recovery.
- Repair/reinstall can keep the policy active until installation completes.
  Do not describe these scripts as background-only operations.
- Keep Teams removal/reinstall's dedicated log and other scripts' Jamf policy
  output as documented. Do not replace failures with blanket success exits.
- Extend active scripts here; historical archived copies are references.

## Validation and changes

From this directory on macOS, run the following in Bash:

```bash
for script in ./*.zsh; do
  test "$(head -n 1 "$script")" = '#!/bin/zsh --no-rcs' || exit 1
  /bin/zsh -n "$script" || exit 1
done
```

Run repository-level pytest as described in the parent guide, including its
shell-safety tests. Update script comments and this directory's README when
modes, logging or dependency behavior changes. Syntax and static tests do not
replace live Jamf validation, and ShellCheck is not a Zsh validator.
