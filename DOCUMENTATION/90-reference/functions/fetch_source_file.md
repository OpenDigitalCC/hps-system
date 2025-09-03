### `fetch_source_file`

Contained in `lib/functions.d/prepare-external-deps.sh`

Function signature: 9851dec43ce9f3e94856800874741f8ff28deda9346709daaa88282763e49999

### Function overview

The `fetch_source_file` function is a utility to download a file from a given URL and save it on a specified destination directory. It first checks if the file already exists in the destination directory. If the file does not exist, it downloads the file using `curl` command. If the `filename` argument is not provided, it infers the filename from the URL. The default directory to save the file is `/srv/hps-resources/packages/src`, nevertheless, it can be overwritten through `HPS_PACKAGES_DIR` environment variable.

### Technical description

- **Name**: `fetch_source_file`
- **Description**: Fetches a file from a provided URL and saves it in a specific location.
- **Globals**: [ `HPS_PACKAGES_DIR`: Specifies the root directory for saving the downloaded files]
- **Arguments**: [ `$1`: URL of the file to be downloaded, `$2`: Name of the downloaded file]
- **Outputs**: Logs to stdout showing the progress and result of the download.
- **Returns**: `0` if the file is successfully downloaded or already exists on the server, `1` if the download fails.
- **Example usage**:
  ```bash
  fetch_source_file "https://example.com/file.zip" "myFile.zip"
  ```

### Quality and security recommendations

1. Input validation: As the function downloads content from a URL, it is advisable to add checks for ensuring that the URL is properly formatted and secure (uses `https://`, belongs to trusted domain etc).
2. Error handling: While the function checks if the file is successfully downloaded, it would be better to add error handling for other operations as well like creating directory.
3. Sanity checks: It would be safer to add some sanity checks on the downloaded file, like checking its size, verifying its checksum and more.
4. Avoid using global variables: The use of global variables makes code hard to predict and debug, it is better to pass them as parameters to the functions.
5. Logging: consider redirecting error logs to stderr consistently. In the current case, some logs are written to stdout, some - to stderr, which might be cumbersome to debug if the function is used in a script.

