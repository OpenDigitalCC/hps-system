### `__guard_source`

Contained in `lib/functions.sh`

Function signature: e8beb9b32cabb9e73dba64f7b102ad5f1112590b455a914144bd65e5d3001168

### Function overview

The function `__guard_source()` is a bash script guard, designed to prevent sourcing a script more than once. This function takes the name of a previously-sourced script and stores it in a guard variable. The function returns '1' if the script has already been sourced (indicating an error and preventing further sourcing) and '0' if not.

### Technical description

- **name:** `__guard_source()`
- **description:** This function is used to avoid multiple sourcing of the same bash script for the prevention of redundant operations, potential recursion and unexpected behavior. It generates a guard variable for the sourced script and checks if the script has been previously executed or sourced, and if so, the function will return 1 preventing the script from re-executing.
- **globals:** [ `_guard_var: Guard variable created for each sourced script to mark its execution. It uses the script name with nonalphanumeric replaced with '_'` ]
- **arguments:** [ `$1: Unused in this function.`, `$2: Also unused in this function.` ]
- **outputs:** No output is returned to stdout/stderr.
- **returns:**  `0 if the script or source has not been run before, and 1 if it has and encoutered an error`
- **example usage:**
```bash
if ! __guard_source; then
    echo "Script already sourced once"
fi
source script.sh
```

### Quality and security recommendations

1. Clear documentation: Each function, global variable and return value should be clearly documented for future developers.
2. Error handling: The function should handle possible errors gracefully and clear, meaningful messages should be returned.
3. Input Validation: Currently, the function does not take any arguments, but for future enhancement if it does, it should validate the input before processing it.
4. Use Strict Mode: To catch errors and undefined variables sooner, consider enabling a 'strict mode' in your scripts with `set -euo pipefail`.

