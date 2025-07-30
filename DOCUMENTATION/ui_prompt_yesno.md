## `ui_prompt_yesno`

Contained in `lib/functions.d/cli-ui.sh`

### Function overview

The function `ui_prompt_yesno` is a Bash function designed to prompt a user for a 'yes' or 'no' input. It displays a prompt message, awaits user input, and repeats the prompt until valid input (either 'y' or 'n') is provided. This function supports having a default response which is used when the user simply hits Enter without providing any explicit input.

### Technical description

**Name:** ui_prompt_yesno

**Description:** \
This is a Bash function that incessantly prompts users with a message until they provide a 'Yes' or 'No' input, in the form of 'y' or 'n'. The function supports a default response. The default response becomes the input if a user doesn't provide any and simply hits the Enter key.

**Globals:** \
None

**Arguments:**
- $1: `prompt` - The message to display to the user.
- $2: `default` - The default response which becomes the answer if no explicit entry is provided by the user.

**Outputs:** \
Prints the prompt message on the console, potentially multiple times if the user keeps providing invalid input.

**Returns:** 
- 0 if the response is 'y' or 'Y'.
- 1 if the response is 'n' or 'N'.

**Example Usage:** \
```bash
if ui_prompt_yesno "Do you wish to continue"; then
  echo "Yes chosen."
else
  echo "No chosen."
fi
```

### Quality and security recommendations

1. Input validation: This function already validates the user input, only accepting 'y' or 'n'. This trial process continues until a valid response is received.
2. Error handling: While the function is resilient against invalid inputs, it could potentially be stuck in an infinite loop if, for example, user input is piped from a non-interactive source. To fix this, a maximum retry count might be added.
3. Local variables: The function uses `local` to narrow down the scope of the variables `prompt`, `default`, and `response`, which is a good practice. However, ensure that your script is consistent in the use of the `local` keyword for variables.
4. Default Response: The function uses a default response 'y'. This can be parameterized based on function call instead of hardcoding it in functionality.

