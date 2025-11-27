### `o_task_list`

Contained in `lib/functions.d/o_opensvc-task-functions.sh`

Function signature: 756a613eff908ff7ef9c499e18525dbd12006b68220d054fed53c6f97867db18

### Function overview

`o_task_list()` is a Bash function designed for service management. It queries the list of services using a local `services` variable. If a specific service name is provided, it checks for the existence of that service and returns an error message if the service does not exist. If no specific service is identified, it queries all existing services. Then, it extracts service details, retrieves a task list for each service, and iterates through each task, printing the task and its corresponding command.

### Technical description

- **Name**: `o_task_list`
- **Description**: This function processes a list of services (or a single specified service), retrieving each service's configuration, extracting service details, and printing a list of tasks for each service.
- **Globals**: None.
- **Arguments**:
  - `$1` (optional): The name of a specific service to be processed. If no name is provided, the function will process all services.
- **Outputs**: Prints a list of tasks for each service.
- **Returns**:
  - Returns `1` if a specified service is not found.
  - Returns `0` when the processing and printing of tasks are successful.
- **Example usage**: `o_task_list "my_service"`

### Quality and security recommendations

1. Add input validation to the `service_name` argument to ensure the function is working with expected data types and formats.
2. Consider restricting the function's permissions to prevent unauthorized access and potential exploitation.
3. Implement error handling to ensure that the function does not continue to execute if there is an error at any point in the process.
4. Use secure methods for handling and storing sensitive data (e.g., service configurations).
5. Use methods that are robust against common critical programming errors to improve the function's reliability and security.

