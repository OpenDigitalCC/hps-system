### `_osvc_run`

Contained in `lib/host-scripts.d/common.d/opensvc-management.sh`

Function signature: b4d91dc406a4ee6f725ae31a5e96d8ba670b6af35d65b7ad9e0416aecb14c186

### Function overview

The `_osvc_run` function is a utility function in Bash that encapsulates the command execution pattern accommodating argument passing, error capture, and logging. This function accepts command arguments, executes them, logs any error codes or output, and returns the error code.

### Technical description

#### Name
_osvc_run

#### Description
This script function accepts a description and a command as inputs, and executes the given command. Any resulting output or errors are logged using a custom logger, tagged with a provided description and an exit code. The function then returns the same exit code.

#### Globals
None

#### Arguments
* $1: `desc` - A description tag for the command being run. This gets logged with any output or errors.
* `$@`: The remaining arguments form the command to be executed.

#### Outputs
Logs an information message on execution status including the provided tag, the exit code, and any command output or errors.

#### Returns
The exit status of the command that was run.

#### Example Usage
```bash
_osvc_run "List running processes" "ps aux"
```

### Quality and security recommendations
1. Aside from the facilities provided by Bash, there's no explicit error checking or sanitization. Ensure the commands or arguments that this function wraps are safe to execute.
2. Consider adding checks for the number of parameters provided to the function to avoid undesired behavior.
3. Make sure to properly escape the parameters that are passed to this function to avoid command injection vulnerabilities.
4. Always use the function with trusted inputs, as this function executes commands directly.
5. Ensure that the right permissions are granted at the directory and shell level. The function should not have more permissions than what it needs.
6. Incorporate a controlled logging mechanism to reduce the risk of potential log forgery.

