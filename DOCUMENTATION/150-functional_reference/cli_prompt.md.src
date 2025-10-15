### `cli_prompt`

Contained in `lib/functions.d/cli-ui.sh`

Function signature: f49e68ce40ea9bb18b1ae2b2549fbaf0b8bc3bef5f929a8a9764769dc4ce04d5

### Function overview

The `cli_prompt` function is a Bash utility function that prompts the user for input on the command line, sets a default value if the user inputs nothing, and validates the user's input against a specified regular expression if one is provided. If the user's input does not match the regex, it logs an error and returns 1. If the user's input is valid or no validation is necessary, it echoes the input for use in the script or environment, then returns 0.

### Technical description

```bash
cli_prompt() {
  ...
}
```

**name:** `cli_prompt`

**description:** This function prompts the user for input on the command line with the ability to set a default value and validate the input against a given pattern. 

**globals:** None

**arguments:** 
`$1`: `prompt` - The string to display to the user on the command line.
`$2`: `default` - The default value to apply if the user's input is empty.
`$3`: `validation` - The pattern to validate the user's input against.
`$4`: `error_msg` - The error message to log if the user's input is invalid.

**outputs:** If the user's input is valid, it outputs the input. 

**returns:** If the user's input is invalid, it returns 1. If the user's input is valid, it returns 0.

**example usage:**

```bash
cli_prompt "Enter your name" "John Doe" "^[a-zA-Z ]*$" "Name can only contain letters and spaces"
```

### Quality and security recommendations

1. Always provide meaningful prompts to guide the user on what to input.
2. Use the `default` parameter judiciously. If the choice has substantial effect or if the user input is sensitive, a default might not be a good idea, you want to ensure the user consciously inputs information.
3. Regulate the use of regular expressions in the `validation` variable. This could be a point of vulnerability if misused. Be careful to filter out any sensitive or malicious input.
4. Always provide a meaningful `error_msg` which would guide the user on the right input to provide when they make an error.
5. Be careful when echoing out the user input, as this could lead to some potential command injection vulnerabilities. Always sanitize your inputs and do not trust user input blindly.

