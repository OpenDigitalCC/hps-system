### `initialise_cluster`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: 011e924e7a556253209f90291e5c11cc6d353538a17821169829f72b6d16fe0d

### Function overview

The function `initialise_cluster()` is a Bash function intended to initialize a new server cluster configuration within a given directory. If provided a cluster name, it will create a new directory with that name and set up necessary subdirectories and configuration files. If the cluster name is not provided, or if a cluster with the provided name already exists, the function will return an error message. If the initialization ends successfully, it will export dynamic paths for this cluster.

### Technical description

- Name: `initialise_cluster`
- Description: This function creates a new cluster configuration based on the given cluster name. It creates relevant directories, initial configuration file and exports dynamic paths for further use.
- Globals: `HPS_CLUSTER_CONFIG_BASE_DIR: The base directory in which the cluster configuration will be created`
- Arguments: 
     - `$1: The name of the cluster to initialize`
- Outputs: 
    - Various status messages, indicating whether configuration has been successfully completed or not.
    - Error messages, when an error occurred (e.g., missing argument, directory already exists).
- Returns:  
    - `0`: on successful initialization and cluster paths exported
    - `1`: if the cluster name was not provided
    - `2`: if the cluster directory already exists
    - `3`: if exporting cluster paths fails
- Usage Example: 
    ```bash
    initialise_cluster "my-cluster"
    ```

### Quality and Security Recommendations

1. Validate user input: Currently the function does not validate that the input is safe, or whether the name is reasonable for a directory name.
2. Handle or report errors from `mkdir`: If the the directories cannot be created, the function will still try to create the files, which will always fail.
3. Reduce scope of variables: Currently the function uses many local variables, which increase complexity and can potentially clash with identically named variables outside the function.
4. Execute least privilege: Ensure that the script is run with as few privileges as possible to avoid potential security risks.
5. Securely handle potential failures in file writing operations: Always check the status code after writing to a file. Failure to write to a file should be treated as an error and should be handled properly.

