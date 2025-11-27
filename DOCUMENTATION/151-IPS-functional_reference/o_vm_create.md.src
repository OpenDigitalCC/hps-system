### `o_vm_create`

Contained in `lib/functions.d/o_vm-functions.sh`

Function signature: 80ea2cc0b46e856dd51c246e33ff177372cbf92d050c7520cf1fa14fb9432edd

### Function overview

The function `o_vm_create()` is used to create a virtual machine (VM) on a specified target node. The function validates the provided VM identifier and target node, checks the state of the target node, logs the start of the operation, creates a service name, and then creates task service to build the VM. The function waits for instance availability on target node and once available, it executes the task. After the VM creation task completion, the function cleans up the task service and determines the correct return code based on the various scenarios of success and failure in the task execution and cleanup process.

### Technical description

- **Name:** `o_vm_create`
- **Description:** This function creates a virtual machine on a specified target node.
- **Globals:** None
- **Arguments:** 
  - `$1`: vm_identifier: Identifier for the virtual machine to be created.
  - `$2`: target_node: Node on which the virtual machine is to be created.
- **Outputs:** Logs during various steps of the function.
- **Returns:** Based on the various conditions and scenarios:
  - Returns 1: If the parameters are invalid.
  - Returns 2: If the target node is not found in the cluster.
  - Returns 3: If the OpenSVC daemon is not running on the target node.
  - Returns 4: If the target node is frozen or in an error state.
  - Returns 5: If failed to create task service for VM.
  - Returns 6: If timeout occured while waiting for service instance on target node.
  - Returns 7: If Task failed but cleanup succeeded.
  - Returns 8: If Task succeeded but cleanup failed.
  - Returns 9: If both task execution and cleanup failed.
  - Returns 0: If both succeeded.
- **Example Usage:**

```
o_vm_create "vm1" "node1"
```

### Quality and security recommendations

1. Add data sanitization for parameters passed to the function.
2. Return specific error messages based on the error codes for better debugging.
3. Implement a timeout mechanism for each step for robustness.
4. Add additional error checking and handling for each function call within this script, especially handling for unknown errors.
5. Include logging for debugging and auditing purposes to track all activities related to VM creation.
6. The use of static values such as `max_wait=30` should be avoided. Consider replacing such instances with configurable parameters.
7. Regularly update and review your system for potential security holes + vulnerabilities.
8. Verify user permissions before allowing VM creation to avoid any unauthorized access or operations.

