#### `generate_dhcp_range_simple`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 0b96ef1d9a801dba7584c3c03ea9f1327da1cd2685d343519ee3ae72aa66ecd8

##### Function overview

The `generate_dhcp_range_simple` function generates a DHCP range in a subnet. It takes a network CIDR, a gateway IP, and an optional count parameter to determine the range size. If the count is not provided, the function defaults to creating a range of 20 IPs.

##### Technical description

- **Name**: `generate_dhcp_range_simple`
- **Description**: A function that generates the IP range for DHCP in a given subnet.
- **Globals**: None
- **Arguments**: `$1`: network_cidr (e.g 192.168.50.0/24), `$2`: gateway_ip (e.g 192.168.50.1), `$3`: count (optional, defaults to 20)
- **Outputs**: This function outputs the calculated DHCP range.
- **Returns**: None directly. Outputs are sent to stdout.
- **Example Usage**:

    generate_dhcp_range_simple "192.168.50.0/24" "192.168.50.1" 30
This function would generate a DHCP range in the `192.168.50.0/24` subnet, starting at the gateway IP "192.168.50.1" and creating a range of 30 IPs.

##### Quality and security recommendations

1. The function uses ipcalc, an external tool, to calculate network and broadcast addresses. If this tool is not available or fails, the function will be unable to proceed. You may want to add error checks after calling `ipcalc`.
2. Ensure that the range count does not result in overlapping IP ranges. You may want to add logic to prevent the creation of overlapping ranges.
3. It is a good practice to validate all inputs before proceeding with the function. You may want to add checks to ensure that the network_cidr and gateway_ip are valid IPs in correct format.

