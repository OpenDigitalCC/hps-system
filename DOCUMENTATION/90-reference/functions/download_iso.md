#### `download_iso`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: a769efc53df917e64e3dbdfb8acb70dff4b4cb4a89efd3b55a689c47cde86e91

##### Function overview

The function `download_iso` downloads an ISO image of a specific Operating System version for a given CPU architecture from the Internet. It stores the downloaded ISO image in a predefined directory and name. Currently, it only supports the `rockylinux` Operating System variant. If an ISO image that matches the provided parameters already exists in the target directory, the function does not attempt to download it again, instead serving the existing copy.

##### Technical description

- **name**: download_iso
- **description**: A Bash function that downloads an ISO image from the web and saves it in a specific local directory.
- **globals**: `N/A`
- **arguments**: [ 
  - `$1`: CPU - The architecture of the CPU (e.g., x86_64),
  - `$2`: MFR - Manufacturer identifier (currently not used in the function),
  - `$3`: OSNAME - The name of the Operating System variant,
  - `$4`: OSVER - The version of the Operating System ]
- **outputs**: Prints messages about the status of the executed operations
- **returns**: 
  - `0` if function executes successfully.
  - `1` if unsupported OS variant is provided or if the function fails to download the ISO image.
- **example usage**: `download_iso x86_64 intel rockylinux 10`

##### Quality and Security Recommendations

1. The function should validate its input parameters to ensure they adhere to a predetermined format or regex, preventing potential errors in filename construction.
2. The function should support more OS variants, or perhaps have a mechanism for easily adding and managing support for new OS variants.
3. Currently, the function does not perform any action with the `mfr` argument. It should either be used or removed to avoid confusion.
4. The function could include functionality to handle various error states more gracefully. For example, if the directory creation or ISO download process fails, it should capture the exact error and possibly attempt to resolve it.
5. Add checksum verification for ISO images after download for enhanced integrity and security assurance.
6. Since the function seems to be designed to handle sensitive data (Operating System ISO images), it could incorporate some mechanisms for security-hardening, such as encryption of the downloaded ISO image.

