## `cgi_log`

Contained in `lib/functions.d/cgi-functions.sh`

### Function Overview
The `cgi_log` function is used to log messages into a CGI log file. It takes a single argument, a message from the user, and appends this message to the `/var/log/ipxe/cgi.log` file along with the current timestamp.

### Technical Description

- **Name:** `cgi_log`
- **Description:** The function accepts a user-provided logging message and appends it in a pre specified log file with the current timestamp.
- **Globals:** None.
- **Arguments:** [ `$1`: The log message provided by the user ]
- **Outputs:** Appends a log message to the `/var/log/ipxe/cgi.log` file.
- **Returns:** No explicit return value.
- **Example Usage:** `cgi_log "This is a sample log message"`

### Quality and Security Recommendations

- Sanitize the input log message in order to prevent any form of code injection or any other malicious activity.
- Provide error messages if the user does not provide a log message or if the log file is not accessible or writable.
- Be sure to handle errors and exceptions, such as a full disk or inaccessible file.
- Log messages should be meaningful and contain relevant information for easier debugging, if need be.
- From a security perspective, it is important to restrict read/write permissions for log files to prevent unauthorized access.
- Consider including a check for log file size to prevent it from consuming excessive disk space.
- Timestamp should be in a common format which should be timezone aware.

