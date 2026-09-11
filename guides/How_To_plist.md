---
title: Reviewing and Deploying macOS Preferences
description: Repository profile examples, MDM deployment formats and verification.
---

## Repository inputs

Review the XML files in [mobileconfig_profiles](../mobileconfig_profiles/)
before deployment. They contain full configuration-profile payloads, not just
application preference dictionaries. For example, the Outlook privacy profile
targets com.microsoft.Outlook and contains telemetry and feedback settings.
A setting's presence in this repository does not establish support in every
application version. Preserve intended scope and review payload identifiers.

From the MOFA directory on macOS, inspect syntax and payload content:

```bash
plutil -lint mobileconfig_profiles/MOFA_outlook_user_privacy.mobileconfig
plutil -p mobileconfig_profiles/MOFA_outlook_user_privacy.mobileconfig
```

Syntax validation does not establish that an application supports a preference
or that the MDM service will accept the payload. Review the app's supported
keys and verify behavior on a managed test Mac.

## Deployment formats

Keep a complete mobileconfig profile separate from an application's plist or
a preference-file fragment. Select the matching MDM payload/import workflow;
do not upload one format into a field expecting another.

For Intune's macOS Preference file template, supply the preference domain and
the key/value content in a plist or XML file without outer dict/plist/XML
wrappers. This template targets device-channel settings. Intune does not
validate the app settings; test before assignment. See the
[Microsoft preference-file instructions](https://learn.microsoft.com/en-us/intune/device-configuration/templates/configure-preference-file-macos)
for the current import flow.

For Jamf, select a configuration-profile workflow appropriate to the full
profile or the application preference data being deployed. Review target
scope and prevent competing profiles from managing the same key. This
repository does not automate tenant configuration or provide tenant credentials.

## Verification and troubleshooting

Check the MDM profile delivery result, installed payload and application
behavior in the intended user session. A defaults read result or a file in a
preferences directory alone does not prove an MDM-enforced setting took effect.

For failures, check payload syntax, application domain, supported preference
keys, scope, conflicting profiles and device connectivity. Files under
/Library/Preferences are local preferences; placing a file there does not
make it an MDM-managed profile. Managed settings may have device or user scope,
so avoid assuming one path or one user context covers every payload.

Record the tested app/macOS versions and observed result in the change.
Keep deployment secrets and device-identifying logs out of Git.
