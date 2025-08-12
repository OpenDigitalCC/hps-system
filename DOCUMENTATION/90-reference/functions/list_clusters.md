#### `list_clusters`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: 93e2d81ba91f8f27fd695171a6ba9261942077d5e68bbf9699a91e819f6fdd9e

##### 1. Function Overview
The `list_clusters` function is designed to list and display all clusters located within the configured base directory of a High Performance Server's (HPS) clusters. This function makes use of the `nullglob` Bash option, which allows for the prevention of errors when no files or directories match the provided pattern. The function iterates through each cluster in the base directory and echoes its base name to the standard output. 

##### 2. Technical Description

- **Name:** list_clusters
- **Description:** This function is used to list all clusters present in the base directory set by `HPS_CLUSTER_CONFIG_BASE_DIR`.
- **Globals:** `HPS_CLUSTER_CONFIG_BASE_DIR`: This variable describes the base directory where the HPS clusters are located.
- **Arguments:** No arguments are required to be passed to this function.
- **Outputs:** The base names of the clusters located in the `HPS_CLUSTER_CONFIG_BASE_DIR` directory.
- **Returns:** It does not explicitly return a value, but echoes names of clusters on standard output.
- **Example Usage:** 
```bash
list_clusters
```

##### 3. Quality and Security Recommendations

Given the function simply outputs the names of directories, it poses minimal security threats. However, a few general recommendations can be made to ensure best practices:

1. **Access Control:** The script should ensure that proper access controls are placed on the base directory. The script should also verify the reader's permission before access. 
   
2. **Path Sanitization:** If there is user interaction before this function, ensure that path values coming from users are sanitized to prevent potential directory traversal attacks.

3. **Error Handling:** The script should handle scenarios where the base directory doesn't exist or couldn't be read, as well as when there are no subdirectories present.

4. **Documentation:** While this function is straightforward, documenting its expectations and output can help with usage and troubleshooting.
   
5. **User Feedback:** Providing a feedback when no clusters are found might enhance the user experience.

