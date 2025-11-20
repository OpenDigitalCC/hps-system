# lib_sozu.sh - Sozu Proxy Management Library

Bash function library for managing Sozu reverse proxy via Docker.

## Overview

This library provides functions prefixed with `s_` for managing Sozu proxy clusters, backends, listeners, and frontends. All functions interact with Sozu running in a Docker container via `docker exec`.

## Prerequisites

- Docker installed
- Sozu container running (default name: `sozu`)
- Sozu config file at `/etc/sozu/config.toml` inside container
- Run commands as root or with appropriate Docker permissions

## Installation

```bash
source /path/to/lib_sozu.sh
```

## Function Reference

### Cluster Operations

#### s_cluster_add
Add a new cluster to Sozu proxy.

**Usage:**
```bash
s_cluster_add <cluster_id> <load_balancing_policy> [container_name]
```

**Parameters:**
- `cluster_id` - Unique identifier for the cluster
- `load_balancing_policy` - Load balancing policy (e.g., `random`, `roundrobin`)
- `container_name` - (Optional) Name of Sozu container (default: `sozu`)

**Returns:**
- `0` on success
- `1` if container not found or not running
- `2` if sozu command failed

**Example:**
```bash
s_cluster_add "web-cluster" "random"
s_cluster_add "api-cluster" "roundrobin" "sozu-prod"
```

#### s_cluster_remove
Remove a cluster from Sozu proxy.

**Usage:**
```bash
s_cluster_remove <cluster_id> [container_name]
```

**Example:**
```bash
s_cluster_remove "web-cluster"
s_cluster_remove "web-cluster" "sozu-prod"
```

#### s_cluster_list
List all clusters in Sozu proxy.

**Usage:**
```bash
s_cluster_list [container_name]
```

**Example:**
```bash
s_cluster_list
s_cluster_list "sozu-prod"
```

---

### Backend Operations

#### s_backend_add
Add a backend to a Sozu cluster.

**Usage:**
```bash
s_backend_add <cluster_id> <backend_id> <address> [container_name]
```

**Parameters:**
- `cluster_id` - Cluster identifier to add backend to
- `backend_id` - Unique identifier for the backend
- `address` - Backend address in format `IP:PORT` (e.g., `127.0.0.1:8080`)
- `container_name` - (Optional) Name of Sozu container (default: `sozu`)

**Returns:**
- `0` on success
- `1` if container not found or not running
- `2` if sozu command failed

**Example:**
```bash
s_backend_add "web-cluster" "backend-1" "127.0.0.1:8080"
s_backend_add "web-cluster" "backend-2" "192.168.1.10:8080" "sozu-prod"
```

#### s_backend_remove
Remove a backend from a Sozu cluster.

**Usage:**
```bash
s_backend_remove <cluster_id> <backend_id> <address> [container_name]
```

**Example:**
```bash
s_backend_remove "web-cluster" "backend-1" "127.0.0.1:8080"
s_backend_remove "web-cluster" "backend-1" "127.0.0.1:8080" "sozu-prod"
```

**Note:** There is no `s_backend_list` function as Sozu does not provide a backend listing command.

---

### Listener Operations

#### s_listener_http_add
Add an HTTP listener to Sozu proxy.

**Usage:**
```bash
s_listener_http_add <bind_address> [container_name]
```

**Parameters:**
- `bind_address` - Address to bind listener to in format `IP:PORT` (e.g., `0.0.0.0:8080`)
- `container_name` - (Optional) Name of Sozu container (default: `sozu`)

**Behaviour:**
- Automatically adds `--expect-proxy` flag

**Returns:**
- `0` on success
- `1` if container not found or not running
- `2` if sozu command failed

**Example:**
```bash
s_listener_http_add "0.0.0.0:8080"
s_listener_http_add "0.0.0.0:9000" "sozu-prod"
```

**Note:** By default, Sozu includes HTTP listener on port 80 and HTTPS on port 443.

#### s_listener_http_remove
Remove an HTTP listener from Sozu proxy.

**Usage:**
```bash
s_listener_http_remove <bind_address> [container_name]
```

**Example:**
```bash
s_listener_http_remove "0.0.0.0:8080"
s_listener_http_remove "0.0.0.0:8080" "sozu-prod"
```

#### s_listener_list
List all listeners in Sozu proxy.

**Usage:**
```bash
s_listener_list [container_name]
```

**Example:**
```bash
s_listener_list
s_listener_list "sozu-prod"
```

---

### Frontend Operations

#### s_frontend_http_add
Add an HTTP frontend to Sozu proxy.

**Usage:**
```bash
s_frontend_http_add <bind_address> <hostname> <cluster_id> [container_name]
```

**Parameters:**
- `bind_address` - Address to bind frontend to in format `IP:PORT` (e.g., `0.0.0.0:80`)
- `hostname` - Hostname for the frontend (e.g., `example.com`)
- `cluster_id` - Cluster identifier to route traffic to
- `container_name` - (Optional) Name of Sozu container (default: `sozu`)

**Returns:**
- `0` on success
- `1` if container not found or not running
- `2` if sozu command failed

**Example:**
```bash
s_frontend_http_add "0.0.0.0:80" "example.com" "web-cluster"
s_frontend_http_add "0.0.0.0:80" "api.example.com" "api-cluster" "sozu-prod"
```

#### s_frontend_http_remove
Remove an HTTP frontend from Sozu proxy.

**Usage:**
```bash
s_frontend_http_remove <bind_address> <hostname> <cluster_id> [container_name]
```

**Example:**
```bash
s_frontend_http_remove "0.0.0.0:80" "example.com" "web-cluster"
s_frontend_http_remove "0.0.0.0:80" "example.com" "web-cluster" "sozu-prod"
```

#### s_frontend_list
List all frontends in Sozu proxy.

**Usage:**
```bash
s_frontend_list [container_name]
```

**Example:**
```bash
s_frontend_list
s_frontend_list "sozu-prod"
```

---

### Validation Operations

#### s_validate_endpoint
Validate a Sozu endpoint by making an HTTP request.

**Usage:**
```bash
s_validate_endpoint <hostname> <port> [container_name]
```

**Parameters:**
- `hostname` - Hostname to test (will be sent as Host header)
- `port` - Port to connect to
- `container_name` - (Optional) Name of Sozu container (default: `sozu`)

**Behaviour:**
- Uses curl to make HTTP request to `127.0.0.1:<port>` with Host header
- Returns response from backend service

**Returns:**
- `0` on success (HTTP 200-399)
- `1` if curl command failed
- `2` if HTTP error (400+)

**Example:**
```bash
s_validate_endpoint "example.com" "80"
s_validate_endpoint "api.example.com" "8080" "sozu-prod"
```

---

## Complete Workflow Example

Here's a complete example of setting up a web service through Sozu:

```bash
#!/bin/bash
source /path/to/lib_sozu.sh

# 1. Create a cluster
s_cluster_add "myapp-cluster" "random"

# 2. Add backend servers
s_backend_add "myapp-cluster" "server-1" "192.168.1.10:8080"
s_backend_add "myapp-cluster" "server-2" "192.168.1.11:8080"

# 3. Create a listener (optional, if not using default port 80)
s_listener_http_add "0.0.0.0:8080"

# 4. Create frontend binding
s_frontend_http_add "0.0.0.0:80" "myapp.example.com" "myapp-cluster"

# 5. Validate the endpoint
s_validate_endpoint "myapp.example.com" "80"

# 6. List everything to verify
echo "=== Clusters ==="
s_cluster_list

echo "=== Listeners ==="
s_listener_list

echo "=== Frontends ==="
s_frontend_list
```

## Testing

A comprehensive test suite is provided in `test_lib_sozu.sh`:

```bash
# Make test script executable
chmod +x test_lib_sozu.sh

# Run tests (requires Docker and Sozu container running)
./test_lib_sozu.sh
```

The test script will:
1. Create test cluster, backend, listener, and frontend
2. Verify each operation succeeded
3. Clean up all test resources
4. Report pass/fail statistics

## Output Formatting

All functions return raw Sozu output by default. An example formatting script is provided in `example_sozu_format.sh` showing how to parse and format list outputs.

To use the formatting examples:

```bash
source example_sozu_format.sh

# Show formatted status overview
show_sozu_status

# Or format individual lists
format_cluster_list
format_listener_list
format_frontend_list
```

## Error Handling

All functions follow consistent error handling:

- **Success:** Print success message with operation details, then raw output
- **Failure:** Print error message describing the failure
- **Return codes:**
  - `0` = success
  - `1` = docker/compose command failed
  - `2` = sozu command failed

Example error output:
```
ERROR: Failed to add cluster 'web-cluster': cluster already exists
```

Example success output:
```
SUCCESS: Cluster 'web-cluster' added with policy 'random'
[raw sozu output]
```

## Integration with HPS System

These functions are designed to integrate with the HPS system:

- Prefix `s_` indicates service-level functions
- Can be called from IPS or TCH/SCH nodes
- Compatible with existing HPS logging and config functions
- Follow HPS function documentation standards

To integrate with HPS config storage:

```bash
# Store cluster config in cluster_config
cluster_config "set" "sozu_cluster_myapp" "myapp-cluster"

# Store backend config in host_config
host_config "00:11:22:33:44:55" "set" "sozu_backend" "192.168.1.10:8080"
```

## Notes

- All functions use `docker exec -i` for non-interactive execution
- The `-u root` flag is only used for `s_cluster_add` as required by Sozu
- Config file path `/etc/sozu/config.toml` is hardcoded in the container
- Sudo is not used internally - run the entire script with sudo if needed
- Container verification is performed before each operation
- Default container name is `sozu` but can be overridden per function call
- Functions no longer depend on docker compose, making them more portable

## Load Balancing Policies

Currently tested policies:
- `random` - Random backend selection
- `roundrobin` - Round-robin backend selection

Note: Other policies may be available but are untested.

## Future Enhancements

Potential additions:
- HTTPS listener and frontend functions
- TLS certificate management
- Backend health check functions
- Metrics and statistics retrieval
- Container availability checking
- Configuration backup/restore
- Idempotency checks (don't re-add existing resources)

## License

This library is part of the HPS System project and follows the same open source license.

Repository: https://github.com/OpenDigitalCC/hps-system/
