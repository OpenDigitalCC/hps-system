#### `normalise_mac`

Contained in `lib/functions.d/network-functions.sh`

Function signature: ac8cefca0a4fe56f9e4ef01e54a13bb17bd1107670d5f1b98c4c04d07fd2425e

##### Function Overview

The function `normalise_mac()` is utilized to sanitize and validate a given MAC address input to be certain it adheres to the standard format of a 12-character hexadecimal string. It initially removes all common delimiters, such as colons, hyphens, periods, and spaces, converts the string to lowercase, and validates that the sanitised input is exactly a 12-digit hexadecimal string. If the input fails to meet these criteria, the function echoes an error message and returns 1 (indicating failure of the function). If the input is validated, the function echoes the sanitized and validated MAC address.

##### Technical Description

- **name**: normalise_mac
- **description**: This bash function sanitizes and validates a given MAC address to ensure it adheres to the 12-character hexadecimal string format.
- **globals**: None
- **arguments**:
  - $1: Input String - This is the MAC address being sanitized and validated.
- **outputs**: The sanitized and validated MAC address if input is valid, otherwise an error message indicating an invalid MAC address format.
- **returns**:
  1. If the MAC address input is invalid
  0. If the MAC address input is valid
- **example usage**: `normalise_mac "78-30-15-AB-90-67"`

##### Quality and Security Recommendations

1. Code Comments: For better readability and maintainability, each block of code could be introduced with a descriptive comment explaining its purpose.

2. Input Validation: The input is sufficiently validated, but more comprehensive validation could be implemented to strengthen error handling, for instance checking for null or empty strings.

3. Test Cases: Incorporate test cases to verify that the function correctly sanitizes, validates and handles various types of MAC addresses inputs.

4. Error Handling: Considering more advanced error handling mechanisms such as a try/catch block could additionally be beneficial for troubleshooting and debugging. 

5. Exit Codes: Using standardized exit codes could help make the function more universal and better interact with other scripts or applications.

