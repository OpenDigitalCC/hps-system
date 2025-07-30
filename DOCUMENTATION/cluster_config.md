## `cluster_config`

Contained in `lib/functions.d/cluster-functions.sh`

### Function Overview

The `cluster_config` function is used as a utility to interact with an active cluster configuration file. It has three operations: get, set, and exists. The `get` operation retrieves the value for a specified key from the cluster file. The `set` operation adds or updates a key-value pair in the cluster file. Lastly, the `exists` operation checks if a particular key exists in the cluster file. 

### Technical Description

- Name: `cluster_config`
- Description: A utility function to get, set, or check if a key-value pair exists in an active cluster configuration file.
- Globals: None.
- Arguments: 
  - `$1`: This is the operation to be performed: get, set, or exists.
  - `$2`: This is the key that is being manipulated or queried.
  - `$3`: This is the value that is used when the 'set' operation is selected. It is an optional parameter with a default empty string.
- Outputs: 
  - Value of a defined key if the 'get' operation is selected.
  - Confirmation of an update or addition if the 'set' operation is selected.
  - Existence logics if the 'exists' operation is selected.
  - An error message if an invalid operation is chosen or if there's no active cluster config.
- Returns: 
  - `1` if no active cluster configuration is found.
  - `2` if an invalid operation is chosen.
- Example usage:

```sh
cluster_config get nodeSize
cluster_config set masterNode 'Master-1'
cluster_config exists nodeSize
```

### Quality and Security Recommendations 

1. Sanitizing inputs: Since the values of the variables could come from untrusted sources, it would be sensible to sanitize these values before they are used.
2. Error checking: Beyond the three defined operations (get, set and exists), an error gets thrown but with a generic message. It would be good to have a separate error message for absent cluster config and invalid operation selected.
3. Logging: More detailed logging might be useful for debugging purposes.
4. Commenting: More detailed commenting throughout the function will make the function easier to maintain.
5. Function validation: Check if `cluster_config` function actually exists before calling it.

