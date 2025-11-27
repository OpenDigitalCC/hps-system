### `o_log`

Contained in `lib/functions.d/o_opensvc-task-functions.sh`

Function signature: a128422c273b1df345526eab6502010e6b9cca98beb40ca6d2d3fe05aa5d3caa

### Function Overview

The `o_log` function in Bash is built to manage logs. It is used for sending messages to the standard system logger. It takes up to three parameters. By default, the log priority is set to 'info' and the facility to 'user', with a predefined tag "opensvc". If the priority or facility arguments do not match predefined acceptable values, it defaults to 'info' and 'user' respectively while logging a warning about the input anomaly. A validation error occurs and the function halts if the message parameter is empty.

### Technical Description

- Name: `o_log`
- Description: A bash function for logging messages to the standard system logger.
- Globals: None.
- Arguments: 
  - `$1: message` - The log message
  - `$2: priority` - The priority of the message being logged. Acceptable values are 'err', 'warning', 'info', 'debug'. Defaults to 'info' if not specified or if specified value is invalid
  - `$3: facility` - The facility for the message. Potential values include 'user', 'local0' to 'local7', 'daemon', 'auth', 'syslog'. Defaults to 'user' if not specified or if specified value is invalid 
- Outputs: Logs the given message with the specified priority and facility. If parameters are invalid, a warning is logged.
- Returns: The status code of the last executed `logger` command.
- Example Usage: 
```bash
o_log "Application started" info daemon
```

### Quality and Security Recommendations

1. As a quality improvement, incorporate a more detailed error handling system. Currently, when the function is called with an empty message, it only logs a simple error message. Instead, it could throw a detailed exception or return a specific error code.
2. Implement a stricter validation for priority and facility. Right now, the function only checks if the parameters match the expected values (and turns them into defaults if they don't). Consider integrating a proper error handling or feedback to users instead of silently changing the unwanted value to default.
3. Some input sanitation is suggested as a security measure. While Bash commands generally handle special characters, they might create unexpected behaviour with varying locales. So, a standardized message format is recommended.
4. Consider limiting the length of the log message to prevent any potential overflow issues. This can be integrated into the current validation section.
5. As part of best practices, always document the function with its expected inputs and outputs, which is already in place for this case.

