### `n_storage_network_setup`

Contained in `node-manager/base/n_storage-functions.sh`

Function signature: b9d955ab898629611ccbb3c79adf2cb697c037821b05b564e6e5b61ababbb529

### Function overview

The `n_storage_network_setup` function sets up a network storage allocation given a physical interface and an optional storage index. It queries the hardware MAC address and then requests an IP allocation from an IPS. If allocation is successful, the function will parse the allocation into several components like `vlan_id`, `ip`, `netmask`, etc. For each component, a corresponding variable is created which is then used to create a VLAN with `vlan_id` and `mtu`, and assigns the `ip` and `netmask` to the VLAN interface. The function concludes by testing the accessibility of the IP gateway.

### Technical description

- **Name**: n_storage_network_setup
- **Description**: Sets up a network for a given storage given an interface and optional index.
- **Globals**: None.
- **Arguments**: 
   - `$1`: The local physical interface for the storage.
   - `$2`: Optional index number for the storage. Defaults to `0` if not provided.
- **Outputs**: Logs messages indicating the progress of the allocation and any potential errors.
- **Returns**: 
   - `0` if the function successfully executed.
   - `1` if there's an error (ex. failed to get the IP allocation, create VLAN, or add IP to the interface).
- **Example Usage**: `n_storage_network_setup eth0 1`

### Quality and security recommendations

1. Always validate the inputs of the function. Make sure that the physical interface provided exists.
2. Validate the response when making a request for IP allocation. Make sure it returns the expected format.
3. Add error logging statements in every failure point. This increases the debuggability of the function.
4. It may be useful to implement a rollback mechanism for failed allocations to avoid leaving incomplete configurations in the system.
5. Treat all function inputs as potentially malicious and sanitize/escape them as needed. Never trust user input implicitly.

