### `ipxe_goto_menu`

Contained in `lib/functions.d/ipxe-menu-functions.sh`

Function signature: 49847df81dbbc4d2221bff922ec99935856f612fa6c68856d80a8ee4f35615de

### Function overview

The `ipxe_goto_menu` is a Bash function that refreshes the ipxe environment and directs the user towards a chosen menu or to the main menu by default. This is achieved by building a chain request to the ipxe server with the desired menu item as a parameter. As an element of a network booting solution, the scope of the function is to allow adjustments in the booting process through menu interaction.

### Technical description

- Name: `ipxe_goto_menu`
- Description: The function refreshes the ipxe environment and navigates to a chosen menu (defaulting to the main menu if not specified).
- Globals: This function does not use/globalize any variables.
- Arguments:
    - `$1`: This argument represents the menu that the function navigates towards. Defaults to `init_menu` if not provided.
- Outputs: The function initializes an ipxe header and outputs ipxe commands to free loaded images (`imgfree`) and create a chain loading configuration (`chain`).
- Returns: Does not return any particular value, simply executes commands.
- Example usage:
```bash
ipxe_goto_menu         # Will navigate to "init_menu" by default
ipxe_goto_menu "custom_menu"  # Will navigate to "custom_menu"
```

### Quality and security recommendations

1. Introduce error handling for the `ipxe_header` function call inside - it's potentially susceptible to failures which are not currently captured.
2. Check the validity of `CGI_URL` before using it. Currently, if `CGI_URL` is incorrect, the function will fail without any error messages. Customizable error messages will greatly improve troubleshooting.
3. Validate the `MENU_CHOICE` argument to ensure it corresponds to an existing menu. This can prevent erroneous chains.
4. For added security, sanitize the `MENU_CHOICE` variable to prevent potential command injection attacks.

