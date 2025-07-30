## `extract_rocky_iso_for_pxe`

Contained in `lib/functions.d/iso-functions.sh`

### Function overview
The function `extract_rocky_iso_for_pxe` is designed to extract an ISO file of a specific version of Rocky Linux for PXE. It takes in three parameters: the path of the ISO file, the version of the Linux distribution, and the CPU architecture. This function creates a directory based on the parameters given, then attempts to extract the contents of the ISO file into this new directory. If neither `bsdtar` nor `fuseiso` commands are available, it will output an error message and return a non-zero exit status.

### Technical description

- **Name:** `extract_rocky_iso_for_pxe`
- **Description:** This function extracts an ISO for PXE given the location of the ISO, its version, and CPU architecture type. It primarily makes use of bsdtar and fuseiso to perform the extraction.
- **Globals:** `HPS_DISTROS_DIR`: The base directory where the content is extracted.
- **Arguments:** 
    - `$1`: The location of the ISO file to extract.
    - `$2`: The version of the Linux distribution.
    - `$3`: The type of CPU architecture.
- **Outputs:** Prints out information on the extraction process and the location the content is extracted to. In case of errors, it prints out an appropriate error message.
- **Returns:** Returns `1` if either `bsdtar` or `fuseiso` are not found, otherwise nothing.
- **Example usage:** `extract_rocky_iso_for_pxe "/path/to/iso" "8.4" "x86_64"`

### Quality and security recommendations

1. The function should check the existence of the provided ISO path before attempting extraction.
2. It should validate the input arguments to prevent potential code vulnerabilities.
3. The code might use a switch case instead of multiple `if` conditions to choose the extraction program.
4. To improve execution transparency, consider using standardized logging methods instead of `echo`. 
5. Additionally, the function should handle potential cleanup upon encountering an error to leave the system in a clean state. 
6. Make the function more secure by providing file and directory permissions when they're created.
7. Use absolute paths when performing operations to avoid relative path vulnerabilities.

