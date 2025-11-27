### `run_function_list`

Contained in `node-manager/alpine-3/TCH/BUILD/run_osvc_build.sh`

Function signature: 9332f51df9c8b0d77c5f2b16e6f5e98293a660ace81153ea206e9ab1b86c0e9c

### Function overview

The `run_function_list()` function is a bash function used to run a series of functions in sequence, providing logging for each function's execution and stopping the sequence if any function returns a non-zero exit code.

### Technical description

- **Name**: `run_function_list`
- **Description**: This function iterates through an array of function names provided as arguments. Each function is run in sequence, and the execution and exit codes of these functions are logged. If any function returns a non-zero exit code, the sequence is immediately stopped and the non-zero exit code is returned.
- **Globals**: None.
- **Arguments**: This function accepts an unlimited number of arguments. Each argument is expected to be a string corresponding to a function name to run.
- **Outputs**: This function outputs logs to `stdout` containing the name of each function as it is run and whether it was successful or failed.
- **Returns**: This function returns `0` if all functions run successfully. If any function fails, it returns the exit code of the failed function.
- **Example usage**:
    ```bash
    `run_function_list "function1" "function2" "function3"`
    ```

### Quality and security recommendations

1. Functions provided to `run_function_list` should have proper error handling to ensure they exit with a non-zero status when an error occurs.
2. Ensure that all functions called are defined and have the correct permissions to run to avoid possibly sensitive errors being output and logged.
3. Avoid providing user-supplied or unsanitized input as function names to this function to prevent potential code injection attacks.
4. Be careful with the number of arguments. Massive numbers may lead to unexpected behaviour due to argument length limitations.
5. I would recommend adding measures to this function to handle cases where a function could potentially get stuck in an infinite loop.

