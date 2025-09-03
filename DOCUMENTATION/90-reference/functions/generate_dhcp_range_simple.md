### `generate_dhcp_range_simple`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 0b96ef1d9a801dba7584c3c03ea9f1327da1cd2685d343519ee3ae72aa66ecd8

### Function Overview
This function, `generate_dhcp_range_simple()`, is used to generate a DHCP range for a given local network provided in CIDR notation. The range generated is based on the network's gateway IP and its broadcast IP, as well as an optional count parameter that specifies the number of IP addresses in the range.

### Technical Description
**Function Name:** `generate_dhcp_range_simple()`

**Description:** This function generates a range of IP addresses suitable for use as a DHCP dynamic address pool. The IP range is calculated using the provided local network (in CIDR notation), a gateway IP, and an optional count parameter, which defaults to 20 when not specified.
  
**Globals:** None
  
**Arguments:**
  - `$1:` network_cidr (e.g. `192.168.50.0/24`)
  - `$2:` gateway_ip (e.g. `192.168.50.1`)
  - `$3:` count (default: `20`)
  
**Outputs:** A range of IP addresses for DHCP purposes is generated.
  
**Returns:** The function doesn’t return anything, it just executes side effects.

**Example Usage:** 
```bash
generate_dhcp_range_simple "192.168.50.0/24" "192.168.50.1"
```

### Quality and Security Recommendations
1. For improved data validation, consider adding checks to ensure the CIDR and gateway IP are valid before the function uses them.
2. To avoid potential information leak, consider muting `ipcalc` command internal verbose logs if not necessary for active debugging.
3. Test the function thoroughly using different network setups and gateway IPs to ensure it functions correctly under different attribute values.
4. Consider integrating a logging system for easier debugging.
5. Make sure the script has appropriate permissions, limiting the exposure of the function to avoid unauthorized use. Remember, script that alters network configuration could be a potential security risk if misused.

