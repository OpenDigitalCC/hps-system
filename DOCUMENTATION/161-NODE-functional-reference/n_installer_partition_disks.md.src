### `n_installer_partition_disks`

Contained in `node-manager/alpine-3/+INSTALLING/installer-functions.sh`

Function signature: 481842e1c9ac4d126f0266c400ecbb23ec6be762d9b3a2c2d704968f0eb99955

### Function overview

The `n_installer_partition_disks()` function is responsible for automating the disk partitioning process on a host machine. It takes a list of disks from the host configuration and partitions them in different modes based on the number of disks (Single disk mode for one disk, RAID1 mode for two disks). The function also checks and installs required tools if they aren't already installed and handles special naming convention for NVMe disks.

### Technical description

- **name**: `n_installer_partition_disks`
- **description**: This function automates the disk partitioning process based on the configuration on host machine.
- **globals**: [ `IFS`: Internal field separator used for splitting a string into array, `os_disk`: A variable fetched from the host configuration containing the disk(s) to be partitioned]
- **arguments**: No arguments required.
- **outputs**: Log messages indicating the steps and proceedings or any errors encountered.
- **returns**: `1` if errors like failed to read `os_disk` from host config or empty `os_disk` or invalid disk count; `2` if fails to install required tools or partitioning failed.
- **example usage**: `n_installer_partition_disks`

### Quality and security recommendations

1. Error message should not disclose too much information about what went wrong for security concerns. 
2. The function can be made more secure by performing greater validation of the `os_disk` value before attempting disk operations.
3. Consider handling cases where disk count is more than 2.
4. For enhancing this function's maintainability, modularization can be done by breaking down larger chunks of code into smaller functions.
5. It is recommended to have a way to roll back changes if any step in the function fails.
6. Consider handling the failure conditions (like failing to install required tools or partitioning) more robustly, possibly with retries or alternatives.

