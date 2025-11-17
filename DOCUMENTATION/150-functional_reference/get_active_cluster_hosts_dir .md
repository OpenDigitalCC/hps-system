### `get_active_cluster_hosts_dir `

Contained in `lib/functions.d/host-functions.sh`

Function signature: 5e8124c7c913768226948ae7120083b2568d70860f21c6599d89e81df548ee7d

### Function Overview
This function is called `get_active_cluster_hosts_dir` and it is used to get the path directory of the hosts from the currently active cluster. It achieves this by calling another function `get_active_cluster_link_path`, concatenating the resulting path with the string '/hosts' and then outputting the final string.

### Technical Description
Here's a full description of the various parts of the function:

- **Name**: `get_active_cluster_hosts_dir`
- **Description**: This function generates and outputs the path to the 'hosts' directory of the currently active cluster.
- **Globals**: None.
- **Arguments**: None.
- **Outputs**: The fully formed path to the 'hosts' directory of the currently active cluster.
- **Returns**: None.
- **Example Usage**:

```sh
    path=$(get_active_cluster_hosts_dir)
    echo $path # prints the path to the 'hosts' directory of the active cluster
```
    

### Quality and Security Recommendations

1. This function doesn't handle errors and might fail for various reasons (e.g. if `get_active_cluster_link_path` doesn't exist or doesn't output a string). Hence, it would be beneficial to add error handling to this function to make it more robust.
2. Since this function doesn't have any input validations or escaping, it might lead to issues if the output of `get_active_cluster_link_path` were to contain unusual characters (like space or glob characters). A good idea would be to ensure that the paths output by `get_active_cluster_link_path` are sanitized.
3. To ensure better trackability of problems, consider logging errors or warnings whenever the function behaves unexpectedly. This could be done using bash's built-in `echo` or `printf` commands combined with output redirections.

