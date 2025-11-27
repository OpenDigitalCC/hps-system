### `cgi_success`

Contained in `lib/functions.d/cgi-functions.sh`

Function signature: 514b6a0abc4d3054c170946dff0ca831cafb51ed3abc448fdd4f1887a82a8de6

### Function overview

The bash function `cgi_success()` is used to deliver a success message in the context of a CGI (Common Gateway Interface) script. The script calls another function `cgi_header_plain` first, which is likely to format the message header in a specific way. After the header function, it proceeds to echo (or output) a message, without newline, as defined by the first argument `$1`.

### Technical description

- **name**: `cgi_success`
- **description**: A simple bash function that is used within CGI scripts to format and display success messages. It does this by first calling another function `cgi_header_plain` to set the appropriate header, then echoes the input message - without a newline at the end.
- **globals**: None
- **arguments**: 
    - `$1`: The success message to display.
- **outputs**: Message as per the provided argument `$1`, outputted without newline at the end.
- **returns**: Nothing 
- **example usage**:

```bash
cgi_success "File uploaded successfully"
```

### Quality and security recommendations

1. Always sanitize the input to the function, especially if it is coming from an untrusted source.
2. It's recommended to use printf instead of echo, as echo may have different behavior on different systems.
3. Make sure to handle any potential errors that may arise from the internal `cgi_header_plain` function.
4. Consider adding function return checks where this function is used, to handle any execution failures appropriately.
5. Check for any potential sources of shell expansion or code injection within the function argument.

