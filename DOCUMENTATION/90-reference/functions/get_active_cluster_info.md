### `get_active_cluster_info`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: 9343c2f4e3a1e406a9b3535d1ac5d056322bb64a1c7c08b644dcc2aa5b70914a

### Function overview

The `get_active_cluster_info` function is designed to retrieve information about the active cluster in a specific directory. It verifies the number of clusters available in the directory. If no clusters are found, the function alerts the user and returns an error. If only one cluster is present, it notes that only one cluster is in use and outputs the cluster.conf file associated with the cluster. If multiple clusters are present, it checks if there is an active link to a cluster. If so, it uses that cluster. Otherwise, it lets the user select which cluster's information they want to view.

### Technical description

- **Name**: `get_active_cluster_info`
- **Description**: This function is responsible for retrieving and outputting the configuration information (cluster.conf) for the currently active cluster.
- **Globals**: [ `HPS_CLUSTER_CONFIG_BASE_DIR`: This is the base directory which contains cluster directories. Default to /srv/hps-config/clusters if not already set. ]
- **Arguments**: No arguments are used in this function.
- **Outputs**: Outputs the path to the cluster.conf file of the selected/active cluster.
- **Returns**: Returns `1` if no clusters found or if the active cluster's config is missing, otherwise returns nothing.
- **Example usage**: To use this function, simply enter `get_active_cluster_info` in the command line and press Enter.

### Quality and security recommendations

1. Add input validation to ensure that the global variable `HPS_CLUSTER_CONFIG_BASE_DIR` is a valid and accessible directory for added security.
2. Update the function to handle unexpected situations more robustly, such as handling cases where the target directory does not exist, or encountering read errors.
3. Make sure that the permissions for the directories and files the function is interacting with are configured properly to prevent unauthorized access or modification.
4. Consider adding more descriptive error messages to aid in troubleshooting.
5. Ideally, the function should be encapsulated in a script that performs further tasks such as logging actions, performing clean-up operations, and handling errors more gracefully.

