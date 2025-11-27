### `node_lio_delete`

Contained in `node-manager/rocky-10/iscsi-management.sh`

Function signature: 198653d7f8219c254d0f7d905c865d8994dd5dc9072af9cdbc979296660c9662

### Function overview
The function `node_lio_delete` is used to delete an iSCSI target and its associated backstore. The function works by parsing arguments to find the "iqn", validating if the iqn is provided or not, extracting the backstore name from said IQN, checking if the target and backstore exists, and then deleting the iSCSI target and its backstore on confirmation.

### Technical description

- **Name**: `node_lio_delete`
- **Description**: This function deletes an iSCSI target and its associated backstore using the iSCSI Qualified Name (IQN).
- **Globals**: N/A
- **Arguments**: 
  - `$1: --iqn`: the iSCSI Qualified Name (IQN)
- **Outputs**: Logs to the remote log file
- **Returns**: 
  - `0` if the iSCSI target and backstore are successfully removed 
  - `1` if required parameters are missing, or if the target and/or backstore do not exist or fail to be deleted.
- **Example usage**:  
  `node_lio_delete --iqn iqn.2003-01.org.linux-iscsi.localhost.x8664:sn.4cd98b114182`

### Quality and security recommendations

1. Validate the argument to ensure it is a well-formed IQN before attempting to process it.
2. Add error handling to address possible failure conditions when interacting with `targetcli`.
3. Use local variables wherever possible to avoid potential data leakage or accidental overwriting.
4. Use `local -r` to declare constants which prevents any subsequent code from accidentally modifying the variable.
5. Document each component of the function, and explain the purpose behind every major decision. This would be beneficial for maintainability and readability.

