## `list_local_iso`

Contained in `lib/functions.d/iso-functions.sh`

### Function overview

The bash function `list_local_iso()` is designed to search for local ISO files in a specified directory based on the provided parameters (cpu, manufacturer, operating system name and its version). If the optional `osver` argument is supplied, then it is included in the search pattern. The function lists all the found ISO files with corresponding names. If no matches are found, the function returns an echo statement indicating that no matching ISO files were found.

### Technical description

 - **name**: list_local_iso
 - **description**: Searches for ISO files in the ISO directory specified by the `get_iso_path` function, based on the `cpu`, `mfr`, `osname` and `osver` parameters. If the `osver` parameter is not supplied, then it is left out of the search pattern.
 - **globals**:  N/A
 - **arguments**:  [$1: cpu, $2: mfr, $3: osname, $4 (optional): osver]
 - **outputs**: A list of found ISO files or a message indicating that no ISO files were found.
 - **returns**: 1, if no ISO files were found.
 - **example usage**: 

```bash
list_local_iso 'x86' 'intel' 'ubuntu' '18.04'
```

### Quality and security recommendations

1. Validate the input parameters.
2. Add error handlers for potential issues - for example, what happens if the directory specified by `get_iso_path` does not exist.
3. Make sure that `get_iso_path` provides a correct path to prevent potential path traversal attacks.
4. Output all echo messages not only to the standard output but also to a dedicated log file with timestamps for better tracking.
5. Make sure the function works as expected with special characters in the `cpu`, `mfr`, `osname`, and `osver` parameters.
6. Implement an exit mechanism to break the loop if it runs for a certain amount of time to avoid potential infinite looping.

