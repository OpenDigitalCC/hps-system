# OpenSVC V3 Alpha Cheatsheet

**Version tested: v3.0.0-alpha87**

## Verified Commands & Patterns

### Basic Object Management

```bash
# Check version
om -v

# Monitor cluster status
om mon

# List nodes
om node ls

# List services
om svc ls

# List all objects
om all ls
```

### Service Management

#### Create Service
```bash
# Basic creation
om <service-name> create

# With keywords
om <service-name> create --kw <section>.<key>=<value>

# Example
om mysvc create --kw task#hello.type=host --kw task#hello.command="echo hello"
```

#### Service Operations
```bash
# View configuration
om <service-name> config show

# Delete service
om <service-name> delete

# View logs
om <service-name> logs

# View status
om <service-name> print status
```

### Task Resources

#### Create Task
```bash
# Basic task
om mysvc create \
  --kw task#name.type=host \
  --kw task#name.command="<command>"

# Source bash functions and execute
om mysvc create \
  --kw task#name.type=host \
  --kw task#name.command=". /path/to/functions.sh && my_function"
```

#### Run Tasks
```bash
# Run specific task
om <service-name> run --rid task#name

# Run on all nodes
om <service-name> run --rid task#name --node=\*

# Get session ID for tracking
# Output shows: OBJECT NODE SID
```

#### View Task Output
```bash
# View logs with session filter
om <service-name> log --filter SID=<session-id>

# Or use journalctl (local only)
journalctl SID=<session-id>
```

### Environment Variables Available in Tasks

Tasks automatically receive these environment variables:
```bash
OPENSVC_ACTION=run
OPENSVC_NAME=<service-name>
OPENSVC_SVCNAME=<service-name>
OPENSVC_KIND=svc
OPENSVC_SID=<session-id>
OPENSVC_ID=<object-id>
OPENSVC_LEADER=0|1
OPENSVC_SVCPATH=<service-path>
OPENSVC_RID=task#<name>
OPENSVC_NAMESPACE=root
```

### Sync Resources

#### Create Sync Resource
```bash
# Rsync between nodes
om mysvc create \
  --kw sync#name.type=rsync \
  --kw sync#name.src="/source/path" \
  --kw sync#name.dst="/dest/path"

# Provision sync
om mysvc provision --rid sync#name
```

**Note:** Sync resources distribute files FROM the node running the service TO other nodes. Single-node setups will show "no target nodes".

### Configmaps

#### Create and Manage Configmaps
```bash
# Create configmap (note: cfg/ prefix required)
om cfg/name create

# List configmaps
om cfg ls

# Add key to configmap
om cfg/name key add --name=filename.ext --value='content'

# Add key from file
om cfg/name key add --name=filename.ext --from=/path/to/file

# List keys
om cfg/name key list

# View key content
om cfg/name key decode --name=filename.ext

# Delete configmap
om cfg/name delete
```

#### Configmap Limitations in V3 Alpha
- The `configs` parameter in tasks does NOT currently expose configmap data as environment variables or files
- Configmap data is stored base64-encoded in `/etc/opensvc/cfg/<name>.conf` under `[data]` section
- **Workaround:** Use direct file paths or inline functions instead

### Naming Conventions

#### Valid Names
- Use hyphens (`-`), not underscores (`_`)
- Lowercase only
- Must comply with RFC952 (DNS naming rules)
- Examples: `my-service`, `test-functions`, `storage-mgmt`

#### Object Path Formats
- Services: `<name>` (no prefix)
- Configmaps: `cfg/<name>`
- Secrets: `sec/<name>` (assumed, not tested)
- Volumes: `vol/<name>` (assumed, not tested)

### Resource Section Naming
```bash
# Format: <type>#<name>
task#hello
sync#files
app#webserver
disk#data
```

## Working Patterns

### Pattern 1: Simple Task Execution
```bash
om test create \
  --kw task#hello.type=host \
  --kw task#hello.command="echo 'Hello from task'"

om test run --rid task#hello
```

### Pattern 2: Tasks with Bash Functions
```bash
# Create functions file on node(s)
cat > /opt/opensvc/functions.sh << 'EOF'
#!/bin/bash
my_function() {
    echo "Output from function"
}
EOF

# Create service
om mysvc create \
  --kw task#run.type=host \
  --kw task#run.command=". /opt/opensvc/functions.sh && my_function"

om mysvc run --rid task#run
```

### Pattern 3: Multi-Node Execution
```bash
# Create service with multiple nodes
om cluster-task create \
  --kw nodes="node1,node2,node3" \
  --kw task#check.type=host \
  --kw task#check.command="hostname; df -h"

# Run on all nodes
om cluster-task run --rid task#check --node=\*

# Returns SIDs for each node
# View specific node output
om cluster-task log --filter SID=<session-id>
```

### Pattern 4: File Distribution (When Multiple Nodes Exist)
```bash
# Create sync resource
om distribute create \
  --kw nodes="node1,node2" \
  --kw sync#files.type=rsync \
  --kw sync#files.src="/local/file.sh" \
  --kw sync#files.dst="/remote/file.sh"

# Provision to distribute
om distribute provision --rid sync#files

# Then use in tasks
om distribute create --kw task#run.type=host \
  --kw task#run.command=". /remote/file.sh && function_name"
```

## Known Limitations (V3 Alpha)

1. **Configmap Exposure:** `configs` parameter doesn't expose data to tasks
2. **Single Node Sync:** Sync resources need multiple nodes to function
3. **No Service Prefix:** Services use bare names, not `svc/<name>`
4. **Incomplete Documentation:** Many features undocumented in alpha

## Help Commands

```bash
# General help
om --help

# Subsystem help
om svc --help
om cfg --help
om node --help

# Command-specific help
om svc create --help
om cfg key add --help
```

## File Locations

```bash
# Service configs
/etc/opensvc/<service-name>.conf

# Configmap configs
/etc/opensvc/cfg/<name>.conf

# Service runtime data
/var/lib/opensvc/svc/<service-name>/

# Cluster config
/etc/opensvc/cluster.conf
/etc/opensvc/node.conf
```

---

**Note:** This cheatsheet is based on V3 alpha87 testing. Features and syntax may change before GA release.
