### `cli_select`

Contained in `lib/functions.d/cli-ui.sh`

Function signature: c980cde4828d1b931c6014c0b115b19f394558bf05df9574129aae3aff155311

### Function overview

The `cli_select` function is a command-line interface tool in Bash. It provides an interactive menu to the user, allowing for the selection of a choice from an array of provided options. When a valid choice is entered, it is printed and the function returns. In case of an invalid selection, an error message is logged and the selection process repeats. If a SIGINT signal is detected (e.g., user inputs Ctrl+C), the function terminates and returns 1.

### Technical description

- **Function Name**: `cli_select`
- **Description**: This function generates an interactive menu that allows a user to select an option from an array of given choices. The function will print the selected choice or an error message in case of an invalid selection. If the user sends a SIGINT signal, the function will terminate immediately.
- **Globals**: None 
- **Arguments**: 
  - `$1`: This is the prompt message displayed to the user.
  - `$2-N`: These arguments represent the available options for the user to select from.
- **Outputs**: 
  - Valid selection: prints the chosen option to stdout.
  - Invalid selection: calls the `hps_log` function, which presumably logs the error message "Invalid selection".
- **Returns**: 
  - 0: when a valid selection has been made and printed.
  - 1: when the user breaks the selection with a SIGINT signal.
- **Example usage**:
```bash
cli_select "Choose a fruit" "Apple" "Banana" "Cherry"
```

### Quality and security recommendations

1. Consider adding input validation for the prompt and options arguments. This will ensure they do not contain malicious or unexpected characters.
2. Currently the function relies on the `hps_log` function to log errors. Make sure that this function properly sanitizes the log message to prevent log injection attacks.
3. There could be an infinite loop if the `hps_log` function doesn't stop the script. Add a maximum number of attempts to prevent this.
4. The function echo's the user's choice. Ensure that data is sanitized or properly escaped if it is going to be used in any sort of command to prevent command injection attacks.
5. Look into securely handling signal interrupts besides just SIGINT to ensure a consistent user experience across various scenarios.

