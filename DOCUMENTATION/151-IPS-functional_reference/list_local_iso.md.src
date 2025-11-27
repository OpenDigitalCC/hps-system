### `list_local_iso`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 731918cdb2d287bfa33a94adacd15c3101a3688109bc456a782b3e30831ebc11

### Function overview

The function `list_local_iso()` searches for ISO files in a specific directory. It uses three mandatory parameters: `cpu`, `mfr`, and `osname`, and an optional one `osver`. The ISO files it is looking for should fit the pattern `cpu-mfr-osname` or `cpu-mfr-osname-osver` if the version is specified. If the function identifies ISO files that match the given criteria, it will print the base names of these files. If not, it will print a warning message and return 1.

### Technical description

- **Name:** list_local_iso
- **Description:** lists all local ISO files in specified directory which match the input pattern.
- **Globals:** None.
- **Arguments:**
  - `$1: cpu`: Description of the CPU architecture for which the ISO is intended, part of the ISO name pattern.
  - `$2: mfr`: Description of the ISO manufacturer, part of the ISO name pattern.
  - `$3: osname`: Description of the operating system, part of the ISO name pattern.
  - `$4: osver`: (Optional) Description of the operating system version, part of the ISO name pattern.
- **Outputs:** Prints the list of matching ISO files or a warning message if no matching files are found.
- **Returns:** If matching ISO files are found, it returns the base names of these files, or returns 1 if there are no matches.
- **Example usage:** `list_local_iso "x86" "intel" "ubuntu" "18.04"`

### Quality and security recommendations

1. Always use full paths to directories and files to avoid potential ambiguity or misdirection.
2. Utilize error handling and error returns to manage unexpected input or conditions.
3. Avoid using shell options like `nullglob` as they may have unexpected side effects depending on the user's environment. Instead, ensure your code handles cases of no matches explicitly.
4. Guard against unexpected inputs especially if the function could be exposed to untrusted inputs at any time. Consider adding checks for valid inputs before running the function.

