### `o_node_label_exists`

Contained in `lib/functions.d/o_node-label-functions.sh`

Function signature: bf7eb0ec198341162d77fbfc57b8af2754d485e6cb2e9a77c980a30edb2eb1ed

### Function Overview
The function `o_node_label_exists()` is a Bash function that checks if a given node label exists in a system. By supplying it with a node, a label key, and optionally a label value, it determines whether the label configuration contains the specified key-value pair. After validating the parameters, it retrieves the node's label configuration and verifies if the supplied label key exists. If a label value is provided, the function also checks if it matches the existing value. It returns different status codes based on the results, making it an essential tool for instance configurations, especially in the context of node labelling in a cluster management.

### Technical Description
**Name:** `o_node_label_exists()`
 
**Description:** This function checks whether a given node label key (and optional value) exist. It takes three arguments, the name of the node, the label key, and optional label value. After getting configuration of node labels and checking for the key (and value if provided), it returns specific statuses depending on the result.

**Globals:** None

**Arguments:** 
- `$1: node` - The node name to check label in.
- `$2: label_key` - The label key to search for.
- `$3: label_value` - An optional value of the label.

**Outputs:** Diagnostic messages are redirected to the error stream (`stderr`).

**Returns:** 
- `0` if the key (and value if provided) exists
- `1` if either node or label key is not provided
- `2` if the label key (or value if provided) does not exist

**Example Usage:**
```bash
o_node_label_exists "node1" "label1" "value1"
```

### Quality and Security Recommendations
1. Always remember to provide a description for each return status code. This can help other developers to easily understand what each status code stands for.
2. The `o_node_label_exists` function does not check whether the input parameters are valid or safe. It's recommended to add validation procedures for input and also sanitize the input to prevent any form of security breach e.g. script injection.
3. Ensure that all global variables used by the function are clearly defined and initialized. Although this function does not use any global variables, it is a good practice to keep track of them. This would eliminate any chance of accidentally overwriting valuable data or exposing sensitive information.
4. Avoid suppressing output with `/dev/null` unless necessary. Output can often be a useful tool for debugging and auditing.
5. Always secure your bash scripts using the right file permissions. Scripts that can alter the system configuration should only be editable by trusted users.

