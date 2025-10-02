### `list_cluster_hosts`

Contained in `lib/functions.d/dns-dhcp-functions.sh`

Function signature: 9d0cf700c3819fc0712f3ee2664e742b93ed371801fdb6e35ba382d3f7fdc9bd

### Function overview

The Bash function `list_cluster_hosts()` is used to list the hosts in a cluster. It checks if the host configuration directory exists and is readable. The function then finds all configuration files inside that directory, extracts and normalizes MAC addresses for each file, and returns a list of these addresses. If an invalid MAC address is found, it logs a warning and skips to the next file.

### Technical description

- **Name:** `list_cluster_hosts`
- **Description:** This function checks if the host configuration directory exists and is readable. Then, it scans through all configuration files in the directory, normalizes the MAC addresses found, and returns a list of these MAC addresses as a string. In case a configuration file does not exist or an invalid MAC address is found, a warning is logged and the function proceeds with the next file.
- **Globals:** `$HPS_HOST_CONFIG_DIR: A path to the host configuration directory`
- **Arguments:** `None`
- **Outputs:** A space-separated string of normalized MAC addresses.
- **Returns:** Function returns 0 if the function completes successfully, and 1 if the host configuration directory does not exist or is not readable.
- **Example usage:**
```bash
hosts=$(list_cluster_hosts)
echo "Host MAC addresses: $hosts"
```

### Quality and security recommendations

1. **Error Handling:** Additional error handling could be integrated to capture and mitigate potential issues such as a missing key function like `normalise_mac`.
2. **Parameter Validation:** Apply strict validation rules on parameters like `HPS_HOST_CONFIG_DIR` to ensure they contain valid data before proceeding with the rest of the function.
3. **Security:** Make sure that sensitive data such as MAC addresses are handled securely and not exposed in logs or any other insecure means.
4. **Optimization:** The functionality of iterating over all configuration files and extracting MAC addresses could potentially be optimized to improve the performance of the function.
5. **Testing:** Extensive testing should be carried out to ensure the robustness of the function under various scenarios.

