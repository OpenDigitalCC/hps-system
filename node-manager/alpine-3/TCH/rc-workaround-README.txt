# Alpine Linux OpenRC Boot Sequence Workaround

## Problem Description

When Alpine Linux boots from network (iPXE) into a transient filesystem and runs initialization scripts from `/etc/local.d/`, there's a race condition where OpenRC services cannot be started normally during the boot sequence. This affects services with dependencies, particularly:

- `networking` service (even though network is already configured by iPXE)
- `dbus` service
- `libvirtd` service (depends on networking and dbus)

### Symptoms

```bash
rc-service networking start
# * WARNING: networking is already starting
# * ERROR: networking failed to start

rc-service libvirtd start  
# * ERROR: cannot start libvirtd as networking has not been started
```

## Root Cause

1. **Boot State Confusion**: During early boot (`/etc/local.d/` execution), OpenRC is in a transitional state where it believes services are "starting" but won't allow new services to start.

2. **iPXE Network Configuration**: Network is configured by iPXE kernel parameters before Alpine's init system runs, but OpenRC doesn't recognize this as the "networking" service being started.

3. **Dependency Chain Failure**: Services like libvirtd require networking to be marked as "started" in OpenRC's state tracking, even if the network is actually functional.

## Solution Overview

The workaround involves three key strategies:

1. **Force mark services as started** in OpenRC's state tracking
2. **Start daemons directly** bypassing rc-service
3. **Create required state files** manually

## Implementation Details

### 1. Force Network Service State (`n_force_network_started`)

```bash
# Clean any failed state
rc-service networking zap

# Create OpenRC state directories
mkdir -p /run/openrc/started

# Mark networking as started
touch /run/openrc/started/networking
```

**How it works:**
- `rc-service <service> zap` clears any stuck/failed state
- OpenRC tracks running services via files in `/run/openrc/started/`
- Creating `/run/openrc/started/networking` makes OpenRC believe networking is running
- This satisfies dependency checks for other services

### 2. Direct Daemon Startup (`n_force_start_services`)

Instead of using `rc-service`, start daemons directly:

```bash
# Start dbus directly
/usr/bin/dbus-daemon --system --fork --print-pid

# Start libvirtd directly  
/usr/sbin/libvirtd --daemon --pid-file=/var/run/libvirtd.pid

# Then mark as started for OpenRC
touch /run/openrc/started/dbus
touch /run/openrc/started/libvirtd
```

**How it works:**
- Bypasses OpenRC's state checking entirely
- Daemons start normally when invoked directly
- Manual state file creation keeps OpenRC's tracking consistent
- Future rc-service calls will see the service as running

### 3. Required Prerequisites

Before starting daemons directly, ensure prerequisites exist:

```bash
# For dbus
mkdir -p /var/run/dbus /var/lib/dbus
dbus-uuidgen > /var/lib/dbus/machine-id  # Required by dbus

# For libvirtd
mkdir -p /var/run/libvirt /var/log/libvirt /var/lib/libvirt
```

## Complete Workflow

1. **Configure network interface file** (`/etc/network/interfaces`)
2. **Bring up loopback** (`ip link set lo up`)
3. **Force mark networking as started**
4. **Install required packages** (qemu, libvirt, dbus)
5. **Start daemons directly** with required directories
6. **Mark services as started** in OpenRC

## Why This Works

- **OpenRC State Files**: OpenRC is file-based - it tracks service state through files in `/run/openrc/`. By creating these files manually, we convince OpenRC that services are running.

- **Direct Execution**: Linux daemons don't actually need init systems to run. Starting them directly bypasses init system restrictions while achieving the same result.

- **Transient Environment**: Since the filesystem is transient (resets on reboot), we don't worry about cleanup or persistent state - we just need services running for the current session.

## Alternative Approaches (Less Reliable)

1. **Sleep and Retry**: Wait for boot to complete, but unreliable in determining when "ready"
2. **Modify RC Scripts**: Edit `/etc/init.d/` scripts, but complex and fragile
3. **Custom Init Level**: Create custom runlevel, but doesn't solve the core timing issue

## Key Takeaways

- OpenRC's state tracking is file-based and can be manipulated
- Services can be started directly when rc-service fails
- Boot-time race conditions require creative workarounds in transient environments
- Always create required directories and files before starting daemons directly

This approach ensures services start reliably during network boot without modifying Alpine's init system or waiting for indeterminate periods.
