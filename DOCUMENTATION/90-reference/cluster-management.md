## Cluster management

Clusters are managed by OpenSVC.

The central config file is generated on the IPS and downloaded on demand by cluster hosts. It is dynamically built based on the cluster config.

### OpenSVC

we are using v3

Note:

Docs are incomplete. 

- V3 docs: https://book.opensvc.com/a
- V2 docs: https://docs.opensvc.com/latest/


| Thing you want to set                      | Where / How                                      |      |             |
| ------------------------------------------ | ------------------------------------------------ | ---- | ----------- |
| Agent log path/level                       | `opensvc.conf` (`log_file`, `log_level`)         |      |             |
| Agent TCP listener / Web UI ports          | `opensvc.conf` (`listener_port`, `web_ui*`)      |      |             |
| Node local tags for default behavior       | `opensvc.conf` (`tags`)                          |      |             |
| Cluster members / node IPs / names         | `cluster.conf`                                   |      |             |
| Service resources (zpool/zvol/fs/ip/share) | `om ... create/set` → lives under `services/*`   |      |             |
| Placement rules (tags=storage, nodename=…) | `om mysvc set --kw placement=…` (in service cfg) |      |             |
| Start/stop/provision services              | \`om mysvc start                                 | stop | provision\` |
| Distribute service configs to other nodes  | `om mysvc push` / `om mysvc sync`                |      |             |

