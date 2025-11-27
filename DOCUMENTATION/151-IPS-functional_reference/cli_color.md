### `cli_color`

Contained in `lib/functions.d/cli-ui.sh`

Function signature: 5b1da9ceb66e5db9828e84c114d322c5fd60f95ee979773f19784a6dbb747c76

### Function overview

The `cli_color` function is a utility that takes a color name as an argument and outputs an appropriate color code. The function checks the color global variables to ensure they're initialized, and handles inputs in a case-insensitive manner. It supports a variety of color names, including "red", "green", "blue", etc. For unrecognized color names, it simply outputs nothing.

### Technical description

- **Name**: `cli_color`
- **Description**: This function takes as input the name of a color and returns the corresponding color code in the terminal. If the input color name is not recognized, it returns nothing.
- **Globals**: [ `COLOR_RESET`, `COLOR_RED`, `COLOR_GREEN`, `COLOR_YELLOW`, `COLOR_BLUE`, `COLOR_MAGENTA`, `COLOR_CYAN`, `COLOR_WHITE`, `COLOR_BOLD`, `COLOR_DIM`: definitions of terminal color codes ]
- **Arguments**: [ `$1`: the name of the color that needs to be translated into a terminal color code ]
- **Outputs**: The terminal color code corresponding to the color name input. If the color name is unknown, outputs nothing.
- **Returns**: Always returns `0`, indicating a successful termination of the function.
- **Example usage**:

  ```bash
  msg_color=$(cli_color "red")
  echo -e "${msg_color}This text will appear in red${COLOR_RESET}"
  ```

### Quality and security recommendations

1. The function should include a catch-all case statement to handle any color names that are not specifically listed and return an error message instead of silently failing. This will enhance user-friendliness of the function.
2. Consider validating the input color name against a list of supported colors, and throwing an error if the color name is not recognized.
3. These color variables should be encapsulated in a configuration file for better separation of concerns.
4. Encapsulate initialization of color variables into a function to keep the main body of the code clean.
5. Always prefer local variables over globals where possible for data that do not explicitly need to be shared across multiple function calls, to avoid unintended modification.

