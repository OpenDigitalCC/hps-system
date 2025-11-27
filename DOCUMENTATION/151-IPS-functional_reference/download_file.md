### `download_file`

Contained in `lib/functions.d/system-functions.sh`

Function signature: 77275d6db2a730d2f09e1f7111242d9607b215be97269a81302557f4e047a820

### Function Overview

`download_file` is a Bash function designed to download a file from the provided URL to the specified destination path. The function uses either `curl` or `wget` based on availability and supports resuming interrupted downloads. If provided, the function verifies the checksum of the downloaded file using `sha256sum`. If an error is encountered (missing arguments, failure to create the destination directory, download failure, or checksum mismatch), the function will log the error and return a non-zero exit code.

### Technical Description

- **Name:** `download_file`
- **Description:** Bash function to download a file from a URL to a specified destination path, with optional SHA256 checksum verification.
- **Globals:** None.
- **Arguments:**
  - `$1: url` - The URL of the file to be downloaded.
  - `$2: dest_path` - The destination path where the downloaded file will be placed.
  - `$3: expected_sha256` - (Optional) The expected SHA256 checksum of the downloaded file.
- **Outputs:** Information, warning and error logs.
- **Returns:** 0 if the file is successfully downloaded and the checksum (if provided) matches. 1 if necessary tools are missing or required arguments are not provided, 2 if any operation (e.g., directory creation or file download) fails, and 3 if the checksum does not match.
- **Example Usage:**

```bash
download_file "https://example.com/test.txt" "/path/to/test.txt" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
```

### Quality and Security Recommendations

1. The `download_file` function currently lacks input validation. Malformed or malicious values for the URL or destination path could lead to unexpected behavior or security risks.
2. The function silently falls back to `wget` if `curl` is not available. Explicitly specifying the desired tool or alerting the user to the fallback could improve transparency and control.
3. If `sha256sum` is not available, the function logs a warning but continues the download. It might be preferable to fail outright to support secure environments where checksum verification is required.
4. The function only supports SHA256 for checksums. Supporting additional or newer checksum methods could improve versatility and security.
5. It may be worth considering a timeout for the download operation, to prevent hanging in the case of a slow or unresponsive server.

