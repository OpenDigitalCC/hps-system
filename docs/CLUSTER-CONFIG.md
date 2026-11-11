# Cluster configuration

A cluster is configured by a fixed list of questions (`hps-cluster-config
questions`). Three entry points answer that same list.

- The menu (`cli/cluster-configure.sh`, scripts in
  `scripts/cluster-config.d/`) asks them interactively. It is the entry
  point today.
- A declarative file, applied with `hps-cluster-config apply`, is available
  today.
- A web form is planned for after the control API provides authentication; it
  will read the same list from `hps-cluster-config questions --json`.

The menu scripts still carry their own prompts; `t/80` parses them and fails if a
prompt or a stored key has no catalogue entry, so the two cannot drift apart
unnoticed. The menu's commit step (`commit_changes` in
`lib/functions.d/cluster-interactive-functions.sh`) sends its pending pairs to
`hps-cluster-config apply -`, so the menu, `scripts/cluster-bootstrap.sh` and
a file are validated, derived and written by one implementation.

## Commands

```
hps-cluster-config [--cluster NAME] questions [--json]
hps-cluster-config [--cluster NAME] show [--json]
hps-cluster-config [--cluster NAME] get KEY
hps-cluster-config [--cluster NAME] set KEY VALUE [--dry-run] [--json]
hps-cluster-config [--cluster NAME] apply FILE|- [--dry-run] [--json]
hps-cluster-config [--cluster NAME] export [--json]
```

The cluster defaults to `ACTIVE_CLUSTER`.

`show` lists every catalogued key (unset keys as unset), then derived keys,
then registry keys that are not in the catalogue (listed, never dropped).
`export` writes the current configuration in the `apply` format with the
prompt as a comment above each key, so `export > f; edit f; apply f` is the
round trip. Unset keys are exported commented out with their default; derived
keys are left out because `apply` recomputes them.

## File format

`key = value` lines. `#` starts a comment line; blank lines are ignored. There
is no quoting and no inline comment: the value is everything after the first
`=`, trimmed. A file whose first character is `{` is read as one JSON object
of string, number or boolean values instead. Each key may appear once.

`apply` validates the whole file first. It reports every error with its line,
and writes nothing if there is any error (exit 3). Otherwise it writes the
keys, then the derived keys, one registry write per changed key, and prints
what changed (old to new) and what is unchanged. Only keys named in the file
are written; keys not mentioned keep their stored value. `--dry-run` prints
the plan and writes nothing. Required keys that are still unset afterwards
are listed, not treated as an error, so a file may update part of a
configuration.

No key in the catalogue is a secret, and a key whose name looks like one
(secret, password, token, credential, psk, private, key) is refused.

### Derived keys

- `network_dhcp_ip` and `network_cidr` come from `network_dhcp_cidr`.
- `network_storage_vlanN_subnet`, `_gateway`, `_netmask`, `_domain` and
  `_allocated` come from the storage count, base VLAN, subnet base, subnet
  prefix and DNS domain, with the arithmetic of
  `050-set-storage-network.sh`. `_allocated` is runtime state: it starts as
  `false` and is never reset by `apply`.

A derived key may appear in a file only if it equals the computed value.

### Example

```
# Cluster configuration
DESCRIPTION = $CLUSTER description
network_dns_domain = cluster.local
network_dhcp_iface = $IFACE
network_dhcp_cidr = $IPS_ADDRESS/24
network_dhcp_rangesize = 100
network_storage_count = 2
network_storage_base_vlan = 31
network_storage_subnet_cidr = 24
network_syslog_server = $IPS_ADDRESS
network_name_server = $IPS_ADDRESS
network_time_server = $IPS_ADDRESS
osvc_hb_type = unicast
```

## Menu and bootstrap

`commit_changes` writes the pending `key:value` pairs (split at the first `:`) as
`key = value` lines to `bin/hps-cluster-config apply - --cluster NAME`, then
generates the DNS/DHCP files. When validation rejects the set it returns
non-zero after the errors were printed and nothing is written; the pending
array is kept. A key pended twice keeps its last value. Bootstrap's storage
values are derived keys like any other: they must equal the computed value.

Keys with `menu: false` are not asked by the menu: they come from the
interface, from bootstrap or from a file.

### Network layout

`network_layout` is one JSON object, as `net-bridge-ensure` reads it:
`{"<name>": {"cidr", "vlan", "bridge", "purpose", "nic"?, "uplink"?}}`. Names match
`^[a-z][a-z0-9-]{0,15}$`; `cidr` is IPv4/prefix; `vlan` is 1 to 4094, or
`null` or absent for untagged; `bridge` matches `^br-[a-z0-9-]{1,12}$`;
`purpose` is a short word; `nic` is a MAC address when present. `uplink`
is `boot` only, and only with `purpose` `provisioning`, with no `vlan` and no
`nic`: the bridge is the one `hps-net` builds on the node's boot NIC (host key
`boot_bridge`, see `docs/VM-LIFECYCLE.md`), so a VM can sit on the provisioning
segment itself; `net-bridge-ensure` only checks that it exists. VLANs and
bridges may not repeat.

A fabric network (an emulated switch for the scale test) is
`{"kind": "fabric", "purpose": "emulated-switch", "bridge": "br-fab", "mtu"?}`:
no `cidr`, `vlan`, `nic` or `uplink`; `mtu` is 576 to 9216 (default 9000).
`kind` is `fabric` only, `purpose` `emulated-switch` only with it, and `mtu`
only with it. `net-bridge-ensure` builds a bridge with `vlan_filtering 1` and no
member NIC (see `docs/VM-LIFECYCLE.md`); VMs attach with per-NIC VLANs
(`docs/WORKLOADS.md`).

In the text file format the JSON goes on one line
after `network_layout =`; in a JSON file it may be an object. It is stored,
compared and exported as canonical one-line JSON.

## Catalogue

Produced by `hps-cluster-config questions --json` (rows in menu order). The
rule is `text`, `regex:`, `enum:`, `int:MIN..MAX`, `bool`, `ip`, `cidr`,
`host` (address or host name), `dnsdomain`, `subnet_base` (`X.Y`), `iplist` and
`hostlist` (comma or space separated) or `layout`. Optional
keys may be empty.

| Key | Group | Prompt | Rule | Default | Required |
|---|---|---|---|---|---|
| `DESCRIPTION` | description | Enter descriptive name for this cluster | `regex:.+` | - | yes |
| `network_dns_domain` | dns | Enter DNS domain name for this cluster | `dnsdomain` | `cluster.local` | yes |
| `network_dhcp_enabled` | dhcp | DHCP enabled | `bool` | `true` | no |
| `network_dhcp_iface` | dhcp | Select interface to listen on for boot requests | `regex:[A-Za-z0-9_.:@-]+` | - | yes |
| `network_dhcp_cidr` | dhcp | Address of the DHCP interface (IP/prefix) | `cidr` | - | yes |
| `network_dhcp_rangesize` | dhcp | DHCP range size (number of IPs) | `int:1..16777216` | `100` | no |
| `network_dhcp_range_start` | dhcp | DHCP range start (blank: from the range size) | `ip` | (empty) | no |
| `network_dhcp_range_end` | dhcp | DHCP range end (blank: from the range size) | `ip` | (empty) | no |
| `network_static_start` | dhcp | Static address range start (inside the DHCP network) | `ip` | - | no |
| `network_static_end` | dhcp | Static address range end (inside the DHCP network) | `ip` | - | no |
| `network_reserved` | dhcp | Reserved addresses (IPv4, comma or space separated; may be empty) | `iplist` | (empty) | no |
| `network_storage_count` | storage-networks | Number of storage networks to configure (1-10) | `int:0..10` | `2` | no |
| `network_storage_base_vlan` | storage-networks | Storage network base VLAN ID (31-99) | `int:31..99` | `31` | no |
| `network_storage_subnet_base` | storage-networks | Storage subnet base | `subnet_base` | from `network_storage_base_vlan` | no |
| `network_storage_subnet_cidr` | storage-networks | Storage subnet CIDR mask (16-28) | `int:16..28` | `24` | no |
| `network_storage_mtu` | storage-networks | Enable jumbo frames (9000 MTU) on storage networks? | `enum:1500,9000` | `1500` | no |
| `network_syslog_server` | services | Syslog server IP address | `ip` | from `network_dhcp_ip` | no |
| `network_name_server` | services | DNS server IP address | `ip` | from `network_dhcp_ip` | no |
| `network_time_server` | services | NTP server address | `host` | from `network_dhcp_ip` | no |
| `network_time_upstream` | services | Upstream time servers (host names or IPv4, comma or space separated; may be empty) | `hostlist` | (empty) | no |
| `network_layout` | networks | Workload network layout (one-line JSON object) | `layout` | - | no |
| `osvc_log_level` | opensvc | Log level (debug/info/warn/error) | `enum:debug,info,warn,error` | `info` | no |
| `osvc_listener_port` | opensvc | Listener port (1024-65535) | `int:1024..65535` | `1215` | no |
| `osvc_web_ui` | opensvc | Enable Web UI? | `enum:yes,no` | `yes` | no |
| `osvc_web_port` | opensvc | Web UI port (1024-65535) | `int:1024..65535` | `1214` | no |
| `osvc_hb_interval` | opensvc | Heartbeat interval in seconds (1-60) | `int:1..60` | `5` | no |
| `osvc_hb_timeout` | opensvc | Heartbeat timeout in seconds (5-300) | `int:5..300` | `15` | no |
| `osvc_templates_url` | opensvc | Templates URL | `text` | (empty) | no |
| `osvc_packages_url` | opensvc | Packages URL | `text` | (empty) | no |
| `osvc_hb_type` | opensvc | Heartbeat type (multicast/unicast) | `enum:multicast,unicast` | `unicast` | no |
| `hold_retry_seconds` | onboarding | Seconds a held node with its audit stored waits at iPXE between requests (5-3600) | `int:5..3600` | `30` | no |
| `monitor_interval_seconds` | monitoring | Seconds between resource checks of the paired nodes (10-86400; 0 disables) | `int0:10..86400` | `60` | no |
| `held_reboot_after_audit` | onboarding | Reboot the audit image after the IPS accepts its audit (false keeps it up for inspection) | `bool` | `true` | no |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | done |
| 1 | failed (registry error) |
| 2 | usage |
| 3 | refused: validation errors, nothing written |
| 4 | not found: cluster, input file, or an unset key for `get` |

With `--json`, `apply` and `set` print one object (`ok`, `dry_run`,
`cluster`, `errors`, `changes`, `unchanged`, `missing_required`) on stdout,
also when they exit 3.
