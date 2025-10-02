### `initialise_opensvc_cluster`

Contained in `lib/host-scripts.d/rocky.d/opensvc-management.sh`

Function signature: 5ae00b0ed52acd2fc297bb42596c4d4828b6218e0a73be9e8e50fce1f927287d

### Function Overview

The Bash function `initialise_opensvc_cluster()` is responsible for setting up an OpenSVC cluster. It retrieves necessary values such as the cluster name, cluster secret and tags from the host configuration. It handles the setup logic pertaining to different conditions, whether the parameters are not found or the heartbeat type is not set. It applies the cluster configuration using the OpenSVC commands and sets the node tags (if any are found). The function concludes with logging the completion of cluster initialization.

### Technical Description
```pandoc
- name: `initialise_opensvc_cluster()`
- description: A function to initialize an OpenSVC cluster by reading config values, configuring the cluster, and setting node tags.
- globals:
  - `VAR: cluster_name`: The name of the cluster.
  - `VAR: cluster_secret`: The secret key associated with the cluster.
  - `VAR: ips_addr`: The IP addresses associated with the nodes of the cluster.
  - `VAR: node_tags`: Tags associated with the node types in the cluster.
- arguments:
  - `$1: None`: This function doesn't take any arguments.
- outputs: Logs detailing steps of the OpenSVC cluster initialization and potential errors.
- returns: `1` if any error occurs during cluster initialization, otherwise no explicit return.
- example usage:
  - initialise_opensvc_cluster(): This function doesn’t take any arguments. You can simply call it in your bash script to initialize a cluster.
```

### Quality and Security Recommendations
1. For security purposes, avoid logging the `cluster_secret` variable as it might expose sensitive information.
2. Add error handling to the remote cluster variable calls to handle scenarios where these calls fail.
3. Return explicit values for success scenarios, currently, the function does not return anything upon success.
4. Consider making the function more reusable by providing arguments instead of using global variables.
5. Make sure the global variable `node_tags` is not manipulated outside of the function as this function directly depends on its value.
6. Document the expected format and values for the node_tags variable for easier debugging and usage.

