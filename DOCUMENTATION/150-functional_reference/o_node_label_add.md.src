### `o_node_label_add`

Contained in `lib/functions.d/o_node-label-functions.sh`

Function signature: 7662084d4bf2ccba6e23772abd53850712c663ff7956e960844c09c8b7fcd8b8

### Function Overview

The `o_node_label_add` function in Bash is designed to add a specific label to one or multiple nodes. The function takes three arguments, namely the nodes to be labeled, a key for the label, and a value for the label. It validates the parameters, ensures the nodes exist, and then iterates through all the nodes to apply the label. This function uses logs to display information or errors, and has built-in error handling to return different statuses depending on the outcome.

### Technical Description

- **Name**: `o_node_label_add`
- **Description**: This function adds a specific label (defined by key and value) to one or more nodes. If the nodes parameter is "all", it will apply the specified label to all existing nodes. It validates all parameters and handles errors by logging and returning status codes.
- **Globals**: No global variables are modified by this function.
- **Arguments**:
   - $1: nodes - The nodes to which the label should be added. Can be an array of node names or "all" to apply label to all nodes.
   - $2: label_key - The key of the label to be added.
   - $3: label_value - The value of the label to be added.
- **Outputs**: This function logs info and error messages during its execution.
- **Returns**: 
   - 0: All operations completed successfully.
   - 1: Function was provided with invalid arguments or failed to get node list.
   - 2: Failed to add label to one or more nodes.
- **Example Usage**: `o_node_label_add "node1 node2" "env" "prod"`

### Quality and Security Recommendations

1. Instead of comparing arguments to an empty string within the function, consider allowing Bash to enforce arguments during invocation by setting them as required.
2. For greater traceability and debugging, add more logging steps within the function, indicating the process along with the nodes to which the labels are being added.
3. To bypass arbitrary command execution, sanitize all user inputs provided as arguments.
4. Consider using double brackets [[ ]] for comparison operations as they are a safer and more powerful way of checking conditions in Bash.
5. Ensure om CLI tool is correctly installed and configured as this function is dependent on it.

