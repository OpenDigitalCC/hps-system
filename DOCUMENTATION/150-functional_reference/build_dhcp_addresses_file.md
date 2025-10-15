### `build_dhcp_addresses_file`

Contained in `lib/functions.d/dns-dhcp-functions.sh`

Function signature: e4e89283fe1d64f56e0de04c05dbae29598781f49b67ce46af38b86c9af58337

### Function overview
The function `build_dhcp_addresses_file` is a Bash function that builds a list of all the hosts in a network cluster and their associated address details. The function starts by creating a directory if it doesn't exist, and then retrieving a list of all hosts. It processes each host to retrieve and validate their MAC address, IP address, and hostname. The function checks for duplicate MAC and IP addresses, log warnings for duplicates, and stops the process in case of fatal errors like duplicate IP addresses. The details are subsequently written to a temporary file which is then moved to the final location. If successful, a confirmation log is generated with the count of entries created.

### Technical description

- **Name:** `build_dhcp_addresses_file`
- **Description:** Builds and writes DHCP addresses of all hosts to a file.
- **Globals:** `DHCP_ADDRESSES`, `DHCP_ADDRESSES_TMP`
- **Arguments:** None
- **Outputs:** Logs to standard output at different steps and levels (INFO, WARN, ERROR). Ultimately, outputs a file containing an entry for each host with MAC address, IP address, and hostname, comma-separated.
- **Returns:** `0` if successful, `1` otherwise
- **Example usage:**
```
build_dhcp_addresses_file
```

### Quality and security recommendations

1. Make sure to sanitize and validate all inputs and outputs of the function, if it is reused or depended upon in a context with untrusted input.
2. It would be beneficial to add more error handling to verify the success of commands within the function.
3. Adding comments to complex or obscure code sections would improve maintainability.
4. The function could could handle exceptions more gracefully, instead of aborting its operation at the first fatal error.
5. The function should ensure that all sensitive data, such as IP and MAC addresses, is securely handled and not exposed to unauthorized users or services.

