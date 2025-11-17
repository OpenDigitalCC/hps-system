### `hps_get_distro_string`

Contained in `lib/functions.d/node-bootstrap-functions.sh`

Function signature: d0a42fae7fd315ef37bbda7684d00b2b35c3ca46bc5849dfbcf8e045d9686609

### Function Overview
The `hps_get_distro_string` function generates a string in the format of `cpu-manufacturer-osname-osversion`. It first identifies the CPU architecture and uses "linux" as the hardcoded manufacturer. Then it checks if the `/etc/os-release` file exists. 

If the file exists, it sources the file to acquire operating system name (`osname`) and version (`osver`). If the `/etc/os-release` file does not exist, it set `osname` and `osver` to "unknown". The function then prints the constructed string.

### Technical Description
- **name**: `hps_get_distro_string`
- **description**: Generates a string that contains the system's CPU architecture, hardcoded manufacturer "linux", operating system name, and version. The format is `cpu-manufacturer-osname-osversion`.
- **globals**: None
- **arguments**: None
- **outputs**: A string with the format `cpu-manufacturer-osname-osversion`. For example, `x86_64-linux-ubuntu-20.04`.
- **returns**: None
- **example usage**: 

```bash
distro_info=$(hps_get_distro_string)
echo $distro_info
```

### Quality and Security Recommendations
1. Validate the platform before running: This function is highly dependent on the structure and existence of `/etc/os-release`. On platforms where this file does not exist or is formatted differently, the function may not behave as expected.
2. Variable sanitization: Make sure that the variables `cpu`, `osname` and `osver` do not contain harmful characters, which could lead to command injection vulnerabilities.
3. Independent from variable scope: The script uses a shell dot (.) to include another file into the script (/etc/os-release). This could potentially alter other variables in the scope. Instead, read the values without altering the environment.

