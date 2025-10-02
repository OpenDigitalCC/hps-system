### `node_get_functions`

Contained in `lib/functions.d/configure-remote-host.sh`

Function signature: 1b666a5e2b77b4bf76b075e77c70af41c70e3996b2c4adb712d2c69e9dbccba1

### Function overview

The `node_get_functions` is a bash function in charge of building a function bundle for a specific Linux distribution (or 'distro'). The function accepts a string that represents a 'distro' and a base directory as parameters. The Distro string is a concatenation of the CPU architecture, the manufacturer, the OS name, and the OS version, divided by dashes. A function bundle is a collected set of bash functions that are relevant and compatible with the specific system represented by the distro string.

### Technical description

- **name:** `node_get_functions`
- **description:** This function builds a function bundle for a specified Linux distribution based on the specific CPU, manufacturer, OS name and OS version. It finds the relevant functions from a provided directory `base` and echoes them out.
- **globals:** 
    - [ LIB_DIR: an optional global variable that might contain the base directory ]
- **arguments:** 
    - [ $1: a 'distro' string in the format: <cpu-mfr-osname-osver> ]
    - [ $2: Optional. is a base directory where function files are searched. Defaults to "${LIB_DIR}/host-scripts.d" or "/srv/hps-system/lib/host-scripts.d" if LIB_DIR is not presented]
- **outputs:** Outputs the relevant functions found in the provided `base` directory.
- **returns:** It doesn't explicitly return anything. The function has side-effects of echoing the functions it finds and logs info and debug messages.
- **example usage:**

```bash
node_get_functions intel-dell-ubuntu-20.04 /my/base/dir
```

### Quality and security recommendations

1. Always use double quotes around variable expansions to avoid word splitting and pathname expansion.
2. Make sure the provided base directory path is validated and sanitized.
3. Consider adding error messages in case the incorrect number of arguments have been provided.
4. Always validate user inputs. In this function, consider applying validation checks on the distro string and possibly the base directory.
5. If possible, add some unit tests around this function. It'll help to ensure the function behaves as expected when modifying or adding new code.

