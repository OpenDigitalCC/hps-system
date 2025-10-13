### `update_dns_dhcp_files`

Contained in `lib/functions.d/dns-dhcp-functions.sh`

Function signature: 03499dd691020e6c8242d0a4a804e259ee89585ebf7a058cf6c54eefbd9da8f7

### Function Overview

The Bash function `update_dns_dhcp_files` is designed to update DNS (Domain Name System) and DHCP (Dynamic Host Configuration Protocol) configuration files in a network environment. It does this by utilizing other internally defined functions, logging information, and error messages to keep track of the process. If either of the file update operations (DNS or DHCP) fails, the function will return an error. If both operations succeed, the dnsmasq service is reloaded to apply the new configurations, and the function successfully exits.

### Technical Description

- __Name__: `update_dns_dhcp_files`
- __Description__: This bash function updates DNS and DHCP configuration files. The update is considered successful when the DHCP addresses file and DNS hosts file both build without errors. If either file fails to build, the function logs an error message and a failure status is returned. If both files build successfully, `dnsmasq` is reloaded to pick up the new configuration.
- __Globals__: None.
- __Arguments__: None.
- __Outputs__: Logs [INFO] and [ERROR] messages using the inbuilt `hps_log` function.
- __Returns__: 
    - `0` If updating both DNS and DHCP files is successful.
    - `1` If building either DNS hosts file or DHCP addresses file fails.
- __Example usage__: The function is used without any arguments i.e
```bash
    update_dns_dhcp_files
```

### Quality and Security Recommendations

1. Consider using more detailed and unique error messages to assist debugging process and increase maintainability.
2. Techniques such as input validation and data sanitization should be implemented to increase security.
3. Always prefer using local variables inside a function to avoid side effects and accidental modification of global variables.
4. For long running processes, consider using methods to keep the user informed of the progress instead of simply running in the background.
5. Implement logging levels in `hps_log` function to control the verbosity of the logs in different environments (production, staging, development etc).
6. It might be helpful to wrap the dnsmasq service reload in a try-catch block to handle unexpected errors with the service restart.

