## `host_config_delete`

Contained in `lib/functions.d/host-functions.sh`

### Function overview
The function `host_config_delete()` is used to delete a specific configuration file of a host determined by its MAC address. It first checks if the configuration file exists. If it does, it deletes the file and logs an informational message. If the file doesn't exist, it logs a warning message.

### Technical description

- **Name:** `host_config_delete()`
- **Description:** The function deletes a host configuration file based on the provided MAC address.
- **Globals:** [ HPS_HOST_CONFIG_DIR: This global is used to specify the directory of the host configuration files. ]
- **Arguments:** [ $1: mac, This argument specifies the MAC address of the host for which the configuration file needs to be deleted.
  $2: config_file, This argument specifies the configuration file to be deleted based on the MAC address. ]
- **Outputs:** An informational message stating the host configuration file was deleted or a warning message if the configuration file is not found.
- **Returns:** Returns 0 if the configuration file is deleted successfully, or 1 if the configuration file doesn’t exist.
- **Example usage:** `host_config_delete "12:34:56:78:9a:bc"`

### Quality and security recommendations

1. Ensure that the `HPS_HOST_CONFIG_DIR` global is properly initialized and secured against unauthorized access.
2. Validate the `mac` parameter to prevent any sort of code injection.
3. Use a safer method to remove files other than `rm -f` to avoid accidental deletion of critical files.
4. Implement more robust error handling for cases where the file deletion fails for reasons other than non-existence.
5. Log both successful deletions and unsuccessful attempts with detailed messages in a dedicated and secure log system.

