### `n_vm_create`

Contained in `lib/node-functions.d/common.d/n_vm-functions.sh`

Function signature: a35e117904d42b745641766476c0f3afad0f22d188ee42b146198071091138d6

### Function Overview 

This is a bash script function that creates a virtual machine. The function follows the following steps:

- It verifies the parameters
- Fetches the VM configuration 
- Parses the returned configuration
- Validates the required fields
- Verifies the provision method
- Builds the `virt-install` command
- Executes `virt-install`. 

Throughout the process, the function logs information about the steps and any errors encountered.

### Technical Description 

**Function Name:** `n_vm_create`

**Description:** A bash function for creating a Virtual Machine.

**Globals:**

- `n_remote_log`: Function for logging messages.

**Arguments:**

- `$1 (vm_identifier)`: Unique identifier for the VM.
- `$2 (override_title)`: Optional parameter that overrides VM's title from the fetched configuration.
- `$3 (override_description)`: Optional parameter that overrides VM's description from the fetched configuration.

**Outputs:**

- Outputs information during the process including errors and logs them using the `n_remote_log` function.

**Returns:**

- `1`: If required argument is missing or empty.
- `2`: When there is a failed or empty fetch configuration.
- `3`: If a required field is missing in the configuration.
- `4`: If a non-supported provision method is chosen.
- `5`: When `virt-install` command fails.
- `0`: On successful creation of VM.

**Example Usage:** 
```bash
n_vm_create "vm1" "Test VM" "This is a test VM"
```

### Quality and Security Recommendations 

1. Consider adding input validation for the VM configuration parameters.
2. Error and exception handling can be further improved by capturing and logging more specific error messages.
3. Variables such as `provision_method` can be set to be read-only to prevent unnecessary modifications.
4. Apply shellcheck and other linter tools to ensure the syntax and best practices are adhered.
5. Ensure sensitive logs and outputs have proper confidentiality and integrity controls.
6. Add more comprehensive tests to verify the functionality and identify potential errors.

