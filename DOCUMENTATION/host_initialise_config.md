## `host_initialise_config`

Contained in `lib/functions.d/host-functions.sh`

### Function overview

The function `host_initialise_config` is primarily used for setting up the host configuration. This function takes a local MAC address as an argument, generates a configuration file name using that MAC address and the host configuration directory `${HPS_HOST_CONFIG_DIR}`. It then creates the mentioned directory, sets the state to "UNCONFIGURED", and logs the completion of the host config initialization process.

### Technical description

- **Name:** `host_initialise_config`
- **Description:** This function is used to initialize the host configuration. The function creates the host configuration directory if it does not exist and sets the configuration's state to "UNCONFIGURED".
- **Globals:** [ `${HPS_HOST_CONFIG_DIR}`: The directory for storing host configurations ]
- **Arguments:** [ `$1`: Local mac address to initialize host configuration, not optional ]
- **Outputs:** Does not output any variables, but logs the completion of the initialization with the message "Initialised host config: (config_file)"
- **Returns:** No return information
- **Example usage:** 
  ```
  host_initialise_config "C0:FF:EE:C0:FF:EE"
  ```
  
### Quality and security recommendations
1. Always ensure that the MAC address argument is valid or sanitized before passing it to the function as it may lead to unhandled exceptions.
2. Add error checking logic and include exception handling for actions like non-existent directories or inaccessible file paths. 
3. Ensure that the use of `hps_log` is secure and does not expose sensitive logs in insecure locations.
4. Uncomment the pieces of code related to the creation timestamp and refine in a way that doesn't cause an error. This will enhance traceability and aid in debug processes.
5. Explore mechanisms to return status or error codes to make the function more robust and usable in the script. The function currently does not return any value.
6. Consider encrypting sensitive data in the configuration file to enhance security.

