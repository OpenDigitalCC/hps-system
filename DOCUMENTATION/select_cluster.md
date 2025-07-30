## `select_cluster`

Contained in `lib/functions.d/cluster-functions.sh`

### Function overview
The `select_cluster` function is designed to allow users to choose from a list of cluster configurations stored in a base directory. The function will catch and handle the case where no clusters are found in the specified directory.

### Technical description
- **name:** `select_cluster`
- **description:** This function presents the user with a choice of directories located within a base directory. These directories are intended to represent various clusters from which the user can select. The function uses a conditional check to handle cases where no directories (representing clusters) are found within the specified base directory.
- **globals:** [ `HPS_CLUSTER_CONFIG_BASE_DIR`: This global variable stores the location of the base directory containing the clusters. ]
- **arguments:** [ None ]
- **outputs:** If no clusters are found, the function outputs an error message to stderr. In the event that clusters are found, the user is prompted to select one and then the selected directory (cluster) is output.
- **returns:** The function will return `1` if no clusters are found. If a selection is made, the function returns the selection before exiting.
- **example usage:** Assuming `HPS_CLUSTER_CONFIG_BASE_DIR` is a directory with subdirectories representing clusters, the following command will initialize the function:

```bash
select_cluster
```
### Quality and security recommendations

- Consider adding input validation or error handling for the base directory's value to increase the function's robustness.
- Document the expected structure and format of the base directory and its subdirectories.
- Account for potential edge cases, such as the base directory containing non-directory files or the presence of hidden directories.
- Increase the verbosity of error messages to aid in debugging.
- To enhance security, consider restricting the permissions of the base directory and its contents so they are only accessible by intended users or groups.
- If possible, avoid using global variables and favor parameters or local variables within the function; this can help ensure that the function doesn't inadvertently modify data that it doesn't own.

