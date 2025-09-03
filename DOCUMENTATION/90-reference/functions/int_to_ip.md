### `int_to_ip`

Contained in `lib/functions.d/host-functions.sh`

Function signature: 1acb712577aa9213ca920a051e80825c73d7775714d43d10ccad322458fc5946

### Function Overview

The function, `int_to_ip()`, translates an integer into its corresponding IP address. Given an IP address represented as an integer, this function will return the dotted-decimal representation of the IP address. Additionally, this function checks from a pool of unused IP addresses and generates a unique IP address not yet assigned to any hosts. Similarly, a unique hostname will also be created. Once an IP and hostname are generated, they will be assigned to the host configuration.

### Technical Description

- **Name**: `int_to_ip()`
- **Description**: Translates an IP represented as an integer into its corresponding dotted-decimal format. Also, it assigns IP and hostname to the host configuration after generating unused ones.
- **Globals**: 
  - `HPS_HOST_CONFIG_DIR`: Directory of host configuration.
- **Arguments**: `$network_base`: Base integer of entire network.
- **Outputs**: The function outputs the translated IP address from integer to a dotted decimal format.
- **Returns**: It could return 1 if there is no available IP in range or fails to generate a unique hostname.
- **Example usage**: 

```Bash
$ int_to_ip 668154256
```

### Quality and Security Recommendations

1. Implement proper error-handling to cater scenarios where input passed could not be translated to valid IP address.
2. It is crucial to validate the input integers for their validity in terms of being translatable to IP addresses.
3. Validation check to ensure that the input is indeed an integer and within the expected range.
4. It is recommended to add log entries whenever a new valid IP or hostname is found or whenever an IP or hostname assignment fails.
5. There should be checks to ensure that the created hostnames do not collide with any existing system hostnames.

