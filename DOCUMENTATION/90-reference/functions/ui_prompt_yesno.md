### `ui_prompt_yesno`

Contained in `lib/functions.d/cli-ui.sh`

Function signature: 5b56e1af7169ad6721f24f1f595cee61d779f0b22963936d53073e284b177e9c

### Function Overview

The `ui_prompt_yesno` function in Bash is a user interface function that prompts the user with a yes/no question. It loops until the user provides a valid response. The first argument is the prompt text and the second optional argument sets the default answer.

### Technical Description

- **Name:** `ui_prompt_yesno`
- **Description:** This function prompts the user with a question and loops till it gets a valid "yes" or "no" answer from the user. It ensures the users interaction in a script where a binary input is necessary for further execution.
- **Globals:** No global variables are used.
- **Arguments:** 
  - `$1`: This is the prompt text that is to be displayed to the user.
  - `$2`: This optional argument specifies the default answer.
- **Outputs:** Outputs the prompt question with an optional default value and user response.
- **Returns:** 
  - Returns 0 if the response is "yes".
  - Returns 1 if the response is "no".
- **Example Usage:** If we need user's confirmation for proceeding further, we can use the function as follows: 
  ```
  ui_prompt_yesno "Do you want to continue?" "n"
  if [ $? == 0 ]
  then
      echo "User wants to continue"
  else
      echo "User doesn't want to continue"
  fi
  ```

### Quality and Security Recommendations

1. Validate that $1 (the prompt text) exists and is non-empty before proceeding.
2. Regularly audit and update third-party dependencies to keep them up to date with the latest security updates.
3. Avoid using raw user inputs without validation. In this case though, the input is controlled to "y" or "n" only.
4. Use case-insensitive matching to allow inputs as 'Y', 'n', etc.
5. Provide more detailed information about valid inputs for prompt. Do not assume users know they need to enter 'y' or 'n'.
6. Test the function rigorously with a variety of different inputs and edge cases to ensure it handles those correctly.
7. Consider implementing a limit on the number of invalid attempts before automatically selecting the default option.
8. Follow secure code practices and maintain a regular schedule for reviewing/updating the function.

