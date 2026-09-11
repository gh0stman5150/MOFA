---
title: MOFA Generated Feeds
description: Generated application metadata and update lifecycle.
---

## Contents

This directory contains generated standalone application and Apple App Store
metadata in XML, JSON and YAML, plus RSS feeds in macos_standalone_rss.
Datasets cover release channels, update and vulnerability history, and
OneDrive/Edge version collections.

## Generation and freshness

Sources live in [the generator directory](../.github/actions/).
[The update workflow](../.github/workflows/workflow_all_xml_updates.yml)
runs on a minute-3 hourly schedule and supports manual execution.
Validated substantive updates create or update a PR; default-branch data
changes only after merge. Timestamp-only changes do not create an update PR.

Read dataset timestamps before use. Cached files do not guarantee current
vendor versions. Inspect generator output and validation when a product or
version appears inconsistent.

Do not hand-edit generated datasets. See
[maintenance instructions](../CONTRIBUTING.md) for dependencies and refresh
commands. This directory accepts no Jamf parameters and creates no endpoint log.
