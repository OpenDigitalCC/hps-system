### `reload_supervisor_services`

Contained in `lib/functions.d/supervisor-functions.sh`

Function signature: ee7474337de25fd0047a1b12f045d3808374c06aa3f7becbd66592a7cb0a8384

### Function overview

This function, `reload_supervisor_services`, reloads services managed by Supervisor. It verifies the existence of the Supervisor configuration file and sends a HUP (hangup) signal to either a specific service (`service_name`) or all existing Supervisor services, logging the output of the operation. The command uses the `-c` option to specify the Supervisor configuration file and the `signal HUP` command to send the hangup signal, allowing for the configuration to be re-read without the need for a full Supervisor restart.

### Technical description

Definition Summary:
- **Name:** `reload_supervisor_services`
- **Description:** A function that reloads services managed by Supervisor by sending a HUP signal to the service(s)
- **Globals:** [`SUPERVISORD_CONF`: Supervisor configuration file path]
- **Arguments:** [`$1`: Optional argument for specifying the service to reload. If not provided, the signal will be sent to all the services]
- **Outputs:** Logs error and info messages depending on the operation status.
- **Returns:** 
  - `0` if the HUP signal was sent successfully,
  - `1` if the Supervisor configuration file was not found or not set,
  - `2` if the HUP signal failed to be sent.
- **Example Usage:** `reload_supervisor_services 'service_name'`

### Quality and security recommendations

1. Ensure that the Supervisor configuration file is secure and can only be edited by authorized users.
2. Restrict the services that can be targeted by this function to prevent malicious actors from forcing unnecessary configuration reloads.
3. Make sure that functions for getting paths and logging (`get_path_supervisord_conf`, `hps_log`) properly handle edge cases and unexpected inputs.
4. Consider adding more error handling for cases where Supervisor may not be running, or the targeted service does not exist.
5. Always use the latest version of Supervisor and peer review any updates to this script.

