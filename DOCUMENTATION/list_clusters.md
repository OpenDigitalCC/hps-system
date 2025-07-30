## `list_clusters`

Contained in `lib/functions.d/cluster-functions.sh`

### Function Overview

The `list_clusters` function essentially lists all the clusters available in the High Performance Storage (HPS) cluster base directory. It accomplishes this by using a Glob function to capture the file path of all directories within the base directory. It then conveniently removes the base file path, leaving only the name of the cluster directories.

### Technical Description

- **Name**: list_clusters
- **Description**: This command operates in the bash shell to enumerate all directories (representing clusters) present within a specified base directory. It uses the globbing option of the bash shell to access the file paths to all directories in the base directory. The base file path is removed from each resulting string leaving only the name of the cluster which is then printed to the console.
- **Globals**: [ HPS_CLUSTER_CONFIG_BASE_DIR: the base directory which contains directories representing clusters ]
- **Arguments**: [ This function does not take arguments ]
- **Outputs**: Prints the names of the cluster directories to the console
- **Returns**: NULL
- **Example usage**: 
```bash
list_clusters
```

### Quality and Security Recommendations
To increase quality and security some recommendations are as follows:

1. Validate the existence of `HPS_CLUSTER_CONFIG_BASE_DIR` before using it. If not set, the function should handle the error gracefully and notify the user.
2. Ensure only authorized users can execute this function. Information about directories might be sensitive.
3. Ensure that all file reads from the directories are secure and sanitize any user-provided input to prevent directory traversal or other filesystem attacks.
4. Validate that the found directories match expected patterns to avoid unexpected behavior or security issues.
5. Handle edge case when there are no directories / clusters.
6. Add comments in the function to increase maintainability.

