### `n_installer_cleanup`

Contained in `node-manager/alpine-3/+INSTALLING/installer-functions.sh`

Function signature: c95f46616dfb982eb488533d36ac9d9b32412f1241dd38f6a6aeba176910ca06

### Function Overview

The `n_installer_cleanup` function is primarily used in system operations to undertake cleanup tasks after the installation process. It does this by unmounting filesystems, stopping RAID arrays, wiping filesystem signatures, clearing partition tables (on demand), and resetting system state to allow for re-installation. The function flags for forceful execution and wiping the partition table, providing an extra level of control over how it behaves. This function is an integral part of system recovery and setup scripts.

### Technical Description

- **Name:** n_installer_cleanup
- **Description:** The function performs cleanup tasks after an installation, including unmounting filesystems, stopping RAID arrays, wiping filesystem signatures, clearing partition tables on-demand, and resetting system state to allow for re-installation.
- **Globals:** None
- **Arguments:**
  - **$1 (Force flag):** If set to 1, the function executes without asking for user confirmation.
  - **$2 (Wipe partition table flag):** If set to 1, the function clears partition tables.
- **Outputs:** Log messages about the cleanup process. Details of actions to be performed and their results are displayed.
- **Returns:** An exit code to indicate the result of the operation. Returns 1 if no installation devices are found or fails to carry out cleanup. Returns 2 if user cancels operation. Returns 0 upon successful completion of cleanup.
- **Example usage:** `n_installer_cleanup --force --wipe-table`

### Quality and Security Recommendations

1. Place further error checks: Comprehensive error checks can prevent unexpected script behavior if the function encounters unusual circumstances.
2. Consider replacing the echo-based logging system: Current logging using echoes might be replaced with a more robust logging system that can work across multiple scripts.
3. Secure sensitive operations: Certain operations such as wiping partition tables could have significant system consequences. Consider adding additional safeguards against accidental triggers.
4. Handle user input safely: As the script reads user input for confirmation, it might be a good idea to ensure this reading process is done in a secure manner.
5. Confirm erasure is successful: While the function tries to wipe certain filesystems and arrays, it doesn't verify if these actions are successful. It could be worthwhile to check if erasure is indeed successful to prevent potential data remnants.

