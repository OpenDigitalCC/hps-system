## `ipxe_configure_main_menu `

Contained in `lib/functions.d/ipxe-menu-functions.sh`

### Function overview
The function `ipxe_configure_main_menu` is used to generate the main interaction menu for host configuration in a cluster network via iPXE (Open Source Boot Firmware). It is responsible for presenting a list of possible actions to the user if they have a configured cluster but their host is not adequately configured yet. Depending on the configuration state (specifically the `FORCE_INSTALL` state), it may provide options to force installation and wipe disks, among other features. 

### Technical description
- **Name**: ipxe_configure_main_menu.
- **Description**: This function dynamically generates a main menu system for hosts not yet configured in a cluster network. It populates the menu based on the state of `FORCE_INSTALL`. It also creates an infrastructure for logging and handling the user's menu selection.
- **Globals**: [ FORCE_INSTALL_VALUE: Holds the state of the `FORCE_INSTALL` configuration parameter, mac: holds the mac address].
- **Arguments**: This function does not take any arguments.
- **Outputs**: 
  * The menu layout and the set of options available, which is echoed to the standard output.
  * The chosen selection is fetched and the process of that selected menu item is initiated.
- **Returns**: Nothing is explicitly returned.
- **Example usage**: 
    `ipxe_configure_main_menu`

### Quality and security recommendations
1. Prevent code injection by ensuring the integrity of the `FORCE_INSTALL_VALUE`.
2. The function uses `cat <<EOF`, which can potentially expose sensitive data. Always ensure the content within this block is sanitized.
3. To improve code readability, consider adding more comments explaining the logic behind certain actions, such as the way `FORCE_INSTALL_VALUE` is handled.
4. Ensure exception handling during operations like `imgfetch` to maintain robustness.
5. Avoid logging sensitive information to prevent potential leaks.

