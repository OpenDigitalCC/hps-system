#### `get_active_cluster_info`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: 9343c2f4e3a1e406a9b3535d1ac5d056322bb64a1c7c08b644dcc2aa5b70914a

##### Function overview
The Bash function `get_active_cluster_info()` is used to retrieve the configuration file of an active cluster. It checks different scenarios: whether there are no clusters, only one cluster, or multiple clusters. Depending on the outcome, it returns a specific cluster configuration file, prints an error message, or prompts the user to select a cluster from a list.

##### Technical description

- **Name**: `get_active_cluster_info`
- **Description**: This function hosts a script that can get the active configuration of a cluster from a provided directory. The function checks if there are no, one, or multiple active clusters in the directory and acts accordingly. 
- **Globals**: 
  - `HPS_CLUSTER_CONFIG_BASE_DIR`: The base directory where cluster configurations are stored. Default is `/srv/hps-config/clusters`.
- **Arguments**: None
- **Outputs**: This function prints the path of the active cluster configuration file, or an error message when no clusters are found or when multiple clusters are found but none is designated as active.
- **Returns**: This function returns `0` if it successfully fetches the configuration file of an active cluster. Otherwise, it returns `1` if no clusters are found or when the active cluster configuration file is not found.
- **Example usage**: To fetch the active cluster configuration use the function in the terminal as follows:
    ```bash
    get_active_cluster_info
    ```
##### Quality and security recommendations
1. The function assumes the base directory which can present a security issue if not handled right. Consider asking for input from the user or having it as an argument with a default option.
2. Error messages are sent to `stderr`, which is good practice, but status codes returned might not be indicative enough for external applications that could use the function.
3. Add comments to code blocks to explain what each section does, which will make maintaining the code easier.
4. Consider edge cases where `readlink -f "$active_link"` might not return the expected output.
5. Make sure permissions for the active link file and directory are set correctly and only accessible by the expected users or groups of users.

