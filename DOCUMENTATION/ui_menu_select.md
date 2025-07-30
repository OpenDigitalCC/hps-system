## `ui_menu_select`

Contained in `lib/functions.d/cli-ui.sh`

### Function overview

The `ui_menu_select()` function is a user interactive function aimed to efficiently and easily handle user interface menus in Bash scripts. It displays a menu on the console provided by an input array and repeatedly asks the user to make an input selection until the user makes a valid selection. 

### Technical description

**Name:** 
`ui_menu_select()`

**Description:** 
This function presents a user interface on the console for an array-based menu. It accepts an array of options as arguments, presents them as numbered choices to the user, and prompts the user for their selection until a valid selection is made.

**Globals**: 
_None_

**Arguments**: 
- `$1`: This is the first argument passed to the function, which is used here as the prompt message for the menu.
- `shift`: This Bash built-in command shifts the command-line arguments to one position left, essentially removing the first argument `prompt`.
- `"${@}"`: This refers to all the arguments passed after array elements, which here are the other options for the user to select.

**Outputs:**
This function will output the selected choice once a valid selection is made.

**Returns:**
The function will return 0 when a valid selection has been made, otherwise it continues to prompt the user for a valid selection.

**Example usage:**
```bash
options=("Option 1" "Option 2" "Option 3")
ui_menu_select "Please choose an option:" "${options[@]}"
```

### Quality and security recommendations

1. Add validation to ensure reasonable limits on menu options (avoid large number of options).
2. Display an error and exit if no options are provided.
3. Improve error handling. For example, handle errors in non-integer inputs and strings.
4. Enhance usability by handling additional keyboard inputs (such as arrow keys for selection).
5. To minimize injection vulnerabilities, avoid using `eval` or similar commands. Ensure correct quoting and word separation in variable and function usage.
6. Consider a timeout for inputs to prevent indefinite hanging of the script due to inactivity.

