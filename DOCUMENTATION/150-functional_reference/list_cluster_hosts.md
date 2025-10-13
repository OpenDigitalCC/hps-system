### `list_cluster_hosts`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: be089e20c3a7eb6f1c96e5243449b6bffb67b4c25d9062593c07c1c4f6b55ffb

### Function overview

The function `list_cluster_hosts()` is used to list the MAC addresses of the cluster hosts. It accepts a cluster name as an argument, gets the cluster directory, determines the hosts directory depending on the cluster name, and verifies the existence of this directory. Then it lists all .conf files in the directory, extracts the MAC addresses from them, and prints them out. If no argument is passed, it assumes the active cluster directory.

### Technical description

- **Name**: `list_cluster_hosts()`
- **Description**: Lists the MAC addresses of the hosts in a given cluster.
- **Globals**: None.
- **Arguments**:
  - `$1: cluster_name` - The name of the cluster. If omitted, uses the active cluster.
- **Outputs**: 
  - Lists the MAC addresses of the hosts in the identified cluster.
  - Logs errors and debug information to the console.
- **Returns**: 
  - `0` if everything is fine, 
  - `1` if it cannot determine the active cluster hosts directory or cannot get the directory for the specified cluster.
- **Example Usage**:
  - `list_cluster_hosts myCluster` 
  - `list_cluster_hosts`

### Quality and security recommendations

1. Validate the provided cluster name to ensure it matches expected formatting and values. 
2. Consider implementing error handling for the cases where the .conf files cannot be read or are improperly formatted.
3. Introduce strict mode (`set -euo pipefail`) at the top of your script. This forces you to handle unintended errors and prevents variables from being used before they are set. 
4. Use unique temporary filenames if creating any files or directories, using tools like `mktemp` to avoid potential conflicts or security issues.
5. Ensure that logging does not inadvertently print sensitive information.

