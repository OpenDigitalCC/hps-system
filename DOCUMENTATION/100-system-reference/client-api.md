# HPS API Client Documentation

## Overview

The HPS API client provides JSON-based communication between nodes (TCH/SCH) and the IPS server. It offers both modern registry operations and backward-compatible functions for existing code.

## Setup


```bash
# Load the API client functions on your node
source /path/to/hps-api-client.sh

# Test connectivity
n_api_health

```

## Core Functions

### Health Check


```bash
# Check API status
n_api_health
# Returns: JSON with status, version, uptime, etc.

```

### Registry Operations

Registry functions store JSON data with per-key files for atomic operations.

#### Host Registry


```bash
# Set a value (must be valid JSON)
n_host_registry set "config" '{"type": "SCH", "cores": 16}'

# Get a value
n_host_registry get "config"
# Returns: {"type": "SCH", "cores": 16}

# Delete a key
n_host_registry delete "config"

# List all keys
n_host_registry list
# Returns: ["key1", "key2", ...]

# View all data
n_host_registry view
# Returns: {"key1": {...}, "key2": {...}}

```

#### Cluster Registry

Same operations but for cluster-wide data:


```bash
n_cluster_registry set "api_enabled" '"true"'
n_cluster_registry get "api_enabled"
n_cluster_registry delete "api_enabled"
n_cluster_registry list
n_cluster_registry view

```

### Legacy Compatible Functions

These maintain compatibility with existing code while using the API backend.

#### Host Variables


```bash
# Set a variable
n_remote_host_variable "hostname" "node-001"

# Get a variable
value=$(n_remote_host_variable "hostname")

# Unset a variable
n_remote_host_variable "hostname" --unset

```

#### Cluster Variables


```bash
# Set
n_remote_cluster_variable "DNS_DOMAIN" "example.com"

# Get
domain=$(n_remote_cluster_variable "DNS_DOMAIN")

# Unset
n_remote_cluster_variable "DNS_DOMAIN" --unset

```

### Logging


```bash
# Direct message
n_remote_log "System initialized"

# From command output
dmesg | tail -10 | n_remote_log

# Multi-line
echo -e "Line 1\nLine 2" | n_remote_log

```

### Search


```bash
# Find hosts by field value

n_registry_search "TYPE" "SCH"

# Returns: ["52540011223344", "52540055667788"]

n_registry_search "STATE" "INSTALLED"

```

## JSON Data Guidelines

### Simple Values

Strings must be quoted:

```bash
n_host_registry set "name" '"my-host"'        # Correct
n_host_registry set "name" "my-host"          # Wrong - invalid JSON

```

Numbers and booleans don't need quotes:

```bash
n_host_registry set "cores" "16"              # Number
n_host_registry set "active" "true"           # Boolean

```

### Complex Objects


```bash
# Storage configuration
n_host_registry set "storage" '{
  "disks": ["sda", "sdb"],
  "raid": {
    "level": 1,
    "devices": ["/dev/sda1", "/dev/sdb1"]
  }
}'

# Network configuration  
n_host_registry set "network" '{
  "interfaces": {
    "eth0": {"ip": "10.0.0.10", "vlan": null},
    "eth1": {"ip": "10.1.0.10", "vlan": 100}
  }
}'

```

## Error Handling

All functions return non-zero on error:


```bash
if ! n_host_registry get "missing_key" 2>/dev/null; then
  echo "Key not found"
fi

# Or capture error
if ! result=$(n_host_registry get "key" 2>&1); then
  echo "Error: $result"
fi

```

## Low-Level Access

For custom operations:


```bash
# Direct API request
n_api_request "custom_action" "param1=value1" "param2=value2"

# Raw API call with full JSON
response=$(n_api_call "api.sh" '{"action": "custom", "data": {...}}')

```

## Debugging


```bash
# Enable debug mode
export HPS_API_DEBUG=true
n_api_debug

# View raw responses
n_api_call "api.sh" '{"action": "health"}' | jq .

```

## Migration from Legacy

Existing code using `host_config` commands will work unchanged once aliased:


```bash
# Old style - still works
host_config "$MAC" set "TYPE" "SCH"
value=$(host_config "$MAC" get "TYPE")

# New style - recommended
n_host_registry set "type" '"SCH"'
value=$(n_host_registry get "type")

```

## Best Practices

1. **Always validate JSON** before storing:
   
```bash
   data='{"test": true}'
   if echo "$data" | jq . >/dev/null; then
     n_host_registry set "config" "$data"
   fi
   
```

2. **Use meaningful keys** without spaces or special characters:
   
```bash
   Good: "storage_config", "network_vlans", "host_type"
   Bad:  "storage config", "network/vlans", "host.type"
   
```

3. **Handle multi-value data** as JSON arrays:
   
```bash
   # Instead of comma-separated
   n_host_registry set "disks" '["sda", "sdb", "sdc"]'
   
   # Retrieve and process
   disks=$(n_host_registry get "disks" | jq -r '.[]')
   
```

4. **Check connectivity** before bulk operations:
   
```bash
   if n_api_health >/dev/null 2>&1; then
     # API is available
   fi
   
```

## Common Patterns

### Configuration Management

```bash
# Store complete config
n_host_registry set "system" '{
  "hostname": "node-001",
  "type": "SCH",
  "roles": ["storage", "compute"],
  "resources": {
    "cpu": 16,
    "memory_gb": 64,
    "disks": ["sda", "sdb"]
  }
}'

# Update single field
config=$(n_host_registry get "system")
updated=$(echo "$config" | jq '.roles += ["backup"]')
n_host_registry set "system" "$updated"

```

### Status Tracking

```bash
# Regular status update
n_host_registry set "status" "$(jq -n \
  --arg state "active" \
  --arg uptime "$(cat /proc/uptime | cut -d. -f1)" \
  '{
    state: $state,
    uptime_seconds: ($uptime | tonumber),
    last_update: now | strftime("%Y-%m-%dT%H:%M:%SZ")
  }')"

```

### Batch Operations

```bash
# Backup all host data
backup=$(n_host_registry view)
echo "$backup" > "/backup/host-$(date +%Y%m%d).json"

# Find and update multiple hosts
for mac in $(n_registry_search "type" "TCH"); do
  echo "Updating $mac"
  # Update operations
done

```
