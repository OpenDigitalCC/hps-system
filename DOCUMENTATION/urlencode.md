## `urlencode`

Contained in `lib/functions.d/cgi-functions.sh`

### Function overview
The `urlencode` function is used for encoding a URL by converting all non-alphanumeric characters to percent-encoded format. It substitutes a two-digit hexadecimal code, preceded by a percent sign (%), for each disallowed character in the input string. 

### Technical description
- **Name:** `urlencode`
- **Description:** This function accepts a string as input and generates a URL-encoded version of the string. This is achieved by iterating over each character in the string & testing whether it's alphanumeric or not. Alphanumeric characters are left untouched, while all other characters are converted into hexadecimal format preceded by a '%' sign.
- **Globals:** None.
- **Arguments:** 
    - `$1`: This is the string that has to be URL encoded.
- **Outputs:** The function outputs the URL-encoded string.
- **Returns:** The `urlencode` function doesn't have a return value. It directly outputs the encoded string .
- **Example usage:**
  ```bash
  url="Hello World"
  urlencode "$url"
  ```

### Quality and security recommendations
1. Consider handling edge cases where the input string is empty or contains only spaces.
2. Perform input validation to ensure the input is a string.
3. Although this function may not be vulnerable to significant security risks, always use best practices when dealing with URLs to prevent other types of potential security issues like SQL injections and Cross Site Scripting (XSS).
4. Incorporate error handling to deal with unexpected failures during execution. This can make the function more robust and easier to debug.
5. Add comments to the code to ease understanding and maintenance.
6. Write unit tests for the function to ensure it works correctly with different types of inputs.

