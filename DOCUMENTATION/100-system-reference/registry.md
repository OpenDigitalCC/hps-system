# HPS Registry System

## Overview

The HPS Registry System provides JSON-based configuration storage for the HPS infrastructure management platform. It implements a file-per-key architecture with atomic operations, file locking for concurrency safety, and a searchable query interface.

## Architecture

### Storage Model

The registry uses a hierarchical directory structure where each configuration scope has its own `.db` directory:

```
/srv/hps-config/
├── system.db/              # System-level configuration
│   └── ACTIVE_CLUSTER.json
├── os.db/                  # Operating system definitions
│   ├── x86_64_alpine_3.20.os/
│   │   ├── name.json
│   │   ├── version.json
│   │   └── repo_path.json
│   └── x86_64_rocky_10.os/
└── clusters/
    └── test-1/
        ├── cluster.db/     # Cluster configuration
        │   ├── NETWORK_CIDR.json
        │   └── DNS_DOMAIN.json
        └── hosts/
            └── 5254009c4c24.db/    # Host configuration
                ├── HOSTNAME.json
                ├── IP.json
                └── STATE.json
```

### Key Features

**Atomic Operations**

- File locking prevents race conditions during concurrent writes
- Stale lock detection (removes locks from dead processes)
- Lock timeout prevents indefinite blocking (5 seconds)

**Data Integrity**

- JSON validation on all write operations
- Automatic value wrapping (strings/numbers/booleans)
- Corrupted file detection on reads

**Searchability**

- Direct filesystem scanning for key/value searches
- Registry-wide queries across all hosts or cluster configs
- Efficient lookups using file-per-key structure

**Raw Mode**

- Returns unquoted strings by default (`HPS_REGISTRY_RAW_MODE=true`)
- Simplifies value handling in bash scripts
- JSON format available when needed (`HPS_REGISTRY_RAW_MODE=false`)

## Core Functions

### json_registry

Low-level registry operations. All higher-level registries use this internally.

```bash
json_registry <db_path> <command> <key> [value]
```

**Commands:**

- `get` - Retrieve value (raw string by default)
- `set` - Store value (validates JSON, auto-wraps primitives)
- `delete` - Remove key
- `exists` - Check if key exists
- `list` - List all keys
- `view` - Return all keys as single JSON object

**Example:**

```bash
json_registry "/srv/hps-config/system.db" set EXAMPLE "value"
json_registry "/srv/hps-config/system.db" get EXAMPLE
# Output: value
```

### system_registry

Manages system-level configuration.

```bash
system_registry <command> <key> [value]
```

**Common Keys:**

- `ACTIVE_CLUSTER` - Currently active cluster name

**Example:**

```bash
system_registry set ACTIVE_CLUSTER "production"
system_registry get ACTIVE_CLUSTER
# Output: production
```

### cluster_registry

Manages cluster-specific configuration.

```bash
cluster_registry <command> <key> [value]
```

**Common Keys:**

- `CLUSTER_NAME` - Cluster identifier
- `NETWORK_CIDR` - Network range (e.g., "10.99.1.0/24")
- `DNS_DOMAIN` - DNS domain for cluster
- `DHCP_IP` - DHCP server IP address
- `DHCP_RANGESIZE` - Size of DHCP pool

**Example:**

```bash
cluster_registry set NETWORK_CIDR "10.99.1.0/24"
cluster_registry set DNS_DOMAIN "prod.example.com"
cluster_registry list
```

### host_registry

Manages host-specific configuration. Automatically normalizes MAC addresses.

```bash
host_registry <mac> <command> [key] [value]
```

**Common Keys:**

- `HOSTNAME` - Host identifier
- `IP` - IPv4 address
- `NETMASK` - Network mask
- `TYPE` - Host type (TCH, SCH, etc.)
- `STATE` - Current state (UNCONFIGURED, CONFIGURED, INSTALLED, etc.)
- `arch` - Architecture (x86_64, arm64, etc.)

**Example:**

```bash
host_registry "52:54:00:9c:4c:24" set HOSTNAME "tch-001"
host_registry "52:54:00:9c:4c:24" set IP "10.99.1.5"
host_registry "52:54:00:9c:4c:24" get HOSTNAME
# Output: tch-001
```

### os_registry

Manages operating system definitions.

```bash
os_registry <os_id> <command> [key] [value]
os_registry list
```

**OS ID Format:** `architecture:name:version` (e.g., `x86_64:alpine:3.20`)

**Common Keys:**

- `name` - OS name (alpine, rockylinux)
- `version` - OS version (3.20, 10)
- `arch` - Architecture (x86_64)
- `repo_path` - Distribution directory name

**Example:**

```bash
os_registry "x86_64:alpine:3.20" set name "alpine"
os_registry "x86_64:alpine:3.20" set version "3.20"
os_registry "x86_64:alpine:3.20" set repo_path "x86_64_alpine-3.20"
os_registry list
# Output: x86_64:alpine:3.20
#         x86_64:rocky:10
```

### registry_search

Search across registries for matching key/value pairs.

```bash
registry_search <type> <field> <value>
```

**Types:**

- `host` - Search all host registries
- `cluster` - Search cluster registry

**Example:**

```bash
# Find host by IP address
registry_search host IP "10.99.1.15"
# Output: 52540061c8c9

# Find all SCH hosts
registry_search host TYPE SCH
# Output: 52540061c8c9
#         52540061ed98
```

## Usage Patterns

### Check and Set Pattern

```bash
if cluster_registry exists NETWORK_CIDR; then
  current=$(cluster_registry get NETWORK_CIDR)
  echo "Network already configured: $current"
else
  cluster_registry set NETWORK_CIDR "10.99.1.0/24"
fi
```

### List and Process Pattern

```bash
# Process all hosts
while IFS= read -r mac; do
  hostname=$(host_registry "$mac" get HOSTNAME)
  ip=$(host_registry "$mac" get IP)
  echo "$hostname: $ip"
done < <(list_cluster_hosts)
```

### View All Configuration

```bash
# Get complete cluster config as JSON
cluster_registry view

# Get complete host config as JSON
host_registry "52:54:00:9c:4c:24" view
```

### Atomic Updates

The registry automatically handles locking for atomic updates:

```bash
# Multiple processes can safely update same host
host_registry "$mac" set FIELD1 "value1" &
host_registry "$mac" set FIELD2 "value2" &
wait
# Both updates succeed without corruption
```

## Integration with Helper Functions

Several helper functions wrap registry operations for common tasks:

### get_active_cluster_name

```bash
cluster_name=$(get_active_cluster_name)
# Internally: system_registry get ACTIVE_CLUSTER
```

### set_active_cluster

```bash
set_active_cluster "production"
# Internally: system_registry set ACTIVE_CLUSTER "production"
```

### load_cluster_config

```bash
load_cluster_config
# Exports all cluster registry keys as environment variables
echo $NETWORK_CIDR
echo $DNS_DOMAIN
```

### get_host_os_id

```bash
os_id=$(get_host_os_id "52:54:00:9c:4c:24")
# Returns: x86_64:alpine:3.20
# Uses: host_registry for TYPE/arch, cluster_registry for OS mapping
```

## Compatibility Aliases

For code clarity and backward compatibility, these aliases are available:

```bash
host_config() { host_registry "$@"; }
cluster_config() { cluster_registry "$@"; }
```

Both forms work identically:
```bash
host_config "52:54:00:9c:4c:24" get HOSTNAME
host_registry "52:54:00:9c:4c:24" get HOSTNAME
```

## Performance Considerations

**File-per-key Architecture**

- Efficient for sparse reads (only loads requested keys)
- Scales well with many hosts (no monolithic file parsing)
- Direct filesystem caching benefits

**Lock Overhead**

- Adds ~0.1s per write operation
- Read operations are lock-free
- Stale lock detection prevents indefinite blocking

**Recommended Usage**

- Batch related updates when possible
- Use `view` for reading multiple keys together
- Avoid tight loops with individual key reads

## Error Handling

All registry functions return standard exit codes:

```bash
if host_registry "$mac" get HOSTNAME >/dev/null 2>&1; then
  echo "Host configured"
else
  echo "Host not found or key missing"
fi
```

**Common Return Codes:**

- `0` - Success
- `1` - Key not found / operation failed
- `2` - Invalid input (malformed JSON, bad key format)
- `3` - Lock timeout

## Best Practices

1. **Always check return codes** for set operations
2. **Use exists before get** if key might not be set
3. **Use view for multiple keys** rather than repeated gets
4. **Normalize MACs consistently** (host_registry does this automatically)
5. **Use specific searches** (registry_search) over manual iteration
6. **Validate JSON** when storing complex structures
7. **Use meaningful key names** (uppercase, underscore-separated)

## Example: Complete Host Lifecycle

```bash
#!/bin/bash
mac="52:54:00:9c:4c:24"

# Initialize host
host_registry "$mac" set STATE "UNCONFIGURED"
host_registry "$mac" set arch "x86_64"

# Configure network
host_registry "$mac" set HOSTNAME "tch-001"
host_registry "$mac" set IP "10.99.1.5"
host_registry "$mac" set NETMASK "255.255.255.0"
host_registry "$mac" set TYPE "TCH"
host_registry "$mac" set STATE "CONFIGURED"

# Verify configuration
if host_registry "$mac" exists HOSTNAME; then
  hostname=$(host_registry "$mac" get HOSTNAME)
  echo "Host configured as: $hostname"
fi

# View complete config
host_registry "$mac" view

# Search by hostname
found_mac=$(registry_search host HOSTNAME "tch-001")
echo "Found MAC: $found_mac"

# Cleanup (if needed)
host_registry "$mac" delete HOSTNAME
```
