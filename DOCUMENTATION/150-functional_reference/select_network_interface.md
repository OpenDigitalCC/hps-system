### `select_network_interface`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: 019a6a43a2b588278bd5945964c48b92ffb331b67f1cacc18bedd6dd6828d661

### Function Overview

The function `select_network_interface()` is designed to present a selection menu to the user for choosing a network interface. The function creates a list of available network interfaces, and optionally adds a "None" option. Invalid selections are handled properly, and on a successful selection, the name of the selected interface is returned.

### Technical Description

- **Name**: `select_network_interface`
- **Description**: Shows a user-friendly selection menu to select one of the available network interfaces. Can optionally include a "None" option. Returns the name of the selected interface (not the full label shown in the menu).
- **Globals**: None
- **Arguments**: 
  - `$1`: The prompt to be used in the selection menu (default: "Select network interface").
  - `$2`: Flag to indicate whether to include "None" as an option (default: false).
  - `$3`: The display text for the "None" option, if included (default: "None").
- **Outputs**: 
  - If a valid interface is selected, its name is printed to stdout.
  - If "None" is selected, "NONE" is printed to stdout.
  - If an invalid selection is made, an error message is printed to stderr.
- **Returns**: 
  - `0` if a valid selection is made.
  - `1` if the menu is exited without a valid selection.
- **Example Usage**: `selected_interface=$(select_network_interface "Choose an interface" true "No interface")`

### Quality and Security Recommendations
1. Always quote variable expansions and command substitutions to prevent issues with word-splitting and globbing. In this function, it is done correctly.
2. Consider checking if the `get_network_interfaces` command succeeded before proceeding, possibly exiting early if it failed.
3. Be cautious with using redirection (`< <(...)`), it can create a subshell and modify the parent shell's state, which might lead to unexpected behavior.
4. Keep careful track of what you choose to expose to the user in the prompt. Depending on the context in which the function is used, some information might not be appropriate to share.
5. Check the inputs to the function to ensure they are as expected, and consider handling edge cases more explicitly. For example, what if the `include_none` argument is not a boolean?

