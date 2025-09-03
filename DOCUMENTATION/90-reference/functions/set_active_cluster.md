### `set_active_cluster`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: c4f4f433c7e18e128366307bf60133a4e18e81d677c586a39bfe81ef13c6d637

### Function overview

This function `set_active_cluster` is used to set an active cluster configuration by establishing a symbolic link to the specified cluster's directory from a designated 'active-cluster' file location. The function requires a single argument: the name of the cluster. The function establishes a consistently accessible location, referenced as 'active-cluster', through which to access the current, or active, cluster configuration.

### Technical description

- **name**: `set_active_cluster`
- **description**: This function sets an active cluster configuration by establishing a symbolic link to the specified cluster's directory. 
- **globals**: [ `HPS_CLUSTER_CONFIG_BASE_DIR`: The base directory for the cluster configuration files. ]
- **arguments**: [ `$1`: The name of the cluster to activate.]
- **outputs**: Error messages to stderr if either the cluster directory or 'cluster.conf' file does not exist. Confirmation message to stdout when the active cluster is successfully set.
- **returns**: `1` if the cluster directory is not found, `2` if the 'cluster.conf' file is not found in the cluster directory, `0` (implicit) if the active cluster is successfully set.
- **example usage**:

```bash
$ set_active_cluster "my-cluster"
```

### Quality and security recommendations

1. Implement additional error checking for the existence and availability of the base directory and 'active-cluster' link.
2. Report errors with both a unique message and distinct error code for easier troubleshooting.
3. Check the input for malicious code injections or incorrect formatting before executing the function.
4. Consider limiting the permissions of the 'active-cluster' link for security.
5. Implement logging mechanism to keep a record of which cluster configuration was set active at what time for auditing purposes.
6. Optionally, you might want to backup the existing 'active-cluster' link before creating a new one.

