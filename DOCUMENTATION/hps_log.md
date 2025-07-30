## `hps_log`

Contained in `lib/functions.d/hps_log.sh`

### Function overview

The `hps_log` function is designed to maintain the system log for the hypothetical product or system (hps). It accepts two parameters, namely level and raw message. The level indicates the severity or importance of the log entry, while the raw message is the actual content to be recorded in the log. The function also utilizes the environment variables `HPS_LOG_IDENT` and `HPS_LOG_DIR` which represent the identification tag for log messages and the path directory of the log file respectively.

### Technical description

Here is the definition block for `hps_log`:

- **name**: `hps_log`
- **description**: Maintains a log of system activities in an organized manner. Uses a standardized logging format that includes a timestamp, identification tag, log level, and message content.
- **globals**:
    - `HPS_LOG_IDENT`: Default identification tag for log messages. Falls back to "hps" if not present.
    - `HPS_LOG_DIR`: Directory location for the systemic log file. Defaults to "/var/log" if unspecified.
- **arguments**:
    - `$1`: Log level to indicate the significance of the message.
    - `$*`: The actual content of the log message.
- **outputs**: The function writes the log entry into the designated log file.
- **returns**: No explicit return value.
- **example usage**:  
    ```bash
    hps_log "INFO" "Application started successfully."
    ```

### Quality and security recommendations

- It would be prudent to sanitize and validate the log message to prevent content that could potentially harm the system or compromise its security, e.g., script injection attempts.
- To improve file safety and integrity, permissions for the log file should be correctly set to write-only for the software and read-only for users as needed.
- It is best to have the log file rotated periodically to manage file size, storing older logs in an archive for later perusal if necessary.
- For better error handling, the function could signal a warning or error when it fails to write to the log file.

