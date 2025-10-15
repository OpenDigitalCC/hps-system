### `storage_get_host_vlan`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: e63a3a1fba8ac0a209a0abe4bcc73383ffdfe3060c25018bef1faedec9aa1b77

### Function Overview

The function `storage_get_host_vlan()` is a bash function that takes in a MAC address as its argument and attempts to get the corresponding VLAN from the storage of the host. The MAC address is first normalized for correct formatting with the help of the `normalise_mac` function. If the normalization fails, the function returns an error. 

If the normalization is successful, the function checks the host's config for the VLAN corresponding to the normalized MAC address. If it finds a VLAN, it outputs the VLAN and ends successfully. If it does not find a VLAN, it returns an error. 

### Technical Description

- **Name:** `storage_get_host_vlan`
- **Description:** This function gets the VLAN of a host's storage given a MAC address. It normalizes the MAC address and checks the host's config.
- **Globals:** None
- **Arguments:** 
    - `$1`: The mac_address - The MAC address of the host
- **Outputs:** The function will output the VLAN of the host's storage or nothing if it does not retrieve it.
- **Returns:** The function returns `0` on success and `1` on failure.
- **Example usage:** `storage_get_host_vlan "00:0a:95:9d:68:16"`

### Quality and Security Recommendations

1. Validate the input: Ensure that the MAC input provided is a string and also in the right format.
2. Treat Global Variables as Read-Only: Although no globals are used in this function, as a good practice globals should ideally only be read and not written to. This will help avoid side effects.
3. Error Messages: The function could give a more detailed description when it returns `1` - failure. It may be important to know if it was the normalization process that failed or the retrieval of the VLAN from the host's config.
4. Naming Convention: Ensure that MAC address variable names clearly convey whether they are normalized or not (`normalized_mac_address` vs `mac_address`) to prevent confusion.
5. Test edge cases: Check the behavior of the function with invalid inputs, such as null values or special characters may need to be tested. This allows for the function to handle these appropriately.

