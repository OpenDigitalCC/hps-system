## `make_timestamp`

Contained in `lib/functions.d/system-functions.sh`

### Function Overview
The Bash function, `make_timestamp`, returns the current date and time in the format Year-Month-Day Hours:Minutes:Seconds UTC. The time is represented in Coordinated Universal Time (UTC), providing a standardized timestamp.

### Technical Description
##### Name:
- `make_timestamp()`
##### Description:
- The function uses the `date` command with the `-u` option, which represents the current date and time in UTC. The format is specified as +`'%Y-%m-%d %H:%M:%S UTC'`, which formats the date as Year-Month-Day and the time as Hours:Minutes:Seconds, followed by the string 'UTC'.
##### Globals:
- Not applicable.
##### Arguments:
- The function does not accept any arguments.
##### Outputs:
- The function outputs the current date and time in UTC, in the format 'YYYY-MM-DD HH:MM:SS UTC'.
##### Returns:
- The function does not return any values, it only has an output.
##### Example Usage:
```bash
echo "$(make_timestamp)"
```
In the console, it may appear as:
```
2022-06-14 12:07:28 UTC
```

### Quality and Security Recommendations
- As the function is quite simple, there isn't much room for quality improvements. However, it is always good practice to comment your code for better readability.
- From a security perspective, the `date` command is safe to use. It does not take user input or access sensitive data. However, if your application has specific security requirements around time handling or time zones, you may need to consider these.
- If you want to use this function in a larger script, you might want to consider error handling, even if the chances of the `date` command failing are exceptionally low.

