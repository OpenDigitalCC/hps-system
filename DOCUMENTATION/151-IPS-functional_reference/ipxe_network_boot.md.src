### `ipxe_network_boot`

Contained in `lib/functions.d/ipxe-menu-functions.sh`

Function signature: e2e2b58a92e9af696185f032c9e7372a47cee6530ad51ea9189fc8f257805669

### Function overview
The function `ipxe_network_boot` is a Bash function which is used to boot a Network Interface Controller (NIC) by using the Internet Protocol network booting method (iPXE). It accepts the MAC address of the NIC, obtains the operating system (OS) name using the MAC address, logs the booting process, and calls the function corresponding to the OS name, provided that function is declared. If no such function is declared, an error message is returned.

### Technical description
**Function Name**: ipxe_network_boot

**Description**: This function bootstraps a network boot using iPXE for the provided MAC address.

**Globals**: None

**Arguments**: 
- `$1`: The MAC address of the NIC to be booted. 

**Outputs**: Debug logs on standard output showing the OS being net booted.

**Returns**: Calls the respective iPXE boot function based on the OS name. If the function does not exist, it terminates with an error message.

**Example Usage**: `ipxe_network_boot "00:11:22:AA:BB:CC"`

### Quality and security recommendations
1. Always use quotes around variable names in bash to avoid errors when they contain spaces.
2. Implement additional error checking to confirm if a valid MAC address is passed as an argument.
3. Ensure that logging does not expose sensitive data, which may potentially be exploited.
4. Make sure that the function only allows booting the desired OSs and deny others for security reasons.
5. It is recommended to implement checks to make sure that only the authorised users can use this function.
6. Always check return values and error messages for all operations.

