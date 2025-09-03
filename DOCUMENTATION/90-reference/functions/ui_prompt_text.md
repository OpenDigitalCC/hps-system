### `ui_prompt_text`

Contained in `lib/functions.d/cli-ui.sh`

Function signature: 698fb0f6a52fc5fb7d346cb2755ab85d4e44cef66d1ac20f8f40870457b2970a

### Function Overview

The `ui_prompt_text` function in Bash is designed for presenting an interactive prompt to users. This function receives two arguments - a prompt message and a default value. The function first displays the prompt, afterwards if the default value is nonempty, it is also displayed in brackets. A colon and a space character are appended to prepare the text for an expected user input. The user's input is read and stored in a variable, `result`. In case of no user input, the default value is returned, otherwise the user's input is returned.

### Technical Description

| Feature | Details |
| --- | --- |
| Name | ui_prompt_text |
| Description | A Bash function to prompt users for input with the option of a default response. |
| Globals | None |
| Arguments | $1 (prompt): The message prompt to present to the user. <br> $2 (default): The default value that will be used in case of absence of user input. |
| Outputs | Prompts the user with a message and optional default value. |
| Returns | The user's input if provided, otherwise the default value. |
| Example Usage | `ui_prompt_text "Please enter your name" "John Doe"` |

### Quality and Security Recommendations

1. Always use `read -r` to prevent interpreting backslashes as escape characters.
2. Beware of potential security risks of command injection if the result is used in further commands without sanitization.
3. You should always quote your variable substitutions like so: `"$var"`. This is to prevent issues with multi-word strings.
4. Remember to initialize local Bash variables. This can help avoid problems if there's a global variable with the same name.
5. Provide clear and user-friendly prompts to facilitate the operation for end users.
6. Default values should be carefully chosen to prevent problems in case of user misuse or misunderstanding.
7. When handling sensitive data, ensure that input is hidden or obscured to protect it from unauthorized access or exposure.

