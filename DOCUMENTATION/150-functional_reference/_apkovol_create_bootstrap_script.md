### `_apkovol_create_bootstrap_script`

Contained in `lib/functions.d/tch-build.sh`

Function signature: 42961fd53ac21d7d12daa21968c734351bc09eeb3bf2428033a5d8f5683ab3b6

### Function overview
The function `_apkovol_create_bootstrap_script` is used to generate a bootstrap script for Alpine Linux system. It takes in three arguments: a temporary directory, a gateway IP, and an Alpine version. Initially, it logs the creation of the bootstrap script, and then proceeds to generate a script within a specified directory. The script performs several tasks: configuring Alpine repositories, updating package index with retry logic, installing necessary packages and sourcing HPS functions. The placeholders in the script are replaced with the supplied gateway IP and Alpine version. Eventually, it sets the execute permission on the bootstrap script, and logs a message if it was created successfully.

### Technical description
- **Name**: `_apkovol_create_bootstrap_script`
- **Description**: This Bash function creates an Alpine Linux bootstrap script based on given inputs. It replaces placeholders within the script with the given gateway IP and Alpine version, and finally sets the script as executable.
- **Globals**: None
- **Arguments**: [ `$1`: `tmp_dir: The temporary directory where the script will be created.`, `$2`: `gateway_ip: The gateway IP used in the bootstrap script.`, `$3`: `alpine_version: The version of Alpine Linux used for setting up repositories in the script.` ]
- **Outputs**: An executable bootstrap script created at the specified temporary directory.
- **Returns**: If it is successful, it returns 0. If it fails at any point, it returns 1.
- **Example Usage**: 
```bash
_apkovol_create_bootstrap_script "/tmp" "192.168.1.1" "3.9"
```

### Quality and security recommendations
1. Consider validating the input parameters to make sure they are in the correct format before proceeding with the operation.
2. Make sure the temporary directory where the script is created is secure to prevent unauthorized access or modification of the script.
3. Existence of the temporary directory should be ensured before attempting to write to it, to avoid errors. 
4. Be aware of error-catching mechanisms, and ensure unexpected errors can be handled gracefully.
5. When changing file permissions, consider group permissions and potential security implications.

