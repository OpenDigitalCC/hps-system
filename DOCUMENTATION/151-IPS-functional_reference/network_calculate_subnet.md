### `network_calculate_subnet`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 28bad9be5b146b636db38a5bc9383098acfa045e1d0212500adddc909c91161d

### Function Overview

The `network_calculate_subnet` function in Bash is used for subnet calculation. It takes three arguments, namely a base IP, index, and CIDR notation, and then calculates the subnet. First, the function validates the inputs. If all inputs are valid, it extracts the first two parts (octets) of the base IP. The CIDR notation specifies how the remaining subnets should be calculated. The function also contains comment logs for visibility in case of unsupported CIDR notations.

### Technical Description

- **Name:** `network_calculate_subnet`
- **Description:** Calculates the subnet based on given base IP, index, and CIDR.
- **Globals:** None
- **Arguments:** 
    - `$1: base`: Base IP from which the subnetworks are calculated.
    - `$2: index`: Index used for calculations.
    - `$3: cidr`: CIDR (Classless Inter-Domain Routing) notation that specifies subnet's size.
- **Outputs:** Logs the calculated subnet or logs an error if CIDR is unsupported.
- **Returns:** `0` on successful calculation, `1` on error or if inputs are invalid.
- **Example usage:** 
```bash
network_calculate_subnet 192.168.1 5 24
```

### Quality and Security Recommendations

1. Using very specific subnets (like /25, /26, etc.) might lead to tabulation issues. Hence, it is recommended to use specific subnets only when necessary.
2. The function expects very specific inputs. Thus, it is advisable to add proper error messages conveying the required input in the case of a wrong input format.
3. The function can be modified to use arrays instead of three separate inputs for easier manipulation.
4. Make sure that the function is always used with proper sanitization of inputs to prevent possible injection attacks.

