## `cluster_has_installed_sch`

Contained in `lib/functions.d/cluster-functions.sh`

### Function overview

The Bash function `cluster_has_installed_sch()` checks whether a cluster has an installed "SCH" type. The function reads through cluster configuration files with `.conf` extension in a given directory and checks each of them if it has a line corresponding to type "SCH" and state "INSTALLED". If there is indeed an installed "SCH" type, it returns 0 (true - SCH is installed), otherwise, it returns 1 (false - SCH is not installed).

### Technical description

- **name**: `cluster_has_installed_sch`
- **description**: This function loops through each .conf file in a given directory. Each configuration file is scanned for the type "SCH" and state "INSTALLED". If a configuration with this specific type and state is found, the function returns 0, otherwise, it returns 1.
- **globals**: [ `HPS_HOST_CONFIG_DIR`: The directory where the configuration files (.conf extension) are stored ]
- **arguments**: none
- **outputs**: No explicit output is produced, but the function changes the exit status to indicate the presence of an installed "SCH" type.
- **returns**: Returns 0 if an installed "SCH" type is found, 1 if not.
- **example usage**: 

```bash
if cluster_has_installed_sch; then
  echo "SCH type is installed"
else
  echo "SCH type is not installed"
fi
```

### Quality and security recommendations

1. Make sure to set the global variable `HPS_HOST_CONFIG_DIR` prior to calling the function, otherwise it won't find the files to process.
2. For better security, use absolute paths when setting `HPS_HOST_CONFIG_DIR` to avoid reliance on relative paths which could be exploited.
3. Validate the content of the configuration files to avoid injections. 
4. In case of read failures or other I/O problems, those should be handled graciously.
5. Adding comments to the code would improve its maintainability by making it easier for others to understand.
6. Consider adding more error checks e.g., if directory or files do not exist.

