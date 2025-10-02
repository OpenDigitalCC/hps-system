### `select_cluster`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: d6887af36fa9b9a8372e021a7e7c69665b0d3eee270caacdddd223f760546494

### Function overview

`select_cluster` is a shell function designed to effectively manage multiple clusters within a shell environment. Depending on the argument passed, it returns either the directory or the name of the selected cluster. If the shell is non-interactive, it picks the active or first cluster depending on different conditions. If the shell is interactive, it prompts the user to select a cluster from a list of available clusters.

### Technical description

- **Name:** `select_cluster`
- **Description:** This function is used to manage multiple clusters in a shell environment. It either returns the directory or the name of the active or first available cluster, depending on specific conditions.
- **Globals:** `[ HPS_CLUSTER_CONFIG_BASE_DIR: Base directory for the cluster configuration ]`
- **Arguments:** `[ $1: Sets the return mode to 'name' if value is '--return=name' ]`
- **Outputs:** Prints either the directory or the name of the selected cluster.
- **Returns:** Returns 1 if no clusters are found. Returns 0 after successfully selecting a cluster in either interactive or non-interactive mode.
- **Example usage:**
    ```bash
    select_cluster --return=name
    ```

### Quality and security recommendations

1. For better script security, ensure all input data is validated and sanitized to mitigate the risk of injection attacks.
2. Always check return values from functions and handle any potential errors appropriately.
3. Make good use of local variables to limit the scope to the current shell and to avoid possible variable name conflicts.
4. Use double quotes around variable references to avoid word splitting and pathname expansion.
5. Regularly update the script and maintain proper documentation for easier debugging and maintenance.

