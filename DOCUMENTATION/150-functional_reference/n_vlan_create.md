### `n_vlan_create`

Contained in `lib/host-scripts.d/common.d/n_network_functions.sh`

Function signature: 3690b98c049b24b83d75f48dae821a680194f45f901cafdaffbaff34a2d58326

### Function overview

The `n_vlan_create` function is used to create a Virtual Local Area Network (VLAN). A VLAN is a subnetwork within a larger network, providing network isolation at the data layer. In this function, an existing network interface is used to create a VLAN with a specified ID. The function first removes the VLAN if it already exists, then creates the VLAN and sets up the network interface with the desired Maximum Transmission Unit (MTU).

### Technical description

- **name**: `n_vlan_create`
- **description**: Creates a VLAN with a specified ID for a physical network interface. If the VLAN already exists, it is removed before creating the new one.
- **globals**: None
- **arguments**: 
  - `$1: phys_iface` (description: The name of the physical interface to create the VLAN on)
  - `$2: vlan_id` (description: The ID of the VLAN to create)
  - `$3: mtu` (description: The Maximum Transmission Unit size, defaults to 1500 if not provided)
- **outputs**: None
- **returns**: Always returns 0 to indicate success.
- **example usage**: `n_vlan_create eth0 10 1500`

### Quality and security recommendations

1. Make sure you validate the inputs to this function to prevent any inadvertent modification of network configurations.
2. Be sure to handle error conditions appropriately. In the current implementation, errors are suppressed, particularly when attempting to delete an existing VLAN.
3. Always ensure that the VLAN ID and MTU values provided are within the acceptable range before creating the VLAN.
4. Make sure to sanitize the `phys_iface` input to prevent possible command injection attacks.

