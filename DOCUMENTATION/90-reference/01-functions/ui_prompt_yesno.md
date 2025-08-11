#### `ui_prompt_yesno`

Contained in `lib/functions.d/cli-ui.sh`

Function signature: 5b56e1af7169ad6721f24f1f595cee61d779f0b22963936d53073e284b177e9c

##### Function Overview

The `ui_prompt_yesno` function offers a simple prompt interaction to the user. It accepts a specified question and an optional default answer. If the user does not type in a response, the function will proceed with the default answer. The function uses a while loop to keep prompting the user for input until it gets a valid response. If the user enters "y" or "n", the function will stop prompting and return with 0 for "y" and 1 for "n".

##### Technical Description

**Name**: `ui_prompt_yesno`

**Description**: Function to query user response in a Y/N prompt fashion with an optional default answer.

**Globals**: None

**Arguments**:
 - `$1`: The prompt to display to the user. It should be a String.
 - `$2`: (Optional) The default answer if a user does not provide any response. Default is 'y'.

**Outputs**: The prompt asking for user input, with the optional default value.

**Returns**:
 - `0` if the user inputs 'y' or 'Y'
 - `1` if the user inputs 'n' or 'N'

**Example Usage**:
```bash
ui_prompt_yesno "Do you want to quit?" n
```

##### Quality and Security Recommendations

1. To avoid possible code injection, ensure that the input to `$1` and `$2` are not externally specified without proper validation or sanitizing.
2. Provide thorough comments and maintain readability to help future developers understand the code. In Bash, it's easy to write very complex one-liners, but it can be very challenging to read back and understand.
3. Error-checking methods should be adopted to handle invalid user inputs outside the bounds of 'y' or 'n'
4. Use the `-i` flag with `read` command. This makes it easier for the user to see what the default value is and perhaps only slightly modify it.

