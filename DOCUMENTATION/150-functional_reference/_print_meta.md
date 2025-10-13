### `_print_meta`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: 8f66cc2d9e01b400ddc05a00d6399036188baa213e119c36c4340e95320bcf7f

### Function Overview

The function `_print_meta` is used to obtain and display metadata about a cluster configuration using a specific key and label. The function makes use of two arguments, the key and the label, to fetch the metadata details of a cluster configuration. It then prints the label and the value if the value is not empty. Furthermore, it also handles conditions where there might be multiple clusters, none active cluster and also when there is no active one and exactly one cluster.

### Technical Description

- **Name:** `_print_meta`
- **Description:** A shell function to fetch and display metadata information from a cluster configuration.
- **Globals:**
  - `key`: The configuration key used to fetch value from the cluster configuration.
  - `label`: Label to be print before printing the configuration value.
- **Arguments:**
  - `$1`: The first argument, used as the key in the function.
  - `$2`: The second argument, used as the label in the function.
- **Outputs:** The function can output the label and configuration value if the value is not empty.
- **Returns:** The function returns 0.
- **Example usage:** `_print_meta "DESCRIPTION" "Description"`

### Quality and Security Recommendations

1. As per good practice, make sure that the necessary sanitization of input parameters is performed before they are used.
2. Error checking should be established to handle cases where the cluster configuration or key provided as function argument might not exist.
3. Clear readability should be maintained throughout the code. Usage of clear variable names and comments can help to ensure a good level of readability.
4. Always consider the security implications of your script; be cautious of the possibility of code injection attacks.
5. Regular updates and security patches should be implemented to ensure your bash shell is up-to-date and secure from known vulnerabilities.

