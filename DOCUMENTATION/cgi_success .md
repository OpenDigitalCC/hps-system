## `cgi_success `

Contained in `lib/functions.d/cgi-functions.sh`

### Function overview

The `cgi_success()` is a bash function used within the scope of a CGI (Common Gateway Interface) based application. This function is intended to produce a plain text response from the web server back to the client. Initially, it calls another function, `cgi_header_plain`, which is used to output the proper HTTP headers to make the response be treated as plain text. Afterward, the function outputs the message passed to it as an argument.

### Technical description

- **Name:** `cgi_success`
- **Description:** This bash function emits plain text response for CGI scripts. It begins by calling `cgi_header_plain` to set necessary HTTP headers for the response to be interpreted as plain text. Following that, it echoes the argument passed to it.
- **Globals:** None.
- **Arguments:** `[ $1: The message or data to be displayed as plain text in the HTTP response ]`
- **Outputs:** The function outputs the HTTP headers necessary for a plain text response as well as the data or message passed as an argument.
- **Returns:** None.
- **Example Usage:**

```bash
cgi_success "Operation completed successfully"
```
This will output the plain text "Operation completed successfully" along with the appropriate HTTP headers dictated by the `cgi_header_plain` function.

### Quality and Security Recommendations 

- Validate and sanitize the input argument to prevent the [Cross-Site Scripting (XSS)](https://owasp.org/www-community/attacks/xss/) vulnerability since we are dealing with an output that is directly rendered on a browser.
- Document the `cgi_header_plain` function that this function calls to better understand what header fields are set, and ensure they are appropriately configured.
- Include error-handling mechanisms to ensure that the function behaves as expected even in the event of errors or exceptions.
- It's good practice to always use double quotes around the variable (`"$1"`) to prevent word splitting and pathname expansion.
- Check if the argument is provided to the function before echoing it. If no argument is provided the function should handle it gracefully.
- Use a more informative function name that better describes the intended action(s).

