---
title: Checking Downloaded File Integrity
description: Comparing SHA256 checksums for macOS package downloads.
---

## Verify a downloaded file

From a directory containing a downloaded package on macOS:

```bash
shasum -a 256 "downloaded-package.pkg"
```

Compare the complete 64-character hexadecimal result with the expected checksum
obtained through a trusted source for that exact file. A match establishes
agreement with that checksum; a checksum alone does not identify the publisher.

To download, replace the example URL and output name with the intended package:

```bash
curl --fail --location --output "downloaded-package.pkg" "https://example.com/package.pkg"
shasum -a 256 "downloaded-package.pkg"
```

The URL is illustrative. Do not install the example or a file whose checksum
differs. Check the intended version and download source before retrying.
Where a deployment script validates a package signature, retain that validation
as well as any checksum check.

MOFA release checksums are generated data. Check dataset timestamps and the
update workflow before relying on a cached value; a moving vendor download URL
can serve a different file after the dataset was generated. See
[maintenance instructions](../CONTRIBUTING.md).
