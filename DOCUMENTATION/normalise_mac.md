## `normalise_mac`

Contained in `lib/functions.d/network-functions.sh`

### Function Overview
The function `normalise_mac` normalizes the format of a provided MAC (Media Access Control) address. This is done by removing all common delimiters (periods, hyphens, spaces, colons) and converting all alphabetic characters to lowercase. The function then validates if the MAC address is accurate, meaning it must be exactly 12 hexadecimal characters. If the address is valid, it outputs the normalized MAC address. If not, it sends an error message to stderr and returns 1, signifying an error.

### Technical Description
- **Name**: `normalise_mac`
- **Description**: This function normalizes a MAC address by eliminating delimiters and converting to lowercase, then validates the format.
- **Globals**: None.
- **Arguments**: 
   - `$1: MAC` MAC address to be normalized
- **Outputs**: 
    - Normally, the normalized MAC address.
    - In case of error, an error message to stderr.
- **Returns**: 
    - `0` if successful.
    - `1` if an error occurs (invalid MAC address format).
- **Example usage**: 
```bash
normalise_mac "00:00:00:aa:bb:cc"
```

### Quality and Security Recommendations
1. The function assumes the input is a string, without checking this explicitly. Ensuring this beforehand could prevent errors.
2. Error messages could provide more information to the user about why the format was incorrect (for example, too few/many characters, invalid characters etc.).
3. For further security, consider sanitizing the input to prevent command injection or other potential security risks. 
4. Always use `"${var}"` instead of `"$var"` to avoid word splitting and globbing problems particularly when dealing with variables that can have spaces. This can result in unexpected behavior.
5. It might be handy to have an option to return the normalized format in different styles, i.e., with certain delimiters, or uppercase.

