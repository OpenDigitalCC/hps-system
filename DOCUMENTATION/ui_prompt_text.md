## `ui_prompt_text`

Contained in `lib/functions.d/cli-ui.sh`

### Function overview

The `ui_prompt_text` function is a Bash script function that presents a command line prompt to the user and receives textual input as a response. It supports a default text response that will be the output if the user doesn't type anything before hitting the Enter key.

### Technical description

**Name:**  
`ui_prompt_text`

**Description:**  
This function echoes a prompt to the user, waits for their response and returns the input they enter. If the user gives no input, the function will use a default value.

**Globals:**  
No globals are used.

**Arguments:**  
- `$1: prompt` - The prompt the user will be presented with.
- `$2: default` - The default value that will be used if the user gives no input.

**Outputs:**  
The user's input or the default value if no input was given.

**Returns:**  
The function does not return any value as it directly echoes to standard output.

**Example Usage:**
```
$ ui_prompt_text "Please enter your name" "Anonymous"
Please enter your name [Anonymous]: <User Input> 
```

### Quality and security recommendations

- In terms of quality, it may be beneficial to add an option for including a flag that will specify whether to capture the input silently (such as for passwords). 
- Adding validation code to enforce input content type would improve function robustness.
- From a security perspective, the script should ideally not echo very sensitive default values back to the user if this script's output can be seen/accessed by others.
- Input could be sanitized to prevent code injection vulnerabilities.

