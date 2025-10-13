### `storage_parse_capacity`

Contained in `lib/host-scripts.d/common.d/storage-management.sh`

Function signature: c67957f8ee4be8442088f8824ef3828b5a9b2d67c4b4f352df2b050bf6c8bbee

### Function overview
The Bash function `storage_parse_capacity()` takes a string argument indicating a data size (with an optional suffix denoting the scale e.g., K, M, G, or T for Kilobytes, Megabytes, Gigabytes, and Terabytes respectively). The function will parse this string and return the data size in bytes. The function will return 1 and terminate if the input does not match the expected format, i.e., a numerical value optionally followed by a suffix (K, M, G, or T).

### Technical description
Definition block for `storage_parse_capacity()` function:

- **name**:  `storage_parse_capacity()`
- **description**:  Parses a string argument depicting a data size with an optional suffix (K, M, G, T) and returns the equivalent size in bytes.
- **globals**:  None
- **arguments**: 
  - `$1`: The capacity string to be parsed. Could be a plain number (considered as bytes), or suffixed with K, M, G, or T (case-insensitive) to denote Kilobytes, Megabytes, Gigabytes, and Terabytes, respectively.
- **outputs**: The function echoes the parsed capacity (data size) in bytes.
- **returns**: 
  - 0: if the processing was successful. 
  - 1: if the input string is empty or does not match the expected format.
- **example usage**: `$ storage_parse_capacity 20K` would output `20480`.

### Quality and security recommendations
1. Add input validation: There should be some additional error handling to make sure the value before the suffix is a valid number. Currently, non-numeric characters before the suffix can lead to unexpected behaviour.
2. Use consistent error: The function should always echo an error message to stderr whenever it returns 1. This would make it easier for users to understand any error that the function encountered during its execution.
3. Create unit tests: To ensure that the function consistently works as expected, create some unit tests that will run the function with different inputs and compare the return values with expected results.

