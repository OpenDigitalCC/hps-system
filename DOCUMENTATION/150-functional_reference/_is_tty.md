### `_is_tty`

Contained in `lib/functions.d/system-functions.sh`

Function signature: 53fbf6cc003bc7d9b4614fc9d372f3471ed01447874f4db99da2816eb3cb7e69

### 1. Function Overview

The Bash function `_is_tty` is designed to check whether the standard input (stdin), standard output (stdout) or the standard error (stderr) of the current terminal is attached to a tty (terminal).

---

### 2. Technical Description

- **Name:** `_is_tty`
- **Description:** The function checks if standard input (stdin), standard output (stdout), and standard error (stderr) are currently attached to a tty (terminal). This is achieved by using the `-t` test which returns true if the file descriptor is open and associated with a terminal.
- **Globals:** None
- **Arguments:** None
- **Outputs:** No explicit output. Internally the function returns with a status of 0 if any of the standard I/O streams are attached to a tty, or with a non-zero status otherwise.
- **Returns:** It returns true if at least one of stdin, stdout, or stderr is attached to a terminal. Otherwise, it returns false.
- **Example Usage:**
```bash
if _is_tty; then
    echo "We're in a tty terminal."
else
    echo "We're not in a tty terminal."
fi
```

---

### 3. Quality and Security Recommendations

1. Do not use this function if data privacy is your concern. In shared systems, other users can read or write to this terminal if they know its tty device file.
2. Always check the result of the function to handle the non-interactive environments appropriately.
3. It's highly recommended to handle the return status of this function properly to prevent faults in scripts that depend on a tty terminal.
4. Since the function has no arguments or global side-effects, it's safe to use this in any part of your scripts. But be aware that it only checks the state of the terminal at the time the function is called, not continuously.

