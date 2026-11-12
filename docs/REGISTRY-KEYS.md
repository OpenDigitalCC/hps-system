# Registry keys

Generated from `lib/perl/HPS/Registry/Keys.pm` by `bin/hps-registry-keys --markdown`; do not edit by hand.
A name in angle brackets is a pattern: `<n>` stands for a number, `<name>` for a workload name.

## Types

| Type | A value of this type is |
|---|---|
| `bool` | true or false (JSON booleans or the strings true/false), or 1/0 |
| `epoch` | Unix time in whole seconds, digits only (e.g. 1794321826) |
| `iso8601` | ISO 8601 date-time with offset (date -Iseconds) |
| `stamp` | UTC date-time text, "YYYY-MM-DD HH:MM:SS UTC" |
| `string` | free text; the meaning column lists the values where they are a fixed set |
| `json` | a JSON object or array |
| `pin` | a NixOS system pin: a store path or name chosen by hps-onboard, never empty |
| `mac` | a MAC address, 12 lower-case hex digits |
| `int` | a whole number |
| `ip` | an IPv4 address |
| `cidr` | IPv4 address or network with prefix length, a.b.c.d/n |

## System keys

| Key | Type | Written by | Meaning |
|---|---|---|---|
| `ACTIVE_CLUSTER` | `string` | set_active_cluster (cluster-bootstrap, cluster-configure) | Name of the cluster every host and cluster command acts on. |

## Host keys

| Key | Type | Written by | Meaning |
|---|---|---|---|
| `STATE` | `string` | boot_manager, ipxe menu, host initialisation, hps-onboard | Provisioning state: UNCONFIGURED, CONFIGURED, INSTALLING, NETWORK_BOOT, REINSTALL, UNMANAGED, HELD. |
| `UPDATED` | `stamp` | every host write (host_registry, HPS::Registry::host_set) | When any key of this host last changed. |
| `TYPE` | `string` | host initialisation, ipxe menu, hps-onboard | Node type (for example TCH, SCH, NIXOS). |
| `HOST_PROFILE` | `string` | ipxe menu, hps-onboard | Profile chosen for the node. |
| `PROFILE` | `string` | hps-onboard | Same profile name as HOST_PROFILE, written alongside it. |
| `os_id` | `string` | ipxe menu, hps-onboard | Operating system id arch:name:version the node boots. |
| `FORCE_INSTALL` | `string` | ipxe menu | YES or NO: reinstall at next boot. Upper-case words, not a bool. |
| `HOSTNAME` | `string` | host initialisation | Host name allocated to the node. |
| `IP` | `ip` | host initialisation | Address allocated to the node. |
| `NETMASK` | `ip` | host initialisation | Netmask allocated to the node. |
| `arch` | `string` | host initialisation | CPU architecture the node reported at first boot. |
| `initialised_at` | `iso8601` | host initialisation | When the host registry entry was created. |
| `assigned_at` | `stamp` | hps-onboard | When the node was assigned its profile and pin. |
| `last_boot_at` | `epoch` | ipxe menu | When the node was last issued a boot script (ADR 0002 check 3). |
| `ctrl_exec_paired_at` | `epoch` | ce_approve_pair_request (ctrl-exec pairing approver) | When the node paired with ctrl-exec. Present means paired; removed when the pairing window is reopened for a boot. |
| `ctrl_exec_paired` | `epoch` | ce_approve_pair_request | Deprecated, replaced by `ctrl_exec_paired_at`. Compatibility copy of ctrl_exec_paired_at (same epoch value; the name reads as a boolean, it is not one). Kept one release; read ctrl_exec_paired_at. |
| `system_pin` | `pin` | hps-onboard (assign, repin) | The NixOS system the node boots. |
| `system_pin_previous` | `pin` | hps-onboard repin | The pin before the last repin, for rollback. |
| `repinned_at` | `stamp` | hps-onboard repin | When the pin last changed. |
| `nets` | `json` | hps-onboard, HPS::Workload | Array of network names the node attaches to. |
| `audit` | `json` | node_audit CGI (host_audit_store) | The hps-audit/1 document the node uploaded. |
| `init_result` | `json` | host_init_intake (boot_manager cmd=host_init_result) | The node's last init sequence: boot_id, pin, times, steps with rc, seconds and message (IPS-02). |
| `init_result_prev` | `json` | host_init_intake | The init result of the boot before the last one. |
| `init_ok` | `bool` | host_init_intake | True when every step of the last init sequence exited 0. |
| `bmc_driver` | `string` | HPS::BMC (hps-bmc select from the audit, hps-bmc set) | Name of the out-of-band power driver under lib/bmc/drivers: hpe-ilo, dell-idrac, redfish-generic, ipmi, external or manual. |
| `bmc_driver_source` | `string` | HPS::BMC | audit (chosen from the audit by lib/bmc/drivers.map) or operator (set by hps-bmc set; an audit never replaces it). |
| `bmc_addr` | `string` | HPS::BMC (audit selection: the address ipmitool lan print reported; hps-bmc set --addr) | Address of the BMC; unset when the audit found none. |
| `bmc_options` | `json` | HPS::BMC (hps-bmc set --option) | Object of driver options, for example {"outlet":"pdu1:7"} for the external driver; passed to the driver as BMC_OPT_<name>. |
| `bmc_evidence` | `json` | HPS::BMC (audit selection) | The BMC facts the driver was chosen from: vendor, product, mc_manufacturer_id, bmc_ip, redfish_host_if, ipmi and the drivers.map rule line. |
| `bmc_last` | `json` | HPS::BMC (every hps-bmc call) | The last call: action, rc (the driver exit code), at, and power for a status call. |
| `audit_at` | `stamp` | node_audit CGI | When the audit was stored. |
| `audit_started_at` | `epoch` | ipxe_audit_admit (IPS-16; cleared by the node_audit CGI) | When the IPS admitted the host to an audit and served it the audit image. Until an audit is stored (the key is then deleted) the host counts as auditing against cluster key audit_max_concurrent, for audit_timeout_seconds at most. |
| `audit_stale` | `bool` | hps-onboard reaudit (cleared by the node_audit CGI) | True when the stored audit is to be redone: a held host with it boots the audit image instead of waiting at iPXE. Absent when the audit is current. |
| `zfs_hostid` | `string` | nixos_boot_lines (nixos-boot-functions.sh) | The node's ZFS hostid: 8 hex digits, the first 8 of the sha256 of the host key MAC (12 lower-case hex digits). Derived, so stable and never needed back; recorded so an operator can see which id a pool was imported under. Passed to the node as spl.spl_hostid=0x<id> on the kernel command line. |
| `macs` | `json` | node_audit CGI (host_audit_intake) | Array of the node's physical NIC MACs from its audit: {mac, ifname, driver, speed}, the host key MAC first. The MAC index is computed from these, so a boot from any listed port reaches this host. A MAC another host holds refuses the audit. |
| `boot_mac_last` | `mac` | ipxe_init_handler | The MAC the node last booted from (which port), as the host may boot from any of its macs. |
| `storage_note` | `string` | hps-onboard | Operator note about the node storage plan. |
| `poweroff_last` | `json` | HPS::Node | Outcome of the last hps-node power-off: result (off, forced, no-bmc, failed), at, detail. |
| `storage_last` | `json` | HPS::Storage | Outcome of the last storage operation: op, ok, at. |
| `storage_pool` | `string` | HPS::Storage | Name of the pool created on the node. |
| `storage_created_at` | `stamp` | HPS::Storage | When the pool was created. |
| `storage_exports` | `json` | HPS::Storage | Array of iSCSI exports: zvol, iqn, initiator, portal. |
| `storage_state` | `string` | HPS::Storage | up or down. |
| `storage_up_at` | `stamp` | HPS::Storage | When storage last came up. |
| `storage_down_at` | `stamp` | HPS::Storage | When storage last went down. |
| `storage_trim_at` | `stamp` | HPS::Storage | When the TRIM check last ran. |
| `storage_trim_verdict` | `string` | HPS::Storage | Text verdict of the TRIM check (TRIM OK or the failure). |
| `storage_trim_ok` | `bool` | HPS::Storage | 1 when the TRIM check passed, else 0. |
| `storage<n>_vlan` | `int` | network-functions (storage address allocation) | VLAN id of storage network n on this node. |
| `storage<n>_ip` | `ip` | network-functions | Address of the node on storage network n. |
| `<prefix>_timestamp` | `epoch` | process_host_audit (host data collection) | When the data collection named by the prefix last ran. |
| `<prefix>_count` | `int` | process_host_audit | Number of fields that collection stored. |

## Cluster keys

| Key | Type | Written by | Meaning |
|---|---|---|---|
| `CLUSTER_NAME` | `string` | cluster initialisation | The cluster name. |
| `CREATED` | `iso8601` | cluster initialisation | When the cluster was created. |
| `STATUS` | `string` | cluster initialisation | Cluster status (initialized). |
| `DESCRIPTION` | `string` | hps-cluster-config | Descriptive name of the cluster. |
| `network_dns_domain` | `string` | hps-cluster-config | DNS domain of the cluster. |
| `network_dhcp_enabled` | `bool` | hps-cluster-config | Whether the IPS serves DHCP. |
| `network_dhcp_iface` | `string` | hps-cluster-config | Interface the IPS listens on for boot requests. |
| `network_dhcp_cidr` | `cidr` | hps-cluster-config | Address of the DHCP interface with prefix; network_dhcp_ip and network_cidr derive from it. |
| `network_dhcp_ip` | `ip` | hps-cluster-config (derived) | The IPS address. |
| `network_cidr` | `cidr` | hps-cluster-config (derived) | The network of the DHCP interface. |
| `network_dhcp_rangesize` | `int` | hps-cluster-config | Number of addresses in the DHCP range. |
| `network_dhcp_range_start` | `ip` | hps-cluster-config | First DHCP address; empty means derived from the range size. |
| `network_dhcp_range_end` | `ip` | hps-cluster-config | Last DHCP address; empty means derived from the range size. |
| `network_static_start` | `ip` | hps-cluster-config | First address of the static range. |
| `network_static_end` | `ip` | hps-cluster-config | Last address of the static range. |
| `network_reserved` | `string` | hps-cluster-config | Reserved IPv4 addresses, comma or space separated; may be empty. |
| `network_storage_count` | `int` | hps-cluster-config, cluster-interactive-functions | Number of storage networks (0 to 10). |
| `network_storage_base_vlan` | `int` | hps-cluster-config, cluster-interactive-functions | VLAN id of the first storage network. |
| `network_storage_subnet_base` | `string` | hps-cluster-config, cluster-interactive-functions | Subnet base (leading octets) the storage subnets are cut from. |
| `network_storage_subnet_cidr` | `int` | hps-cluster-config, cluster-interactive-functions | Prefix length of each storage subnet. |
| `network_storage_mtu` | `int` | hps-cluster-config, cluster-interactive-functions | MTU of the storage networks: 1500 or 9000. |
| `network_storage_vlan<n>_subnet` | `string` | hps-cluster-config, cluster-interactive-functions | Subnet of storage network n. |
| `network_storage_vlan<n>_gateway` | `ip` | hps-cluster-config, cluster-interactive-functions | Gateway of storage network n. |
| `network_storage_vlan<n>_netmask` | `ip` | hps-cluster-config, cluster-interactive-functions | Netmask of storage network n. |
| `network_storage_vlan<n>_domain` | `string` | hps-cluster-config, cluster-interactive-functions | DNS domain of storage network n. |
| `network_storage_vlan<n>_allocated` | `bool` | hps-cluster-config, cluster-interactive-functions, host storage allocation | Whether storage network n has been handed out. |
| `network_syslog_server` | `ip` | hps-cluster-config | Syslog server address. |
| `network_name_server` | `ip` | hps-cluster-config | DNS server address. |
| `network_time_server` | `string` | hps-cluster-config | NTP server address or name the nodes use. |
| `network_time_upstream` | `string` | hps-cluster-config | Upstream time servers for the IPS, comma or space separated; may be empty. |
| `network_layout` | `json` | hps-cluster-config, cluster-bootstrap | Workload network layout, one JSON object. |
| `osvc_log_level` | `string` | hps-cluster-config | OpenSVC log level: debug, info, warn, error. |
| `osvc_listener_port` | `int` | hps-cluster-config | OpenSVC listener port. |
| `osvc_web_ui` | `string` | hps-cluster-config | yes or no: enable the OpenSVC web UI. Words, not a bool. |
| `osvc_web_port` | `int` | hps-cluster-config | OpenSVC web UI port. |
| `osvc_hb_interval` | `int` | hps-cluster-config | Heartbeat interval in seconds. |
| `osvc_hb_timeout` | `int` | hps-cluster-config | Heartbeat timeout in seconds. |
| `osvc_templates_url` | `string` | hps-cluster-config | OpenSVC templates URL; may be empty. |
| `osvc_packages_url` | `string` | hps-cluster-config | OpenSVC packages URL; may be empty. |
| `osvc_hb_type` | `string` | hps-cluster-config | Heartbeat type: multicast or unicast. |
| `OPENSVC_AGENT_KEY` | `string` | opensvc-function-helpers | Secret: the OpenSVC agent key. Never logged or put in an image. |
| `OPENSVC_CLUSTER_SECRET` | `string` | opensvc-function-helpers | Secret: the OpenSVC cluster secret. Never logged or put in an image. |
| `hold_retry_seconds` | `int` | hps-cluster-config; read by the iPXE menu | Seconds a held node with its audit stored waits at iPXE before asking the IPS again; an integer 5..3600, default 30 (a value outside the range is logged and 30 used). |
| `audit_max_concurrent` | `int` | hps-cluster-config; read by the iPXE menu | How many audit boots the IPS serves at once (IPS-16); an integer 0..1000, default 2, 0 means no limit (a value outside the range is logged and 2 used). A held host over the limit gets the hold script and is admitted, first seen first, when a slot frees. Assigned hosts are never limited. |
| `audit_timeout_seconds` | `int` | hps-cluster-config; read by the iPXE menu | Seconds after the IPS served the audit image that a host with no stored audit stops counting as auditing and frees its slot (IPS-16); an integer 30..86400, default 900 (a value outside the range is logged and 900 used). |
| `monitor_interval_seconds` | `int` | hps-cluster-config; read by hps-monitor loop | Seconds between resource checks (ctrl-exec nagios-check) of the paired nodes, logged to syslog; 0 disables, otherwise an integer 10..86400, default 60 (a value outside the range is logged and 60 used). Read afresh every tick. |
| `operator_api_listen` | `ip` | hps-cluster-config; read by ce_api_bring_up at IPS start | The address of this IPS on which the ctrl-exec API listens with TLS (port 7445) for remote operators (docs/OPERATOR.md). Empty or unset: no TCP listener, no remote operator. Must be one address of the IPS, not loopback or a wildcard. |
| `ips_admin_read_timeout` | `int` | hps-cluster-config; read by ce_ips_agent_bring_up (ips_admin_read_timeout) | Seconds the dispatcher waits for the IPS's own ips-admin agent to answer (set on its registry record with ctrl-exec 0.14.7 --read-timeout; node agents keep the global read_timeout); an integer 60..3600, default 900 (a value outside the range is logged and 900 used). Applied at the next IPS start. |
| `syslog_forward_host` | `ip` | ips-syslog-forward (ips_syslog_forward), hps-cluster-config | Optional: collector every syslog message of this IPS is forwarded to (TCP 514). Unset: no forwarding. |
| `syslog_forward_prefix` | `string` | ips-syslog-forward (ips_syslog_forward), hps-cluster-config | Host name prefix for the forwarded messages (<prefix>.<hostname>); 1-32 of a-z 0-9 -. Set with syslog_forward_host. |
| `held_reboot_after_audit` | `bool` | hps-cluster-config; read by the iPXE menu | Whether the audit image reboots after the IPS accepts its audit (true, the default) or stays up for inspection over ctrl-exec (false); passed to the image as hps.audit_reboot=0. |
| `egress_proxy` | `string` | hps-cluster-config; read by the iPXE menu | HTTP proxy the image builder (node-builder) reaches the internet through, http://<host>:<port>; passed to that image only as hps.proxy= (docs/BUILDER.md). Unset: no proxy on the command line. |
| `nixos_default_pin` | `pin` | operator (hps-cluster-config or the API); read by the iPXE menu | The pin a NixOS node boots when it has no pin of its own. |
| `power_devices` | `json` | HPS::BMC (hps-bmc device set) | Object of power devices (PDU, smart plug) keyed by name: addr and options (cmd template). Hosts using the external driver refer to one as outlet=<name>:<n>. Credentials are in the keysafe, never here. |
| `workload_<name>` | `json` | HPS::Workload (create, start, stop; removed by destroy) | Instance record of a workload: state, VMs, disks, macs, define (the vm-define arguments of create), created_at, by. |
| `workload_<name>_destroyed` | `json` | HPS::Workload destroy (removed by the next create) | Audit record of a destroyed workload: at (when), by (who). The definition file workloads/<name>.json is kept. |

## Free-form writers

These write keys chosen by the caller at run time, so no row above can name them.

| File | What it writes |
|---|---|
| `http/api/api.sh` | host and cluster registry set and unset through the API: the caller names the key. |
| `http/cgi-bin/boot_manager.sh` | host_variable set and unset (refused with 403 over CGI; kept for the legacy node-manager protocol). |
| `lib/functions.d/host-functions.sh` | host data collection: <prefix>_<field> for each field of the collection. |
| `lib/functions.d/os-functions.sh` | OS registry keys (os.db) are configured by the OS tooling, not catalogued here. |

## Rules

- A key holds one type, the one in this table. A boolean-looking name never holds a timestamp.
- Readers use the typed accessors (`host_get_bool`, `host_get_epoch`), which refuse a value of the wrong type and name the key.
- A key is renamed only with a compatibility window: the old key keeps being written for one release and is marked deprecated here.
- Adding a key means adding its row; `t/83-registry-keys.t` fails when code writes a key that has none.
