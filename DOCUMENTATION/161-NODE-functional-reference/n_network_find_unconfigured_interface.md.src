### `n_network_find_unconfigured_interface`

Contained in `lib/node-functions.d/common.d/n_network-functions.sh`

Function signature: 4b8cced8949437d8332391a0d4ab87a48036672dee0cfc1e783b64bae29baacd

### Function overview

The `n_network_find_unconfigured_interface` is a Bash function that searches all available interfaces and identifies an "unconfigured" one. This selection is based on two primary criteria: the number of assigned IP addresses (the fewer the better) and the connection speed (the faster the better). The function counts the assigned IP addresses for each interface, and if an interface is found with no IP addresses and a decent speed, it is immediately chosen. If not, all interfaces are scrutinized, and the one with fewest IP addresses and highest speed is chosen. 

### Technical description

- Name: `n_network_find_unconfigured_interface`
- Description: A Bash function to find an unconfigured network interface based on the number of their assigned IPs and their connection speed
- Globals: N/A
- Arguments: N/A
- Outputs: Outputs the name of the selected unconfigured interface. If no suitable interface can be found, no output is printed.
- Returns: Returns 0 if an interface is found, otherwise no return value.
- Example Usage:

```bash
$ n_network_find_unconfigured_interface 
```

### Quality and security recommendations

1. Add error handling: The function doesn’t currently handle any exceptions, thus, adding error handling for unforeseen situations could enhance its reliability.
2. Check input validation: Even though this function doesn't accept any arguments, it might be beneficial to check the validity of the information retrieved from interfaces.
3. Avoid command injection: Make sure that the values assigned to the variables within function are not user-supplied inputs to prevent command injection attacks.
4. Limit permissions: Run the function with the least privileges required to reduce the impact of potential security vulnerabilities.
5. Logging: Consider adding logging functionality to help with debugging and monitoring.
6. Code comments: Improve the comments for code readability and maintainability.
7. Testing: The function should be extensively tested to ensure that it works as expected in different environments and edge cases.

