### `get_active_cluster_info`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: 51d7c68169c79cb4271c76d4914a13afce322dd3dab4f93ccfeba936798070ea

### Function Overview

The `get_active_cluster_info` function is a bash function designed to gather and display information about currently active clusters. This function first calls on another function, `_collect_cluster_dirs`, in order to get a list of cluster directories. Then the function checks if there are any active clusters. If there are none, it will print an error message and end the program. If there are active clusters, the function will proceed to print specific information about each cluster.

### Technical Description

- **Name**: `get_active_cluster_info`
- **Description**: This function gathers and displays information about currently active clusters. 
- **Globals**: `HPS_CLUSTER_CONFIG_BASE_DIR`: It holds the base directory path that the function will check for active clusters.
- **Arguments**: None
- **Outputs**: Error message if no clusters are found, otherwise list of directories stored in `dirs`.
- **Returns**: Returns 1 if no clusters are found, otherwise returns 0.
- **Example Usage**: `get_active_cluster_info`

### Quality and Security Recommendations

1. The function should include validation for the global variable `HPS_CLUSTER_CONFIG_BASE_DIR` to ensure it is correctly defined and it points to a valid directory.
2. Use descriptive error messages to allow for easier debugging, and in those error messages include potential solutions for the issues.
3. Ensure that the `_collect_cluster_dirs` function is properly securing and validating the data that it is returning.
4. Check directories for appropriate read permissions before attempt to collect directories.
5. It would be recommended to also provide some form of error handling, for scenarios when the function `_collect_cluster_dirs` isn't defined or fails to execute.
6. Consider adding logging functionality for tracking warnings or errors. This will help in maintaining the system and diagnosing problems.

