### `rocky_latest_version`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: f42e139a07133ae36c4e9783c1fbb144e1167e59537bd374c0b346f853c77a3d

### Function overview

The `rocky_latest_version` function is used to fetch the latest version number of the Rocky Linux distribution. It retrieves the listing of the Rocky Linux distribution repository using `curl`, filters, sorts, and echoes out the version number of the latest release.

### Technical description

- **name**: `rocky_latest_version`
- **description**: This function retrieves the HTML of the Rocky Linux distribution repository, filters out the version numbers using regular expressions, sorts them in reverse order, and echoes out the latest release version.
- **globals**: 
  - `base_url`: the URL of the Rocky Linux distribution repository
  - `html`: stores the html data fetched from the `base_url`
  - `versions`: array holding the version numbers sorted in reverse order (`-Vr` option for "version sort")
- **arguments**: None
- **outputs**: The latest Rocky Linux version number.
- **returns**: 
  - `1` if either fetching the HTML fails, or no version numbers could be extracted from the HTML 
  - otherwise, does not explicitly return anything
- **example usage**: 
```bash
latest_version=$(rocky_latest_version)
echo "The latest Rocky Linux version is ${latest_version}"
```

### Quality and security recommendations

1. Since this function heavily relies on the format of the HTML file, it may become brittle with changes to the website structure. It would be more reliable to use an official API, if available.
2. Error handling can be improved. Currently, the function returns `1` in case of either connection failure or when no versions are found in the HTML. Considering these two situations could be differentiated for better troubleshooting.
3. For security reasons, consider validating the HTML content before processing, as maliciously-crafted content might lead to unexpected behavior.
4. Add comments to give context to the regular expression used in the `grep` command. This will improve maintainability for developers not familiar with this pattern.

