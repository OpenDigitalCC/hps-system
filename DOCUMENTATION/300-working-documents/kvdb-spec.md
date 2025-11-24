# KV Database Library Specification

**File:** `lib/functions.d/kvdb-functions.sh`

## Overview

Treat config files as a Key-Value database with proper locking, scanning, and atomic operations. Separate from general file management tools but shares locking mechanisms.

---

## Core Configuration

### Environment Variables
```bash
KVDB_LOCK_STALE_TIMEOUT=${KVDB_LOCK_STALE_TIMEOUT:-5}
KVDB_LOCK_ACQUIRE_TIMEOUT=${KVDB_LOCK_ACQUIRE_TIMEOUT:-30}
KVDB_LOCK_RETRY_INTERVAL=${KVDB_LOCK_RETRY_INTERVAL:-1}
KVDB_LOCK_RETRY_JITTER=${KVDB_LOCK_RETRY_JITTER:-500}  # milliseconds
```

### Lock File Format
```
PID:EPOCH:HOSTNAME:FUNCTION
```
Example: `12345:1696248372:docker-01:kvdb_set`

### Lock File Locations
```
/path/to/file.conf          → /path/to/.file.conf.lock
/path/to/directory/         → /path/to/directory/.dir.lock
```

---

## Lock Management Functions

### `kvdb_acquire_lock(file_path, lock_type, stale_timeout, acquire_timeout)`
**Purpose:** Acquire file or directory lock with retry and jitter

**Arguments:**
- `$1` file_path - Path to file or directory
- `$2` lock_type - "file" | "dir" | "both" (default: "file")
- `$3` stale_timeout - Seconds before lock considered stale (default: 5)
- `$4` acquire_timeout - Seconds to retry before giving up (default: 30)

**Behavior:**
1. Determine lock file path(s) based on lock_type
2. Loop with timeout:
   - Check for existing lock file
   - If exists:
     - Parse PID:EPOCH:HOSTNAME:FUNCTION
     - Check if process still alive: `kill -0 $PID 2>/dev/null`
     - Check age: `current_epoch - lock_epoch > stale_timeout`
     - If stale (dead process OR too old): remove lock
     - If valid: sleep 1s + random jitter (0-500ms), retry
   - If not exists: create lock file
   - Verify lock creation succeeded and contains our PID
   - Return success
3. After acquire_timeout: fail with error

**Lock File Content:**
```bash
echo "$$:$(date +%s):$(hostname):${FUNCNAME[2]}" > "$lockfile"
```

**Returns:**
- 0 on success
- 1 on timeout
- 2 on invalid arguments

**Logging:**
- debug: Each retry attempt
- warn: Removed stale lock (show previous owner details)
- error: Acquisition timeout

**Notes:**
- Not safe for NFS or network filesystems (add comment warning)
- Random jitter prevents thundering herd on lock contention

---

### `kvdb_release_lock(file_path, lock_type)`
**Purpose:** Release previously acquired lock

**Arguments:**
- `$1` file_path - Path to file or directory
- `$2` lock_type - "file" | "dir" | "both" (default: "file")

**Behavior:**
1. Determine lock file path(s)
2. For each lock file:
   - Verify exists
   - Read lock content
   - Parse PID from lock
   - If PID matches $$: remove lock file
   - If PID doesn't match: log warning (someone else's lock)
3. Return success if all locks released

**Returns:**
- 0 on success
- 1 if lock not found or not owned by current process

**Logging:**
- warn: Attempted to release lock not owned by us
- debug: Lock released successfully

---

## Basic KV Operations

### `kvdb_get(db_file, key)`
**Purpose:** Read value for a single key

**Arguments:**
- `$1` db_file - Path to config file
- `$2` key - Key name to retrieve

**Behavior:**
1. Validate db_file exists
2. Validate key format: `[A-Za-z_][A-Za-z0-9_]*`
3. Read file, find line matching `^KEY=`
4. Extract value, strip quotes
5. Output value to stdout

**Returns:**
- 0 if key found (outputs value)
- 1 if key not found or file doesn't exist

**Locking:** None (single atomic read)

**Notes:**
- Must handle both quoted and unquoted values
- Must handle escaped quotes in values

---

### `kvdb_set(db_file, key, value, lock_type, create_file)`
**Purpose:** Set or update a key-value pair

**Arguments:**
- `$1` db_file - Path to config file
- `$2` key - Key name
- `$3` value - Value to set
- `$4` lock_type - "file" | "dir" | "both" | "none" (default: "file")
- `$5` create_file - "true" | "false" (default: "true")

**Behavior:**
1. Validate key format
2. Check directory exists (fail if not)
3. If file doesn't exist and create_file="false": fail
4. If lock_type != "none": Acquire lock
5. If file doesn't exist: create with header
6. Read file into memory/temp
7. If key exists: replace line
8. If key doesn't exist: append line
9. Ensure value properly quoted and escaped
10. Write temp file
11. Atomic move: `mv -f tempfile db_file`
12. If lock_type != "none": Release lock

**Returns:**
- 0 on success
- 1 on lock failure
- 2 on write failure
- 3 on validation failure

**Value Quoting:**
- Always quote values: `KEY="value"`
- Escape embedded quotes: `"` → `\"`
- Escape backslashes: `\` → `\\`

---

### `kvdb_delete(db_file, key, lock_type)`
**Purpose:** Remove a key from config file

**Arguments:**
- `$1` db_file - Path to config file
- `$2` key - Key to remove
- `$3` lock_type - "file" | "dir" | "both" | "none" (default: "file")

**Behavior:**
1. Validate file exists
2. If lock_type != "none": Acquire lock
3. Read file, filter out lines matching `^KEY=`
4. Write to temp file
5. Atomic move
6. If lock_type != "none": Release lock

**Returns:**
- 0 on success (even if key didn't exist)
- 1 on lock failure
- 2 on write failure

---

### `kvdb_exists(db_file, key)`
**Purpose:** Check if key exists in file

**Arguments:**
- `$1` db_file - Path to config file
- `$2` key - Key name

**Behavior:**
1. Check file exists
2. grep for `^KEY=` in file

**Returns:**
- 0 if key exists
- 1 if key doesn't exist or file missing

**Locking:** None

---

## Scanning Operations (Directory Lock Required)

### `kvdb_scan(db_pattern, key, value_pattern)`
**Purpose:** Scan multiple files for matching key-value pairs

**Arguments:**
- `$1` db_pattern - Glob pattern (e.g., "hosts/*.conf")
- `$2` key - Key to search for ("*" for all keys)
- `$3` value_pattern - Pattern to match ("*" for any value)

**Behavior:**
1. Extract directory from pattern
2. Acquire directory lock
3. Expand glob pattern to file list
4. For each file:
   - If key="*": read all keys
   - Else: read specific key
   - If value_pattern matches: output "filename:key:value"
5. Release directory lock

**Returns:**
- 0 on success (outputs matches to stdout, one per line)
- 1 on lock failure

**Output Format:**
```
/path/to/file1.conf:IP:10.99.1.2
/path/to/file2.conf:IP:10.99.1.3
```

**TODO:**
- Support regex patterns on keys and values
- Add kvdb_list_keys(db_file) to enumerate all keys in one file
- Add kvdb_dump(db_file) for debugging/export

---

### `kvdb_scan_values(db_pattern, key)`
**Purpose:** Extract all values for a key across multiple files

**Arguments:**
- `$1` db_pattern - Glob pattern
- `$2` key - Key to extract values for

**Behavior:**
1. Extract directory from pattern
2. Acquire directory lock
3. Expand glob pattern
4. For each file: extract value for key
5. Output values (one per line)
6. Release directory lock

**Returns:**
- 0 on success
- 1 on lock failure

**Example:**
```bash
# Get all IPs
kvdb_scan_values "hosts/*.conf" "IP"
# Output:
10.99.1.2
10.99.1.3
10.99.1.4
```

---

### `kvdb_value_exists(db_pattern, key, value, exclude_file)`
**Purpose:** Check if a value exists anywhere in matched files

**Arguments:**
- `$1` db_pattern - Glob pattern
- `$2` key - Key name
- `$3` value - Value to search for
- `$4` exclude_file - File to exclude from search (optional, for update scenarios)

**Behavior:**
1. Extract directory from pattern
2. Acquire directory lock
3. Expand glob pattern
4. For each file (except exclude_file):
   - Check if key=value exists
   - If found: release lock, return 0
5. Release directory lock
6. Return 1 (not found)

**Returns:**
- 0 if value exists
- 1 if value not found
- 2 on lock failure

---

## Unique Value Operations

### `kvdb_insert_if_unique(db_pattern, target_db, key, value, lock_type)`
**Purpose:** Insert key-value only if value is unique across all files

**Arguments:**
- `$1` db_pattern - Pattern to scan for uniqueness (e.g., "hosts/*.conf")
- `$2` target_db - Specific file to write to (e.g., "hosts/12:34:56:78:9a:bc.conf")
- `$3` key - Key name (e.g., "IP")
- `$4` value - Proposed value (e.g., "10.99.1.5")
- `$5` lock_type - "file" | "dir" | "both" (default: "dir")

**Behavior:**
1. Extract directory from pattern
2. **Acquire directory lock** (critical for atomicity)
3. Call `kvdb_value_exists(db_pattern, key, value, target_db)`
4. If value exists in another file:
   - Release lock
   - Return failure
5. If value is unique:
   - Call `kvdb_set(target_db, key, value, "none", true)`
     - Note: "none" because dir lock already held
   - Release lock
   - Return success

**Returns:**
- 0 on success (value was unique and inserted)
- 1 on failure (value already exists elsewhere)
- 2 on lock failure
- 3 on write failure

**Use Cases:**
```bash
# Allocate unique IP
kvdb_insert_if_unique \
  "hosts/*.conf" \
  "hosts/${mac}.conf" \
  "IP" \
  "10.99.1.2" \
  "dir"

# Allocate unique hostname
kvdb_insert_if_unique \
  "hosts/*.conf" \
  "hosts/${mac}.conf" \
  "HOSTNAME" \
  "tch-001" \
  "dir"
```

**Notes:**
- Caller must generate candidate value
- Function only validates uniqueness and inserts
- Directory lock ensures no race conditions

---

### `kvdb_get_next_sequence(db_pattern, key, prefix)`
**Purpose:** Find next number in a sequence based on existing values

**Arguments:**
- `$1` db_pattern - Pattern to scan
- `$2` key - Key to examine (e.g., "HOSTNAME")
- `$3` prefix - Prefix to match (e.g., "tch-")

**Behavior:**
1. Acquire directory lock
2. Scan all files for key values
3. Filter values matching prefix
4. Extract numeric suffix from each
5. Find maximum number
6. Return max + 1
7. Release lock

**Returns:**
- 0 on success (outputs next number to stdout)
- 1 on lock failure

**Example:**
```bash
# Files contain: tch-001, tch-002, tch-004
next=$(kvdb_get_next_sequence "hosts/*.conf" "HOSTNAME" "tch-")
echo $next  # Outputs: 5
```

**Notes:**
- Handles zero-padded numbers (001, 002, etc.)
- Returns 1 if no existing values found
- Does NOT insert the value (caller must use kvdb_insert_if_unique)

---

## Index Management (Performance Optimization)

### `kvdb_index_build(db_pattern, key, index_file)`
**Purpose:** Build an index of key values for fast lookups

**Arguments:**
- `$1` db_pattern - Pattern to index
- `$2` key - Key to index
- `$3` index_file - Path to index file (e.g., ".index.ip")

**Behavior:**
1. Acquire directory lock
2. Scan all files matching pattern
3. Extract key values
4. Build index: `value -> filename` mapping
5. Write to index file atomically
6. Release lock

**Index File Format:**
```
# Auto-generated index for key: IP
# Generated: 2025-10-02 13:00:00
10.99.1.2=/path/to/host1.conf
10.99.1.3=/path/to/host2.conf
```

**Returns:**
- 0 on success
- 1 on failure

**TODO:** Implement index management
- kvdb_index_lookup(index_file, value) - Fast value lookup
- kvdb_index_invalidate(index_file) - Mark index stale
- kvdb_index_auto_update() - Rebuild if stale

---

### `kvdb_register_indexed_key(key)`
**Purpose:** Register a key to be automatically indexed

**Behavior:**
- Add key to list of indexed keys
- Automatically rebuild indexes when files change

**TODO:** Implement automatic index management

---

## Watch/Notification System

### `kvdb_watch(db_pattern, callback_function)`
**Purpose:** Monitor files for changes and trigger callback

**Arguments:**
- `$1` db_pattern - Pattern to watch
- `$2` callback_function - Function to call on change

**Behavior:**
- Use inotify or polling to detect changes
- Call callback with changed file path

**TODO:** Spec this out after file writes complete

Example use case: Wait for new unconfigured host to boot and automatically configure it.

---

## Helper Functions

### `kvdb_validate_key(key)`
**Purpose:** Validate key name format

**Validation Rules:**
- Must match: `^[A-Za-z_][A-Za-z0-9_]*$`
- Must be bash variable compatible
- Cannot be empty

**Returns:**
- 0 if valid
- 1 if invalid

---

### `kvdb_escape_value(value)`
**Purpose:** Properly escape value for config file

**Behavior:**
- Escape backslashes: `\` → `\\`
- Escape quotes: `"` → `\"`
- Return escaped value

---

### `kvdb_unescape_value(value)`
**Purpose:** Unescape value read from config file

**Behavior:**
- Remove surrounding quotes
- Unescape `\"`  → `"`
- Unescape `\\` → `\`

---

## Error Codes

```bash
KVDB_SUCCESS=0
KVDB_LOCK_TIMEOUT=1
KVDB_WRITE_FAILURE=2
KVDB_VALIDATION_ERROR=3
KVDB_NOT_FOUND=4
KVDB_ALREADY_EXISTS=5
```

---

## Usage Examples

### Basic Operations
```bash
# Set a value
kvdb_set "host.conf" "IP" "10.99.1.2"

# Get a value
ip=$(kvdb_get "host.conf" "IP")

# Delete a key
kvdb_delete "host.conf" "OLD_KEY"

# Check if key exists
if kvdb_exists "host.conf" "HOSTNAME"; then
  echo "Hostname configured"
fi
```

### Scanning
```bash
# Find all TCH hosts
kvdb_scan "hosts/*.conf" "TYPE" "TCH"

# Get all IPs
kvdb_scan_values "hosts/*.conf" "IP"

# Check if IP in use
if kvdb_value_exists "hosts/*.conf" "IP" "10.99.1.5"; then
  echo "IP already assigned"
fi
```

### Unique Allocation
```bash
# Try to allocate IP
if kvdb_insert_if_unique "hosts/*.conf" "hosts/${mac}.conf" "IP" "10.99.1.5"; then
  echo "IP allocated successfully"
else
  echo "IP already in use"
fi

# Get next hostname number
next_num=$(kvdb_get_next_sequence "hosts/*.conf" "HOSTNAME" "tch-")
hostname="tch-$(printf '%03d' $next_num)"

# Try to allocate hostname
kvdb_insert_if_unique "hosts/*.conf" "hosts/${mac}.conf" "HOSTNAME" "$hostname"
```

---

## Integration with Existing Functions

### host_config refactor
```bash
host_config "$mac" set "IP" "10.99.1.2"
  ↓
kvdb_set "$(get_host_conf_filename $mac)" "IP" "10.99.1.2" "file" "true"
```

### cluster_config refactor
```bash
cluster_config set "DHCP_IP" "10.99.1.1"
  ↓
kvdb_set "$(get_cluster_config_file)" "DHCP_IP" "10.99.1.1" "file" "true"
```

### host_network_configure refactor
```bash
# Instead of get_cluster_host_ips + manual checking
kvdb_insert_if_unique "hosts/*.conf" "hosts/${mac}.conf" "IP" "$candidate_ip"

# Instead of get_cluster_host_hostnames + manual checking
kvdb_insert_if_unique "hosts/*.conf" "hosts/${mac}.conf" "HOSTNAME" "$candidate_hostname"
```

---

## Testing Checklist

- [ ] Lock acquisition with retry and jitter
- [ ] Stale lock detection and removal
- [ ] Concurrent writes (race condition testing)
- [ ] Unique value validation across multiple files
- [ ] Directory vs file locking
- [ ] Proper quoting and escaping
- [ ] Missing file/directory handling
- [ ] Invalid key format rejection
- [ ] Lock cleanup on error
- [ ] Performance with many files

---

## Implementation Notes

- Indent 2 spaces
- Follow HPS function documentation standards
- Use `hps_log` for all logging
- All functions in `lib/functions.d/kvdb-functions.sh`
- Test each function individually before integration
- Backup is not required (rely on write operation logs)
- NFS/network filesystems are NOT supported (document this)

---

## Future Enhancements (TODO)

1. **Type validation** - Specify parameter types and re-validate (e.g., IP must be valid IP address)
2. **Query language** - Support complex queries like `TYPE=TCH AND STATE=CONFIGURED`
3. **Regex patterns** - Support regex on keys and values in scanning
4. **List/dump functions** - `kvdb_list_keys()`, `kvdb_dump()` for debugging
5. **Index management** - Automatic index building and maintenance
6. **Watch system** - File change notifications for auto-configuration