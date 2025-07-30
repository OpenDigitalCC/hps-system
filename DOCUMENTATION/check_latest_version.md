## `check_latest_version`

Contained in `lib/functions.d/iso-functions.sh`

### Function overview

The function `check_latest_version` is used to check for the latest version of an operating system. The function takes three parameters: cpu (processor type), mfr (manufacturer), and osname (operating system name). It fetches the HTML from the base URL of the OS, parses the page for versions, and echoes the latest version found. For instance, it can access the base URL of the operating system 'Rocky Linux' and echo the latest version if such exists. If an error occurs during the fetch or if no versions are found, an error message is displayed and the function returns 1. In case the OS provided is unknown, the function also echoes an error message and returns 1.

### Technical description

- name: `check_latest_version()`
- description: The function checks for the latest version of an operating system.
- globals: None
- arguments:
    - `$1: cpu` - the type of cpu
    - `$2: mfr` - the manufacturer
    - `$3: osname` - the name of the operating system
- outputs: Echoes the status of version checking, any potential error messages, and the latest version number if found.
- returns: Returns 1 when an error occurs, or 0 on successful finding of the latest version.
- example usage:
  ```bash
  check_latest_version "x86_64" "Intel" "rockylinux"
  ```

### Quality and security Recommendations

- To improve the security of this function, it's recommended to include additional mechanisms for validating the security certificates of the pages you fetch through `curl`.
- As a quality measure, it might be beneficial to add support for other operating systems or at least output a more specific error message when an unavailable OS is supplied.
- Considering the potential changes over time on the HTML structure of the page that this function scrapes, it'd be recommended to maintain and adapt the parsing method according to these changes accordingly.
- Additional error checks should be added to ensure that the function parameters are not empty before the function attempts to operate with them.
- On a practical note, it would be optimal to avoid hard-coding the base URL for each OS and instead, maybe, fetch it from a maintained list or database.

