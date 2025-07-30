## `rocky_latest_version`

Contained in `lib/functions.d/iso-functions.sh`

### Function overview
This bash function, `rocky_latest_version`, fetches the page content from the Rocky Linux download page and parses it to find the latest version number of Rocky Linux available for download. The function leverages `curl`, `grep`, `sed`, and `sort` tools to fetch and parse HTML content, and extract version numbers from it. If successful, it prints the most recent version number to the standard output.

### Technical description
**Function: `rocky_latest_version`**
- **Name**: rocky_latest_version
- **Description**: This function fetches and prints the latest version number of Rocky Linux available for download from the official website.
- **Globals**: None
- **Arguments**: None
- **Outputs**: The most recent version number of Rocky Linux, or nothing in case of an error.
- **Returns**: 0 if a version number was found and echoed, 1 if the download failed or no version number could be fetched.
- **Example usage**:
```bash
latest_version=$(rocky_latest_version)
echo "The latest version of Rocky Linux is $latest_version"
```
  
### Quality and security recommendations
1. **Error handling and reporting**: Currently, when an error happens (e.g., download fails), the function just returns 1 without any explanation. A more user-friendly approach would be to also print a meaningful error message to the standard error.
2. **Be more specific with `grep` usage**: The function uses a rather broad regular expression to match version numbers. If the page structure changes in the future, it might return wrong results. Instead, consider using a more specific pattern or a different method to get the version number.
3. **Check for `curl` installation**: The function doesn't check if `curl` is installed on the system.
4. **Secure protocol**: The URL is hardcoded with a secure protocol "https". This is good as it ensures secure transmission.
5. **Use of piping and subprocesses**: The function uses multiple pipes and subprocesses. While this is generally acceptable in a bash script, it might negatively impact the performance and also lead to unexpected results if not done carefully.

