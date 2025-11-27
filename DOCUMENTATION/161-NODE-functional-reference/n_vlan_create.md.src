### `n_vlan_create`

Contained in `lib/node-functions.d/common.d/n_network-functions.sh`

Function signature: ef56d7f556ee4dc1eff461d4554ebcd6fa4417a20a048f5a0cb407cd62b05eb2

### Function Overview

The `n_vlan_create` function is used to create a VLAN (Virtual Local Area Network) on a physical network interface. It takes three arguments - the physical interface to create the VLAN on, the VLAN ID, and optionally, the MTU (Maximum Transmission Unit). The function first validates these arguments, then checks the existence of the physical interface. If a VLAN already exists on that interface with the same ID, it's deleted and a new one is created. An MTU check is conducted and if the requested MTU is larger than the physical interface's current MTU, it's updated. If there are any issues during these steps, appropriate error or warning logs are generated. Finally, the newly created VLAN is enabled.

### Technical Description

- **Function Name**: `n_vlan_create`
- **Description**: This function creates a virtual local area network (VLAN) on a specified physical network interface, with a specified VLAN ID and Maximum Transmission Unit (MTU).
- **Globals**: `phys_iface`, `vlan_id`, `mtu`
- **Arguments**: 
  - `$1`: The physical network interface on which to create the VLAN.
  - `$2`: The ID of the VLAN to be created.
  - `$3`: The Maximum Transmission Unit (MTU) size. This argument is optional and defaults to 1500 if not provided.
- **Outputs**: The function will echo usage instructions if the required arguments are not supplied. It will also log error and warning messages to console during execution.
- **Returns**: `1` if an error occurs; `0` if the function successfully created and enabled the VLAN.
- **Example Usage**: `n_vlan_create eth0 100 1600`. This command creates a new VLAN with ID 100 on `eth0` with an MTU of 1600.

### Quality And Security Recommendations

1. Input validation: Currently, there is no check to ascertain whether the provided VLAN ID falls within the accepted range (1-4094). Implement this check to prevent invalid VLAN IDs.
2. Error handling: The function should handle errors more gracefully. Rather than continuing with process even after a failure, reconsider exit after a serious error.
3. Usage of sudo: All `ip link` commands require root privileges. So, either run the function with `sudo` or use the command `sudo` within function to prevent permission issues.
4. Secure logging: Use secure logging mechanisms like `syslog` for error or output logging, rather than directly outputting to console. This can provide better access control and auditing capabilities.
5. Harden the use of `sleep 1`: Usage of sleep without any condition might lead to unnecessary process delay or blocking. Instead, implement a wait mechanism with verification on `ip link delete` operation.

