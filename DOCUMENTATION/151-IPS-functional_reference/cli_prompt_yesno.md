### `cli_prompt_yesno`

Contained in `lib/functions.d/cli-ui.sh`

Function signature: f47ec2eb44075d167f6f356ea8bd4fc03757eb9a99d783f80e432210369044ff

### Function Overview

The bash function `cli_prompt_yesno()` is a utility that has been developed to interact with the user through a command line interface (CLI). It prompts the user to provide a 'yes' or 'no' response, with the possibility to set a default response. It is handy for confirming actions or choices in automation scripts. The function takes in a prompt message and a default value ('y' for yes, 'n' for no) as inputs, and outputs the normalized user response.

### Technical Description

- **Name:**  `cli_prompt_yesno`
- **Description:**  A Bash function that outputs a prompt to a user in a command line interface and waits for a 'yes' or 'no' response. It has the capability to use a default response if the user just hits the enter key without providing any input. The user's input is normalized to 'y' or 'n', and any other input results in an error message and an unsuccessful function exit.
- **Globals:**  None
- **Arguments:** 
  - `$1: prompt` This represents the question or prompt message to be displayed to the user.
  - `$2: default` This is the default value (either 'y' for yes, or 'n' for no) to be used if the user just hits the enter key without providing any input.
- **Outputs:** The function will normalize the user input to either 'y' or 'n' or an error message, which it echoes to stdout.
- **Returns:**
  - `0` if the user input is valid (i.e., either 'y' or 'n' even after applying the default value).
  - `1` if the user input is invalid (neither 'y' nor 'n').
- **Example usage:**
   ```bash
   if cli_prompt_yesno "Are you sure you want to proceed?" "n"; then
       echo "Proceeding, ..."
   else
       echo "Abort operation!"
   fi
   ```
### Quality and Security Recommendations
1. Add input validation for the `default` argument, to ensure it's either 'y' or 'n'. Any other inputs should lead to a function failure.
2. Internationalize the function by allowing translation of the 'yes' and 'no' strings.
3. Make sure the prompt string is safely escaped to prevent command injection attacks.
4. Consider returning distinct error codes for different types of errors, such as input validation errors and invalid user inputs, to allow the calling code to respond appropriately.

