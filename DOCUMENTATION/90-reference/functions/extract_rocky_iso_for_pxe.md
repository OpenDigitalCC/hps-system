### `extract_rocky_iso_for_pxe`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 52e8a2e1e3a65096a2e0e1ac3696f4c21521a7cc3c3b006a7056ede3446b2ada

### Function overview

The function `extract_rocky_iso_for_pxe()` is created to extract a Rocky Linux ISO for PXE (Preboot Execution Environment). This extraction is required to prepare the PXE boot environment. The function takes in three arguments: the path to the ISO, the version of the Linux OS, and the CPU architecture information. It then prepares a location to extract the ISO contents and performs the operation using bsdtar or fuseiso. If neither utility is available, the function logs an error message and exits with a non-zero status code.

### Technical description

- **name**: extract_rocky_iso_for_pxe
- **description**: The function aims to extract a Rocky Linux ISO for PXE (Preboot Execution Environment).
- **globals**: 
   - VAR: `HPS_DISTROS_DIR`: a variable holding the base directory for Linux OS distributions.
- **arguments**: 
   - $1: `iso_path`: Path to the Rocky Linux ISO file.
   - $2: `version`: The version number of the Linux OS.
   - $3: `CPU`: The required CPU architecture.
- **outputs**: 
   - Logs about the extraction process.
   - An error message if neither `bsdtar` or `fuseiso` commands are installed.
- **returns**: 
   - 0 if the Rocky Linux ISO extraction is successful.
   - 1 if neither `bsdtar` or `fuseiso` commands are installed.
- **example usage**:

```
extract_rocky_iso_for_pxe "/path/to/iso" "8.4" "x86_64"
```

### Quality and security recommendations

1. Always sanitize inputs to the function to prevent any possible malicious or unintended actions.
2. Make sure to check the existence of the ISO file passed as an input, and fail fast, if it doesn't exist.
3. Use full paths to commands like bsdtar, fuseiso, etc. to avoid dependency on PATH and prevent potential "command not found" errors or command injection vulnerabilities.
4. Be mindful of returning appropriate status codes on failure scenarios, it helps to debug faster.
5. Consider providing more informative and meaningful log messages for clarity about each operation.
6. Always handle potential errors in filesystem operations like mkdir, cp, etc.
7. In the "globals" section, important potential side effects of using global variables in a function like potential conflicts with other scripts/environment variables should be kept in mind.

