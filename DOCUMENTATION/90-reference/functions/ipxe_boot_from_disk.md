### `ipxe_boot_from_disk `

Contained in `lib/functions.d/ipxe-menu-functions.sh`

Function signature: f26dc79cd8c9ea270e2758702b63d4a607fd3fd40737c5d947de898af37ff1fe

### Function overview

In the Bash shell, the function `ipxe_boot_from_disk` primarily ensures that the system boots from the local disk through BIOS (Basic Input/Output System). This action is accomplished by exiting from the iPXE stack, an open-source network boot firmware. The function first invokes `ipxe_header` then hands control back to BIOS for booting.

### Technical description

- **Name**: `ipxe_boot_from_disk`
- **Description**: This function is responsible for facilitating system boot from local disk through BIOS. It achieves this by exiting the iPXE stack. Before handing over the resultant control to the BIOS, it prints a statement notifying of the action and waits for 5 seconds.
- **Globals**: None.
- **Arguments**: None.
- **Outputs**: This function prints a message "Handing back to BIOS to boot" and then initiates a 5-second sleep.
- **Returns**: Doesn't return any value.
- **Example usage**: `ipxe_boot_from_disk`

### Quality and security recommendations

1. Always ensure that this function is called in a safe and secure environment. Unauthorized access or modifications could lead to serious system damage or data loss.
2. When calling the method `ipxe_header`, please make sure that it is properly defined and doesn't have any undesired side effects.
3. As it automatically initiates a system boot after 5 seconds, it's necessary to warn the user beforehand.
4. Consider adding error handling code to ensure its successful execution.
5. Verify that the BIOS settings permit booting from the local disk; else the function may not yield the expected results.

