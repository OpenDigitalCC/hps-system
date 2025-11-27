### `download_iso`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 8809a8fec0ae6a5ffcfad851cf4f532fecb9538381ebc77a93c97b6f36151885

### Function overview

The `download_iso` function is designed to download ISO files based on specific parameters given as inputs. The parameters include central processing unit (CPU) type, manufacturer (MFR), operating system name (OS name), and operating system version (OS version). The function utilizes a helper function to get the directory path where the ISO will be saved. The function downloads the ISO file from the appropriate URL based on the parameters and saves it to the constructed path. If the ISO file is present, the function will not download it. The function handles exceptions such as failure in downloading, unsupported OS variant, etc., and it further communicates its success or failure through echo statements.

### Technical description

- **Name:** download_iso
- **Description:** Downloads specified ISO image file from the internet, using curl, and saves it in mentioned directory.
- **Globals:** None
- **Arguments:** 
  - $1: Central processing unit type.
  - $2: Manufacturer.
  - $3: Operating system name.
  - $4: Operating system version.
- **Outputs:** Echoes status of the operations performed and download link if successful.
- **Returns:** Status code of the command in case of failure or success in downloading ISO file. 
- **Example usage:**

```bash
download_iso "x86_64" "Intel" "rockylinux" "10.0"
```

### Quality and security recommendations

1. For better error handling, consider defining custom error messages, so that users can understand what type of error occurred instead of a simple failure message.
2. It would be a good idea to also clean up the partial downloads from failed curl attempts.
3. Always validate the inputs. For the current function, check if all the required arguments are provided and properly formatted.
4. You might consider catching more specific errors e.g, network errors, to give more detailed feedback to the user.
5. It's a good practice to ensure that the directory where the ISO is being saved has proper permissions to avoid any potential security risks.
6. Revealing the URLs or paths of the ISO files being downloaded in echo messages could be a security risk. Consider anonymizing or masking these details.

