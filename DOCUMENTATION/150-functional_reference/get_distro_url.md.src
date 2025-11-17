### `get_distro_url`

Contained in `lib/functions.d/os-function-helpers.sh`

Function signature: d5e5cb266493aa86db394cb7cbb071c14d0e30e84fcc69d8ddf988f413d59f36

### Function overview

The Bash function `get_distro_url` constructs a complete URL to access distribution files on a specific server. It requires an operating system identifier as a parameter and optionally, a server address. If the server address is not provided, it will use a global server address (`SERVER_ADDR`).

### Technical description
* **Name:** `get_distro_url`
* **Description:** Constructs a fully qualified URL for accessing distribution files of a specific OS on a particular server. This function makes use of another function `get_distro_base_path` to get the base path of the distribution files.
* **Globals:** `SERVER_ADDR: The server address to be used if not provided as a function argument.`
* **Arguments:**
  * `$1: The OS ID for which the distribution files URL is required.`
  * `$2: The server address to access the distribution files. If not provided, the global var SERVER_ADDR will be used.`
* **Outputs:** Prints the complete URL to stdout.
* **Returns:** None. In case of an error (like the absence of necessary globals or arguments), the function may not work as expected or may throw an error message.
* **Example usage:**

```bash
# Get the URL with provided server address
get_distro_url "ubuntu" "example.com"

# Get the URL with the global SERVER_ADDR
get_distro_url "debian"
```

### Quality and security recommendations

1. Implement error checking to make sure all required variables and arguments are provided. If not, return an appropriate error message or code.
2. Validate provided arguments, especially if they are user-supplied (to avoid issues like code injection).
3. Ensure the invoked `get_distro_base_path` function is well-tested and secure.
4. Use HTTPS instead of HTTP where possible for improved security.
5. Always quote your variables to prevent word splitting and pathname expansion.

