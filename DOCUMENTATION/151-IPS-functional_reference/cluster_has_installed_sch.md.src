### `cluster_has_installed_sch`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: 409c4d1b1b370935d8896096a0eba8d1aee600a78f18df3551d875126c299da2

### Function Overview
The `cluster_has_installed_sch` function is a tool that is used to determine if there is at least one School (SCH) host in the cluster that has been installed. It entirely depends on two different function helpers; `host_config` and `list_cluster_hosts`. It iterates over each host within a cluster, and for each host, it first checks if it is of type SCH, and then if that SCH host is in an installed state. If it finds a SCH host that is installed, it returns 0 to indicate success, else it returns 1.

### Technical Description
**Name**: cluster_has_installed_sch

**Description**: This Bash function checks if there is at least one installed host of type SCH in a cluster.

**Globals**:

- None

**Arguments**:

- No arguments are required for this function.

**Outputs**:

- It doesn't print anything to stdout.

**Returns**:

- 0: If an Installed SCH host is found in the cluster.
- 1: If no Installed SCH hosts are found in the cluster.

**Example usage**:

```bash
if cluster_has_installed_sch; then
  echo "There is at least one installed SCH in the cluster."
else
  echo "No installed SCH found in the cluster."
fi
```

### Quality and Security Recommendations
1. Add input validation measures to ensure that helper functions like `host_config` are receiving valid inputs for a better and safer execution.
2. Consider logging the operation and outcomes. It would help while debugging, in case something goes wrong.
3. You might also want to improve error handling to better account for any common issues that might occur and provide more verbose information.
4. Check if helper functions `host_config` and `list_cluster_hosts` exists before their usage, as they seem to be crucial for this function.
5. To avoid calling multiple times `host_config` function for each host, fetch all config at once then filter on it.

