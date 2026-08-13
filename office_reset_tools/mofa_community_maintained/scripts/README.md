# MOFA Scripts  

These scripts were originally sourced from package files like `Microsoft_Office_Reset_2.0.0.pkg` from *Office-Reset.com*, created by Paul Bowden. Since *Office-Reset.com* is no longer maintained, the MOFA and Mac Admin communities have taken over their maintenance, ensuring continued updates and improvements.  

We encourage users to contribute, enhance, fork, and suggest fixes to help refine these scripts for the community. In the future, we also plan to provide packaged versions of these scripts for easier deployment and use.

**Notes:** Currently, `cocopuff2u`, the maintainer of MOFA, does not have a developer account to sign packages, and their experience with building and signing packages has not yet been tested. While confident in their ability to handle it, they would appreciate guidance from someone experienced in the process. They prefer to maintain control over package signing to ensure the integrity and security of the packages, preventing any malicious alterations.

## Jamf Pro deployment

Upload the script source directly to a Jamf Pro Script object; no sibling files are required. Run the policy as root and use a login or Self Service trigger because user-data reset scripts require a valid console user with a home under `/Users`.

For `MOFA_Community_Microsoft_Teams_Reset.zsh`, parameter 4 may be `MODE=reset`, `MODE=repair`, `MODE=reinstall`, or `MODE=force`. Parameter 5 may be `INSTALL=force`. The default `reset` mode removes Teams user state without installing the app. Repair/reinstall modes validate the Microsoft package signature, and any cleanup or installation failure returns a nonzero status to Jamf.

Do not pass shell expressions or secrets as parameters. Unsupported arguments are rejected rather than evaluated.
