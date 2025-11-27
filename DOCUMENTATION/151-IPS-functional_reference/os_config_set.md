### `os_config_set`

Contained in `lib/functions.d/os-functions.sh`

Function signature: c4746ca6605cff53d6621b31b6cd996758390233161c17381459ddfcdb47c0a5

### Function Overview
The `os_config_set` function is a shell function developed for bash scripts that deal with configuration files on a Unix-like operating system. It takes in three arguments: `os_id`, `key`, and `value`. It checks a specified configuration file for a particular section (defined by `os_id`), then updates it (or creates it) with a specified `key`-`value` pair. If the configuration file is empty or if the specified section does not exist, the function creates a new section.

### Technical Description
* **name:** `os_config_set`
* **description:** This function updates or creates a section in a configuration file with the given `os_id` as the section name. Inside this section, it either updates an existing `key` with a new `value` or adds the new `key`-`value` pair if the `key` does not exist.
* **globals:** None
* **arguments:** `$1`(`os_id`): The identifier of the OS configuration section, `$2`(`key`): The configuration key to set, `$3`(`value`): The value to set for the key.
* **outputs:** Rewrites a configuration file by updating or adding a new `key`-`value` pair in a specified section.
* **returns:** It will always return `0` indicating successful execution.
* **example usage:**

```bash
os_config_set "ubuntu18" "hostname" "my-new-host"
```

### Quality and Security Recommendations
1. To avoid errors or unexpected behavior, check if the `os_id`, `key`, and `value` variables are not empty before proceeding with the rest of the function.
2. Instead of directly writing to the configuration file, consider creating a backup of the original file and then apply changes to the backup. This way, if something goes wrong during the operation, the user can revert to the original configuration.
3. It may be beneficial to include error messages or logs when a section does not exist in the configuration file, or when the desired key to be updated is not found.
4. Check all output of external commands using `$?` to make sure the command was successful. For instance, check the output of the `mv` command used towards the end of the function.

