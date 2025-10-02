### `list_clusters`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: 3f954969c054c0715b3cb4975cc16f60b59455fed57d76db287682a09738b747

### Function overview

The `list_clusters()` function in Bash is used to list all clusters. It gathers cluster directories using the `_collect_cluster_dirs clusters` function call and stores the directories in a local array. The function also attempts to determine the active cluster name, ignoring any potential errors in case it is not set. If no clusters are found, the function alerts the user and returns an exit status of 0. Finally, it iterates over the array of clusters, and for each one, it checks if the cluster name matches the active cluster name and appropriately tags the active cluster in the output it echoes.

### Technical description

- **name**: `list_clusters()`
- **description**: This bash function lists all clusters. It collects cluster directories, determines the active cluster (if any), and iterates over the cluster list to echo each one while highlighting the active cluster.
- **globals**: 
  - `HPS_CLUSTER_CONFIG_BASE_DIR`: The base directory where cluster configurations are stored.
- **arguments**: None.
- **outputs**: Prints names of all clusters, marking the active one as '(Active)', if any.
- **returns**: 
  - `0`: When no clusters are found in the `HPS_CLUSTER_CONFIG_BASE_DIR`.
  - Other values could be returned if inner functions (`_collect_cluster_dirs` and `get_active_cluster_name`) return them.
- **example usage**: Simply run the function without any arguments as `list_clusters`.

### Quality and security recommendations

1. Error messages should be handled adequately. For instance, when no clusters are found, the program could inform the user on what steps to take.
2. The function could return unique exit codes for each type of failure to make debugging easier.
3. Consider sanitizing any user inputs or outputs, to prevent potential security risks.
4. The function should handle the possibility of not being able to collect cluster directories gracefully.
5. To achieve better code readability, consider adding more comments to explain complex code segments.
6. While the function does a good job managing local scope variables, careful attention must be paid to global variable usage. It could potentially cause conflicts with other parts of the program.

