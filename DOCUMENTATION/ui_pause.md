## `ui_pause`

Contained in `lib/functions.d/cli-ui.sh`

### Function overview
The `ui_pause()` function is written in Bash and it is used as a mechanism to pause a script's execution until the user presses the [Enter] key. This function is vital when testing scripts or ensuring that the user reviews information before the script proceeds. 

### Technical description
 - **Name:** `ui_pause()`
 
 - **Description:** 
 This Bash function uses the `read` built-in command combined with `-rp` option. It will print the prompt "Press [Enter] to continue..." on the standard output (typically on the terminal screen) and then read a line from the standard input (typically from the keyboard). It waits until the user presses the [Enter] key.
 
 - **Globals:** None
 
 - **Arguments:** None
 
 - **Outputs:** It outputs a "Press [Enter] to continue..." prompt message to the terminal screen.
 
 - **Returns:** It does not return a value.
 
 - **Example usage:** 
 ```
 #!/bin/bash
 echo "This is an important message"
 ui_pause
 echo "Script resumes here..."
 ```
 
### Quality and security recommendations 
1. This function always assumes the script wants to pause, it may be made more flexible by having a flag or option to toggle this behaviour.
2. Ensure that the prompt message displayed is clear and useful to the user.
3. For better readability, put the common pause message to a separate constant.
4. Check if the script is running in an interactive shell before pausing. This function can cause automated scripts to hang indefinitely if they encounter a pause.
5. It's important to use `-r` option with `read` command to prevent it from interpreting any backslashes. Always apply best practice to maintain security.

