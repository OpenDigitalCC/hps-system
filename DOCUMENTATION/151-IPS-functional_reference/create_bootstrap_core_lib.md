### `create_bootstrap_core_lib`

Contained in `lib/functions.d/node-bootstrap-functions.sh`

Function signature: 185ab2e8ed8b7b25b303b8cc7a660c5fe4fc99cf828a17426f8d22cd6d330dba

### Function overview
The `create_bootstrap_core_lib` function is used to relay IPS core functions. The function specifically prints out a heading "HPS Bootstrap library", then it relays a number of HPS functions such as `hps_check_bash_syntax`, `hps_debug_function_load`, `hps_safe_eval`, and `hps_source_with_debug`. After the relay is completed, it echoes "Relay complete" and then begins to write the core functions for HPS node bootstrap and initialization including a URL encoding function. 

### Technical description
- **Name:** `create_bootstrap_core_lib`
- **Description:** This function is used to relay IPS core functions, specifically starts by printing out a heading "HPS Bootstrap Library", then relaying a couple of HPS functions and ends by echoing "Relay complete" and beginning to write the core functions for HPS node bootstrap and initialization which includes a URL encoding function.
- **Globals:** No global variables used.
- **Arguments:** The function does not take any arguments.
- **Outputs:** The function spits out some text to stdout including the relaying of HPS functions, 'Relay complete', and starting to write the core functions for HPS node bootstrap and initialization.
- **Returns:** The function doesn't return any value.
- **Example usage:** `create_bootstrap_core_lib`

### Quality and security recommendations
1. Incorporate error handling to identify and resolve any potential issues that may occur when declaring and relaying functions.
2. Write unit tests for the function to ensure it’s working as expected at all times.
3. Document the purpose and usage of each relayed function. This will improve the maintainability of the code.
4. Avoid using hard-coded strings. Try to make the function more flexible and not tied to the specific HPS functions.
5. Ensure all the relayed functions are also following security best practices.

