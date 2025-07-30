## `initialise_cluster`

Contained in `lib/functions.d/cluster-functions.sh`

### Function Overview

The `initialise_cluster` function is utilized for initializing a new cluster in a High Performance System (HPS). It takes as input a cluster name and creates relevant directories and a configuration file within a base directory (default: `/srv/hps-config/clusters`). The function will check if a cluster directory already exists and will stop execution if so. It also uses the `export_dynamic_paths` function to export cluster paths.

### Technical Description

- **name**: `initialise_cluster`
- **description**: This function accepts a cluster name and initializes relevant directories and a configuration file within a base directory for the HPS. It also checks if a cluster directory already exists and halts execution if it does. Additionally, it exports cluster paths using the `export_dynamic_paths` function.
- **globals**: `HPS_CLUSTER_CONFIG_BASE_DIR`: The base directory where the cluster directories and files will be stored. Default is `/srv/hps-config/clusters`.
- **arguments**: `[ $1: Cluster name for the new cluster, ]`
- **outputs**: Display whether a new cluster was initialized or if there was an error, and on successful creation, it shows the created config.
- **returns**: 1 if a cluster name was not provided, 2 if the cluster directory already exists, 3 if an error occurred in exporting cluster paths using the `export_dynamic_paths` function.
- **example usage**: 

```bash
initialise_cluster "new_cluster"
```

### Quality and Security Recommendations

1. Enhance error handling: Include more comprehensive error handling and reporting. This function currently presents potential avenues for failures, such as if the base directory cannot be written to or if `mkdir` or `cat` fail.
2. Sanitize inputs: Validate the cluster name for potential security issues. For instance, an unexpected input could navigate out of the desired directory structure and overwrite arbitrary files.
3. Consider concurrency: If multiple scripts might run this concurrently, add checks or implement file locking mechanisms to avoid conflicts.
4. Remove global variables: Global variables can make a script harder to reason about and more prone to errors. Consider alternatives such as passing variables as arguments to functions.
5. Robustness: The function should check whether the `export_dynamic_paths` function exists before attempting to call it.

