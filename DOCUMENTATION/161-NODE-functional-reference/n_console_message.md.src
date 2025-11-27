### `n_console_message`

Contained in `lib/host-scripts.d/pre-load.sh`

Function signature: 36e26683aca03d37f7320e5524aa23849cd906d839f1064363a2204b560d0b17

### Function overview

The `n_console_message` is a bash function that utilizes conditional statements to print messages to the console. The messages are customizable, with a default system message in the case no input message is provided.

### Technical description

- **Name**: n_console_message
- **Description**: The function is designed to take in a user-inputted message, defaulting to a system message if none is provided. It checks the write abilities to both the /dev/console and the /dev/tty1, if accessible, the message is printed to both. 
- **globals**: None.
- **Arguments**: [ $1: This represents the user-inputted message. If this argument is missing the function will use a default 'System message'. ]
- **Outputs**: The function may output a user-inputted message or the default 'System message' if the console and tty1 are both available and writable.
- **Returns**: The function returns 0 indicating successful completion.
- **Example Usage**: 

```bash
n_console_message "This is a message"
```

Above will print [HPS] This is a message in the /dev/console and /dev/tty1 if they are writable.

### Quality and security recommendations

1. Always validate whether the user-inputted message is in the desired plain text format to avoid any chance of code injection.
2. Additional error checking mechanisms can be included in case the console or tty1 are not writable.
3. It would be beneficial to include custom exit statuses for different failure instances, instead of mere success status. This will aid in easier debugging.
4. Regular reviews and updates should be performed to ensure that all security protocols are met.

