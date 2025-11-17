### `verify_rocky_checksum_signature`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: c29ccb47fbd2f30ffd999a0dbdad086aae4efbf33487b193102452f5f4b62cab

### Function Overview

The function `verify_rocky_checksum_signature()` is designed for verifying the checksum and signature of the downloaded Rocky Linux ISO in order to ensure its accuracy and safety. It requires a version number as an argument to specify which version of Rocky Linux for validation. The function firstly downloads the GPG key from Rocky Linux's official website. Then it uses this GPG key to verify the signature of the downloaded ISO CHECKSUM. Finally, it calculates and compares the SHA256 checksum of the downloaded ISO with the expected checksum obtained from the server.

### Technical Description

- **Name:** `verify_rocky_checksum_signature()`
- **Description:** This function verifies the GPG signature of the CHECKSUM file of a particular downloaded Rocky Linux ISO. It also computes the SHA256 checksum of the downloaded ISO file and compares this calculated checksum against the server provided expected checksum.
- **Globals:** 
  - `arch: x86_64` Architecture of the system
  - `base_url: https://download.rockylinux.org/pub/rocky/${version}/${arch}/iso/` The base url from which the ISO and other resources will be downloaded
  - `target_dir: "$(_get_distro_dir)/rocky"` The directory where the ISO is stored after downloading
- **Arguments:** 
  - `$1: version` The version of Rocky Linux ISO to be verified 
- **Outputs:** Status messages about ongoing process, checksum mismatch errors, GPG key import errors and GPG signature verification errors
- **Returns:** 0 when GPG signature and checksum verification are successful, 1 when GPG key import fails, 2 when GPG signature verification fails, 3 when expected checksum is not found in the downloaded CHECKSUM file, 4 when the received and computed checksums of the ISO mismatch.
- **Example Usage:** `verify_rocky_checksum_signature 8.4`

### Quality and Security Recommendations

1. Implement additional error handling and logging to provide more detailed feedback if the GPG key download fails or if incorrect input is provided.
2. Before proceeding, validate the URL where the GPG key will be downloaded.
3. Introduce tests to ensure SHA256SUM algorithm's reliability used in the computation of the received ISO checksum.
4. Update the GPG key in a regular basis in case it has been updated by the server and consider a secure key handling.
5. Make sure the directory and the ISO file path are valid and secured and have the write permission. 
6. Check the availability of the `curl`, `gpg` and `sha256sum` tools before execution.

