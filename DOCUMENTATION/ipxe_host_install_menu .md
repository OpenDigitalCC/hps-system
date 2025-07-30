## `ipxe_host_install_menu `

Contained in `lib/functions.d/ipxe-menu-functions.sh`

### Function overview
The `ipxe_host_install_menu` function generates an interactive installation menu for an iPXE host. The displayed menu provides the user with four different installation options: a Thin Compute Host, a Storage Cluster Host, a Disaster Recovery Host, or a Container Cluster Host. The selected option is logged and then processed.

### Technical description
**name:** `ipxe_host_install_menu`

**description:** This function is meant to be called without parameters. It generates a series of option prompts for a user to interactively choose an installation type for an iPXE host using combustion menus. The user's selection is logged and sent to a processing command.

**globals:**
 - `TITLE_PREFIX`: Description (initially undefined)
 - `CGI_URL`: Description (initially undefined)

**arguments:** 
- `None`

**outputs:** The function outputs a menu with different installation options for an iPXE host.

**returns:** The function does not explicitly return a value but the output of the user's selection is passed to a processing command.

**example usage:**
```bash
ipxe_host_install_menu
```

### Quality and security recommendations
1. To improve security, consider validating the value of `${mac:hexraw}` and `${selection}` variables before using them in the command to prevent possible command injection.
2. User inputs should be handled carefully. Ensure that the user can only choose pre-specified options and cannot input arbitrary values.
3. Include comments within your function to better explain the purpose and functionality of different parts of your code.
4. Consider error handling for the case when the user doesn’t select any menu item.
5. It would be more maintainable to have a dynamic way to add or remove installation options.
6. Consider making sure that `ipxe_header` function (that is being called) exists and works as expected.
7. You may want to check and verify any external dependencies such as `imgfetch`, `chain`, and `CGI_URL`.

