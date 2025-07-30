## `get_device_model`

Contained in `lib/functions.d/storage_functions.sh`

### Function overview
The `get_device_model` function fetches and returns the model of the device specified. This function is useful for retrieving the model name for any block device in a Linux environment, and this information can be used for various purposes like device identification, logging or any other device-specific logic. As a fallback, it will return the string "unknown" when the model name cannot be obtained.

### Technical description
- **Name:** `get_device_model`
- **Description:** This function fetches the model of a device specified by the user and returns it. If the model name cannot be obtained, it returns the string "unknown".
- **Globals:** None
- **Arguments:** 
  - `$1`: The block device for which the model name is to be fetched.
- **Outputs:** Prints model name of device or "unknown" if not fetch-able.
- **Returns:** Nothing
- **Example Usage:** 
  - Command: `get_device_model /dev/sda`
  - Response: `ST1000DM003-1CH162` or `unknown`

### Quality and security recommendations
- Always validate the argument passed to the function. It is a good practice to make sure the required number of arguments are provided, and they are of expected type or format.
- A more explicit error message could be returned instead of "unknown" to provide more information to the end-user in cases where the model name cannot be fetched.
- Redirecting errors to /dev/null can hide potential issues. It would be better to handle errors and give proper messages whenever something goes wrong.
- Always remember to quote your variables in bash to prevent word splitting and pathname expansion.
- Consider limiting the permissions of the file the function is defined in and mark it as readonly, to prevent unauthorized modifications.

