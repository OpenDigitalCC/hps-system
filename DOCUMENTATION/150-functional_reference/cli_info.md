### `cli_info`

Contained in `lib/functions.d/cli-ui.sh`

Function signature: 28a3fbfdceeaf8bd49d31ad9ce80e2034af53e3e598755aaaa9e1bba6bb9cd30

### Function Overview

The function `cli_info()` is a Bash function primarily used for formatting and presenting information output to the command line. It accepts two parameters; a header and a message. If neither a header nor a message is provided, the function simply returns. If one or both are provided, the function will use ANSI color codes to format the text and output it to the console with a certain format based on the inputs.

---

### Technical Description

- **Name**: `cli_info()`
- **Description**: This function receives two inputs: a header and a message, and prints them to the console. If both a header and a message are given, it prints the header in blue, followed by the message. If only a header is given, it prints the header in blue. If only a message is given, it prints the message without any color. If neither are given, it simply returns.
- **Globals**: [ `COLOR_RESET`: The ANSI color code to reset the color, `COLOR_BLUE`: The ANSI color code for blue ]
- **Arguments**: [ `$1: The header`, `$2: The message` ]
- **Outputs**: Printed header and/or message to the console.
- **Returns**: 0 (successful function execution)
- **Example Usage**: `cli_info "INFO" "This is an informational message"`

---

### Quality and Security Recommendations

1. Check the inputs for potential command injections or illegal characters. Bash does not have native string sanitization functions, but it’s generally a best practice to remove or escape any special characters that can have special meanings in unix shells (e.g., `;`, `&`, `|`, etc.).
2. Handle errors by logging them and exiting gracefully, rather than just returning.
3. Incorporate a logging mechanism to record all outputs for future troubleshooting.
4. When printing user-provided inputs if they contain any sensitive data, make sure to properly redact this data to prevent information leaking.

