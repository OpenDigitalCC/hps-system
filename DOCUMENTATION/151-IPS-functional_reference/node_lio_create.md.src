### `node_lio_create`

Contained in `lib/host-scripts.d/common.d/iscsi-management.sh`

Function signature: 98eefecb076b12ce8574e70fbcdc3dbe7da279292f2b27fad96ad89b969a1f6e

### Function overview
The `node_lio_create` function sets up an iSCSI target node using the Linux IO (LIO) Target-core storage abstraction layer. It does so by taking three optional arguments for iqn, device, and acl. The function validates and checks the existence of required arguments (iqn and device), extracts the backstore name from iqn, creates the backstore, the iSCSI target and the LUN, configures the ACL if provided and saves the configuration.

### Technical description
- **name:** node_lio_create
- **description:** A bash function to set up an iSCSI target node using the Linux IO (LIO) Target-core storage abstraction layer via targetcli.
- **globals:** None
- **arguments:** 
    - `$1`: iqn – the iSCSI Qualified Name, an unique identifier for an iSCSI node.
    - `$2`: device – the device to be used for the iSCSI target.
    - `$3`: acl – Access Control List to control which initiators are granted access.
- **outputs:** Logs messages regarding process status (e.g., success/failed to create backstore/iSCSI target/etc.)
- **returns:** 
    - `0`: if the iSCSI target has been successfully created.
    - `1`: if a failure occurred (unknown parameter, missing required parameters, non-existing device, failure to create backstore/iSCSI target, etc.)
- **example usage:** `node_lio_create --iqn iqn.2003-01.com --device /dev/sdb --acl iqn.1994-05.com.redhat:dhclient`

### Quality and security recommendations
1. The function should sanitise all user input data to prevent potential command injection attacks or faulty operations.
2. The function could implement some logging mechanism, preserving a history of operations for further analysis or debugging.
3. Improve error messages by stating exactly which parameter(s) is/are missing instead of the generic message
4. The function could handle different input formats and conversions. For instance, device input could be accepted as device UUID instead of device path only.
5. Including more comprehensive tests for edge cases or exceptional circumstances, such as when the system lacks the necessary resources to create a new target.
6. Encryption should be considered for the transmitted data as this function disables authentication for demo/testing purposes. This feature should be taken out of production versions or controlled by an additional variable.

