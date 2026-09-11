---
title: MOFA Maintenance and Contributions
description: Feed generation, endpoint tools and validation workflow.
---

## Instruction authority

[AGENTS.md](AGENTS.md) is the authoritative contributor instruction file.
This guide remains the human-oriented maintenance reference; keep its commands
and workflow descriptions consistent with AGENTS.md and its nested guide.

## Source and generated content

MOFA combines Python feed generators, Microsoft application reset tools,
configuration profiles and static assets. The generator runner is
.github/actions/run_generators.py; .github/actions/update_readme.py produces
the root README. Change generated prose in that template. Do not hand-edit
release tables or use cached versions as proof of the latest vendor release.
Keep operational guidance here and in directory READMEs.

## Development and validation

From this repository, use Python 3.13 to match CI and an isolated environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r .github/requirements.txt
python -m compileall -q .github/actions tests
python -m pytest -q
```

On macOS, syntax-check changed community scripts individually with /bin/zsh -n.
Active scripts must start with #!/bin/zsh --no-rcs. Tests cover HTTP helpers,
generated-data consistency, automation helpers and shell safety. Mock services
for regression tests; do not run live reset scripts as tests.

## Data refresh

workflow_all_xml_updates.yml validates pushes and pull requests matching its
path filters. Its schedule is minute 3 of each hour. Only scheduled and manual
runs enter the update job, which generates data, validates it and opens or
updates automation/mofa-generated-data when changes exceed timestamps.
It does not automatically merge that PR. The update job uses GitHub token
permissions for contents and pull requests; generators need no Jamf credentials.

For an intentional local refresh with network access:

```bash
python .github/actions/run_generators.py
python -m pytest -q
git diff -- README.md latest_raw_files
```

Review product identities, missing fields, URLs and timestamps before merging.
For stale data, inspect workflow results and the pending update PR; an hourly
schedule does not guarantee hourly publication.

## Endpoint tools

Deploy reviewed scripts from
[community scripts](office_reset_tools/mofa_community_maintained/scripts/README.md).
They run as root on macOS; user-data resets require an eligible console user.
That directory's README describes parameters, modes and logging.
The community packages directory contains documentation only.
Archived scripts/packages preserve historical provenance.

Review mobileconfig payload scope and values before MDM deployment. Resets,
removal and reinstall can affect user data; validate on a disposable managed
Mac with recovery available before expanding policy scope.

## Contributions and ownership

Describe the problem, final behavior, test results and remaining endpoint
validation in PRs. Keep generators and output consistent. Preserve
[LICENSE](LICENSE) and upstream attribution. Do not commit secrets or
identifying logs. Use this checkout's configured issue tracker for defects;
internal deployment ownership and on-call support are not declared here.
