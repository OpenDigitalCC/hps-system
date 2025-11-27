### `osvc_bootstrap_cluster_on_ips`

Contained in `lib/functions.d/opensvc-functions.sh`

Function signature: 5c6e0561effddf61773afa3a92bd63b874a69bc5288818a661a33cb6934cf68e

### Function overview

This function, `osvc_bootstrap_cluster_on_ips()`, is a crucial part of setting up a Clustering Infrastructure using OpenSVC. The procedure involves bootstrapping a cluster on IPs, configuring necessary parameters such as Cluster Name and Node Name, enforcing certain configurations, starting a daemon, and setting up a heartbeat for the operation. An essential part of this function includes getting or generating a cluster secret.

### Technical description

* _Name_: `osvc_bootstrap_cluster_on_ips()`
* _Description_: The function's main role is in the bootstrapping process of a cluster on IPS using OpenSVC. It has several operations with checks and logging at each step to ensure smooth operation and reporting any possible failures.
* _Globals_: [ `ips_role`: stores the OSVC_IPS_ROLE, `cluster_name`: stores the name of the cluster, `hb_type`: takes the type of heartbeat, `cluster_secret`: holds the cluster secret]
* _Arguments_: This function does not take any arguments.
* _Outputs_: The function outputs several log messages, consisting of information, error and status details about the state of bootstrapping, possible failures, and the final status of the process.
* _Returns_: The function returns 0 on successful bootstrapping, 1 if any configuration fails, and 2 if the daemon fails to start or is not responsive.
* _Example usage_: The function is intended to be called without any arguments in the form of `osvc_bootstrap_cluster_on_ips`.

### Quality and security recommendations

1. Input Validation: As is common with bash functions, an implicit assumption is that any provided environment variables or globals are already set and valid. To improve this, consider validating these variables inside the function or explicitly handle the case when these globals are not provided.
2. Error Handling: The function does good job logging errors in most cases. Still, it might be beneficial to have more granular error handling, especially when dealing with sensitive information like the cluster secret.
3. Security Recommendations: As the function is dealing with sensitive data (like the cluster secret), it becomes critical to safeguard this information. Always ensure that such data is securely stored and used only over safe connections/protocols.

