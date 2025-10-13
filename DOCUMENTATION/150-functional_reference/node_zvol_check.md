### `node_zvol_check`

Contained in `lib/host-scripts.d/common.d/zvol-management.sh`

Function signature: 07447af71573f33e1e9896011244fa50252bca03c45d1685a0b8677a4720d46c

### Function Overview
The `node_zvol_check` function is a part of the command-line tool intended for use in ZFS (Zettabyte file system). The function checks if a specific ZFS volume (zvol) exists, where the zvol is defined by its pool and name. These two parameters are passed to the function as arguments. The function prints the outcome of the check to the console and returns an error code.

### Technical Description

- **Name:** `node_zvol_check`
- **Description:** This function checks the existence of a ZFS volume (zvol) where the zvol is identified by its ZFS pool and name.
- **Globals:** No globals variables
- **Arguments:** 
  - `$1`: Parameter pair `--pool <pool>`.
  - `$2`: Parameter pair `--name <name>`.
- **Outputs:** 
  - If the zvol exists, it prints: `Zvol <zvol_path> exists`. 
  - If the zvol does not exist, it prints: `Zvol <zvol_path> does not exist`.
- **Returns:** `0` if the zvol exists; `1` otherwise, or if the required arguments were not correctly passed.
- **Example usage:** `node_zvol_check --pool myPool --name myZvol`

### Quality and Security Recommendations

1. Implement parameter validation, ensuring the input parameters meet the expected format.
2. Add more explicit error codes for different error conditions to aid in troubleshooting.
3. Implement a help message function when parameters are not provided or incorrectly supplied.
4. Consider using more secure methods when processing the output and display messages. This could help against possible Bash Injection attacks.

