#### `extract_rocky_iso_for_pxe`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 52e8a2e1e3a65096a2e0e1ac3696f4c21521a7cc3c3b006a7056ede3446b2ada

##### Function Overview

The `extract_rocky_iso_for_pxe` function is designed to automate the process of extracting the ISO image files of Rocky Linux for PXE (Preboot eXecution Environment). This function takes in the path to the ISO file, the Linux version, and the CPU architecture as arguments. The files are then extracted to a specific directory, which is determined by the provided parameters. The function supports both the `bsdtar` and `fuseiso` commands for this extraction process.

##### Technical Description

- **Name**: `extract_rocky_iso_for_pxe`
- **Description**: Extracts a Rocky Linux ISO for PXE
- **Globals**: `[ HPS_DISTROS_DIR: A directory for distribution versions, CPU: Processor architecture, MFR: Manufacturer (in this case 'linux'), OSNAME: Operating system name (in this case 'rockylinux'), OSVER: Operating system version, extract_dir: Extraction directory path ]`
- **Arguments**: `[ $1: iso_path (Path to ISO file), $2: version (Linux version), $3: CPU (CPU architecture) ]`
- **Outputs**: Extracted ISO file for PXE
- **Returns**: 1 if neither `bsdtar` nor `fuseiso` is found, otherwise nothing
- **Example usage**: `extract_rocky_iso_for_pxe "/path/to/iso" "8" "x86_64"`

##### Quality and Security Recommendations

1. Add more error checks and possibly introduce handling for different edge cases, such as invalid inputs or read/write errors.
2. The function requires a significant amount of system memory to mount and process the files. Make sure to free up space or manage memory effectively.
3. Always check the source of the ISO image download to ensure it is a trustworthy site.
4. Given the function's role in setting up a booting environment, it's especially important to ensure the integrity and authenticity of the ISO images.
5. Consider integrating a log mechanism to track the performance of the function in case of troubleshooting.
6. Implement a way to check if the created directories already exist to avoid overwriting any previous versions.
7. Include more informative and user-friendly messaging to communicate the function's process and outcomes to the user.
8. Make sure the `HPS_DISTROS_DIR` variable is defined and valid before executing the function.

