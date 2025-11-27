### `o_vm_get_healthy_nodes`

Contained in `lib/functions.d/o_vm-functions.sh`

Function signature: 0fd072e62375745d0379b61631516ed1a9edcdecc9c23774227390ad74f9b2d0

### Function Overview 

The `o_vm_get_healthy_nodes` function takes a list of nodes as the argument and checks their health. The initial empty string and counters are set for keeping track of the healthy nodes and total count. The function loops through each node, validating its status, increments the total count, adds it to healthy nodes if it's valid, and adjusts the healthy count. The function then trims leading spaces in the end from the string of healthy nodes and logs the number of found healthy nodes out of the total. If any healthy nodes are found, the function will display these nodes. The function will always return 0.

### Technical Description

- **Name:** `o_vm_get_healthy_nodes`

- **Description:** This function checks the health status of nodes passed in a list as an argument. It logs an error and returns 1 if the node list is empty and lists out the healthy nodes, if present.

- **Globals:** None

- **Arguments:** `[ $1: node_list ]` - A list of nodes passed as an argument.

- **Outputs:** Logs the number of 'healthy' nodes found out of the total and prints their list if present. Logs an error and returns 1 if the node list is not provided as an argument.

- **Returns:** Always returns 0, unless the node list is empty, in which case it returns 1.

- **Example Usage:**

```bash
nodes_list="Node1 Node2 Node3"

o_vm_get_healthy_nodes "$nodes_list"
# Output: Node1 Node3
# (Assuming Node1 and Node3 are healthy)
```

### Quality and Security Recommendations

1. Validate that each node in the node list is an acceptable format before checking the node's health, to prevent execution with improper data.
2. Consider improving error handling by ensuring the function exits upon encountering an error, instead of continuing to run through the loop.
3. Add more detailed logging messages to make debugging easier.
4. Your script should manually handle cases where a node is neither healthy nor unhealthy, like in a 'degrading' state.
5. Maintain a secure environment by making sure that sensitive information is not printed or logged and ensure log files have proper access permissions.

