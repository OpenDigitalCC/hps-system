# HPS Network Topology Design

## Objectives and Intent

### Core Objectives

**Flexible Deployment Stages**
: Support deployment from simple single-NIC setups (testing/POC) through to production multi-NIC configurations without changing logical network definitions.

**Infrastructure Isolation**
: Separate HPS infrastructure networks (management, storage, VXLAN transport) from customer workload networks completely. Customer changes never impact HPS core systems.

**Multi-Host Customer Networks**
: Enable VMs and containers across different physical hosts to communicate on private customer networks without requiring switch VLAN configuration.

**Bootstrap-Friendly**
: Support diskless PXE boot while maintaining VLAN-based security model through rapid transition to tagged networks.

**Simplicity and Robustness**
: Minimize configuration complexity. Use standard Linux kernel features. Avoid proprietary protocols or complex control planes.

**Scalability**
: Start with minimal hardware for testing, expand to production-grade redundancy and performance without reconfiguration.

### Design Intent

The HPS network design uses **VLAN abstraction at the infrastructure level** combined with **VXLAN overlays for customer networks**. This creates a clear separation:

**HPS Infrastructure Networks**
: Predefined VLANs (10, 20, 31, 32+) for management, VXLAN transport, and storage, mapped to physical interfaces based on deployment profile.

**Customer Networks**
: VXLAN overlays (VNI 1000+) providing isolated layer-2 domains spanning all host types (KVM, Docker, physical).

The bootstrap problem (diskless PXE requiring untagged network) is solved through a rapid transition approach:

1. Initial PXE boot on untagged network (~3-7 seconds exposure)
2. iPXE chainload configures VLAN 10 for management
3. All subsequent provisioning and runtime operations on VLAN 10

This ensures:

- Infrastructure stability (core VLANs remain unchanged)
- Customer flexibility (add/modify customer networks independently)
- Progressive enhancement (add hardware without reconfiguration)
- Minimal untagged network exposure (seconds, not minutes)

---

## Network Architecture Overview

### Infrastructure Networks (HPS Core)

```
┌─────────────────────────────────────────────────────────────┐
│                    HPS Infrastructure                        │
│                                                              │
│  VLAN 10: Management Network (192.168.10.0/24)             │
│    - SSH, monitoring, provisioning                          │
│    - Cluster coordination                                   │
│    - 1Gbps sufficient for Profile 2+                          │
│                                                              │
│  VLAN 20: VXLAN Transport Network (10.20.0.0/24)           │
│    - VXLAN multicast traffic                                │
│    - Customer network encapsulation                         │
│    - Isolated from management                               │
│                                                              │
│  VLAN 31: Storage Network 1 (10.31.0.0/24)                 │
│    - iSCSI Target 1                                         │
│    - MTU 9000 (jumbo frames)                                │
│    - 10Gbps recommended                                     │
│                                                              │
│  VLAN 32: Storage Network 2 (10.32.0.0/24)                 │
│    - iSCSI Target 2                                         │
│    - MTU 9000 (jumbo frames)                                │
│    - 10Gbps recommended                                     │
│                                                              │
│  VLAN 33+: Additional Storage (10.33.0.0/24+)              │
│    - Scale storage capacity as needed                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### VLAN Numbering Scheme

**Reserved VLAN ranges to avoid:**

- VLAN 0: Reserved (priority tagging)
- VLAN 1: Default VLAN (avoid for security)
- VLAN 1002-1005: Reserved (Cisco legacy protocols)

**HPS VLAN allocation:**

VLAN 10
: Management (safe, commonly used)

VLAN 20
: VXLAN Transport (safe)

VLAN 31-99
: Storage networks (safe range, room for expansion)
  - 31: Storage 1
  - 32: Storage 2
  - 33-99: Additional storage hosts as needed

This numbering avoids all known reserved ranges and provides clear logical grouping.

### Customer Networks (VXLAN Overlays)

```
┌─────────────────────────────────────────────────────────────┐
│                   Customer Overlay Networks                  │
│         (Transported over VLAN 20 VXLAN Network)            │
│                                                              │
│  VNI 1000: Customer A Private (10.200.0.0/16)              │
│    - Multicast Group: 239.1.1.100                           │
│    - Spans: KVM hosts, Docker hosts                         │
│    - MTU 1450                                                │
│                                                              │
│  VNI 1001: Customer B Private (10.201.0.0/16)              │
│    - Multicast Group: 239.1.1.101                           │
│    - Isolated from Customer A                               │
│                                                              │
│  VNI 1002: Shared External Gateway (10.250.0.0/16)         │
│    - Multicast Group: 239.1.1.102                           │
│    - Firewall VMs provide internet access                   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Bootstrap Process

### The Challenge

Diskless hosts require network boot (PXE), but PXE firmware only supports untagged Ethernet. HPS runtime uses VLANs for security and isolation. This creates a bootstrap requirement.

### HPS Solution: Rapid VLAN Transition

```
Phase 1: Initial PXE (untagged, ~3-7 seconds)
┌─────────────────────────────────────────────┐
│ 1. Host NIC firmware initiates PXE          │
│ 2. DHCP request (untagged)                  │
│ 3. IPS responds: IP + iPXE bootloader       │
│ 4. Download iPXE binary (~100KB)            │
│ Duration: ~3-7 seconds total                │
└─────────────────────────────────────────────┘
         ↓
Phase 2: iPXE VLAN Configuration (~1-2 seconds)
┌─────────────────────────────────────────────┐
│ 5. iPXE executes embedded script:           │
│    - vcreate --tag 10 net0                  │
│    - dhcp net0-10                           │
│    - chain to boot_manager on VLAN 10       │
└─────────────────────────────────────────────┘
         ↓
Phase 3: Full Boot and Runtime (VLAN 10)
┌─────────────────────────────────────────────┐
│ 6. Download kernel, initrd from VLAN 10     │
│ 7. Boot OS with VLANs configured            │
│ 8. All provisioning on VLAN 10              │
│ 9. Runtime: VLAN 10, 20, 31, 32 active      │
└─────────────────────────────────────────────┘
```

**Untagged exposure: ~3-7 seconds**

**All runtime operations: VLAN-tagged**

### Bootstrap Security Modes

**Exploratory Mode (Default - Profile 1)**
: Untagged bootstrap enabled. Suitable for: Lab, testing, home, POC. Minimal security risk (seconds of exposure).

**Production Mode (Profile 2+)**
: Untagged bootstrap on dedicated 1Gb management NIC. Management traffic isolated from data networks. Suitable for: Production deployments.

**High Security Mode (Optional)**
: No untagged bootstrap allowed. Requires: Pre-configured switch with VLAN 10 as native VLAN or out-of-band management (IPMI) for initial configuration. Suitable for: Highly regulated environments.

---

## Deployment Stages

### Profile 1: Single NIC (Testing/POC)

**Hardware**: 1 x 10G NIC per host, any switch (managed or unmanaged)

**Purpose**: Lab environments, home use, initial testing, proof of concept

```
┌──────────────────────────────────────────┐
│            KVM/Thin Host                 │
│                                          │
│  ┌────────────────────────────────────┐ │
│  │      Physical NIC: eth0            │ │
│  │      10Gbps                         │ │
│  └────────────┬───────────────────────┘ │
│               │                          │
│  Bootstrap:   │                          │
│  eth0 (untagged) → iPXE → VLAN 10       │
│               │                          │
│  ┌────────────┴───────────────────────┐ │
│  │  Runtime Configuration:            │ │
│  │                                    │ │
│  │  eth0.10  - Management (1500 MTU) │ │
│  │  eth0.20  - VXLAN (1500 MTU)      │ │
│  │  eth0.31  - Storage 1 (9000 MTU)  │ │
│  │  eth0.32  - Storage 2 (9000 MTU)  │ │
│  │                                    │ │
│  │  VXLAN overlays on eth0.20        │ │
│  └────────────────────────────────────┘ │
│                                          │
└──────────────────────────────────────────┘
                 │
                 ↓
           [Any Switch]
```

**Characteristics**:

- All VLANs share single 10G interface
- Bootstrap: untagged (~3-7 seconds) → VLAN 10 transition
- Storage MTU 9000 (jumbo frames) on eth0.31, eth0.32
- Management/VXLAN MTU 1500 on eth0.10, eth0.20
- VXLAN multicast on eth0.20 (dedicated VLAN)
- Switch can be unmanaged for testing (inefficient but works)
- **Not performant - all traffic shares 10G - testing only**

**Switch Requirements**:

- None for unmanaged switch
- If managed: Trunk port with VLANs 10, 20, 31, 32 + allow untagged (bootstrap)

**Bootstrap Process**:

1. PXE boot (untagged) → iPXE
2. iPXE creates VLAN 10, gets IP
3. Downloads OS from VLAN 10
4. OS configures all VLANs (10, 20, 31, 32)

---

### Profile 2: Dual NIC (Production Entry)

**Hardware**:

- 1 x 1G NIC (management)
- 1 x 10G NIC (VXLAN + storage)
- 1-2 managed switches

**Purpose**: Production deployments with network isolation

```
┌────────────────────────────────────────────────────┐
│              KVM/Thin Host                         │
│                                                    │
│  ┌──────────────┐         ┌──────────────┐        │
│  │ Management   │         │  Data NIC    │        │
│  │ NIC: eth0    │         │  eth1        │        │
│  │ 1Gbps        │         │  10Gbps      │        │
│  └──────┬───────┘         └──────┬───────┘        │
│         │                        │                │
│  Bootstrap:                      │                │
│  eth0 (untagged) → iPXE → VLAN 10│                │
│         │                        │                │
│  ┌──────┴───────┐         ┌──────┴───────┐        │
│  │ Runtime:     │         │ Runtime:     │        │
│  │              │         │              │        │
│  │ eth0.10      │         │ eth1.20      │        │
│  │ Management   │         │ VXLAN        │        │
│  │ 192.168.10.x │         │ 10.20.0.x    │        │
│  │              │         │              │        │
│  │              │         │ eth1.31      │        │
│  │              │         │ Storage 1    │        │
│  │              │         │ 10.31.0.x    │        │
│  │              │         │              │        │
│  │              │         │ eth1.32      │        │
│  │              │         │ Storage 2    │        │
│  │              │         │ 10.32.0.x    │        │
│  │              │         │              │        │
│  │ MTU: 1500    │         │ MTU: 9000    │        │
│  └──────────────┘         │ (Storage)    │        │
│                           │ MTU: 1504    │        │
│                           │ (VXLAN)      │        │
│                           └──────────────┘        │
│                                                    │
└────────────────────────────────────────────────────┘
           │                        │
           ↓                        ↓
     [Switch A/B]             [Switch A/B]
```

**Physical Interface Assignment**:

eth0 (1Gb)
: Management only (VLAN 10). SSH, monitoring, provisioning. Low bandwidth requirements. Dedicated interface for administrative access.

eth1 (10Gb)
: Data networks (VLAN 20, 31, 32). VXLAN transport (VLAN 20). Storage networks (VLAN 31, 32) with jumbo frames. High bandwidth for data operations.

**Characteristics**:

- Management isolated on dedicated 1Gb NIC
- VXLAN and storage share 10Gb data NIC
- Bootstrap on eth0 (untagged → VLAN 10 transition)
- Storage networks: MTU 9000 (jumbo frames for iSCSI)
- VXLAN network: MTU 1504 (accommodates VXLAN overhead)
- Management network: MTU 1500
- Clear separation: management vs data

**Switch Requirements**:

- Trunk ports supporting VLANs 10, 20, 31, 32
- IGMP snooping on VLAN 20 (recommended for VXLAN efficiency)
- Jumbo frame support on data ports (MTU 9000+)
- Allow untagged on management port (bootstrap)

**Bootstrap Process**:

1. PXE boot from eth0 (untagged) → iPXE
2. iPXE creates eth0.10 (VLAN 10), gets IP
3. Downloads OS from VLAN 10
4. OS configures:
   - eth0.10 (management)
   - eth1.20 (VXLAN transport)
   - eth1.31, eth1.32 (storage)

---

### Profile 3: Dual NIC, Dual Switch (High Availability)

**Hardware**:

- 1 x 1G NIC (management)
- 1 x 10G NIC (VXLAN + storage)
- 2 independent switches

**Purpose**: Production with switch-level redundancy

```
┌────────────────────────────────────────────────────┐
│              KVM/Thin Host                         │
│                                                    │
│  ┌──────────────┐         ┌──────────────┐        │
│  │ Management   │         │  Data NIC    │        │
│  │ NIC: eth0    │         │  eth1        │        │
│  │ 1Gbps        │         │  10Gbps      │        │
│  └──────┬───────┘         └──────┬───────┘        │
│         │                        │                │
│  ┌──────┴───────┐         ┌──────┴───────┐        │
│  │ No bonding   │         │ No bonding   │        │
│  │ (optional    │         │ (optional    │        │
│  │  feature)    │         │  feature)    │        │
│  └──────┬───────┘         └──────┬───────┘        │
│         │                        │                │
│  ┌──────┴───────┐         ┌──────┴───────┐        │
│  │ eth0.10      │         │ eth1.20      │        │
│  │ eth0.31      │         │ eth1.31      │        │
│  │ eth0.32      │         │ eth1.32      │        │
│  └──────────────┘         └──────────────┘        │
│                                                    │
└────────────────────────────────────────────────────┘
           │                        │
      ┌────┴────┐             ┌────┴────┐
      ↓         ↓             ↓         ↓
  [Switch A] [Switch B]   [Switch C] [Switch D]
```

**Optional Bonding Configuration**:

Mode
: active-backup (no LACP required)

bond0
: eth0 connects to Switch A and B (management failover)

bond1
: eth1 connects to Switch C and D (data failover)

Failover
: Automatic upon link or switch failure

**Characteristics**:

- Switch-level redundancy (no single point of failure)
- Automatic failover if bonding used (typically <1 second)
- One active path per bond when bonding used (1G mgmt, 10G data)
- No switch coordination required (independent switches)
- Bonding optional - can run without for simpler configuration

**Switch Requirements**:

- Same as Profile 2
- Switches can be independent (no stacking/MC-LAG needed)
- If bonding used: same trunk configuration on both switches

---

### Profile 4: Quad NIC with LACP Bonding (Maximum Performance)

**Hardware**:

- 2 x 1G NICs (management bonding)
- 2 x 10G NICs (data bonding)
- 2 switches (can be independent)

**Purpose**: Production with bandwidth aggregation and redundancy

```
┌──────────────────────────────────────────────────────────┐
│                   KVM/Thin Host                          │
│                                                          │
│  ┌────────┐ ┌────────┐       ┌────────┐ ┌────────┐     │
│  │ eth0   │ │ eth1   │       │ eth2   │ │ eth3   │     │
│  │ 1Gbps  │ │ 1Gbps  │       │ 10Gbps │ │ 10Gbps │     │
│  └────┬───┘ └────┬───┘       └────┬───┘ └────┬───┘     │
│       └─────┬────┘                └─────┬────┘          │
│             │                           │               │
│        ┌────┴────┐                 ┌────┴────┐          │
│        │ bond0   │                 │ bond1   │          │
│        │ (LACP)  │                 │ (LACP)  │          │
│        │ 2Gbps   │                 │ 20Gbps  │          │
│        └────┬────┘                 └────┬────┘          │
│             │                           │               │
│        ┌────┴────┐                 ┌────┴────┐          │
│        │bond0.10 │                 │bond1.20 │          │
│        │Mgmt     │                 │VXLAN    │          │
│        │         │                 │bond1.31 │          │
│        │         │                 │Storage1 │          │
│        │         │                 │bond1.32 │          │
│        │         │                 │Storage2 │          │
│        └─────────┘                 └─────────┘          │
│                                                          │
└──────────────────────────────────────────────────────────┘
             │                           │
        ┌────┴────┐                 ┌────┴────┐
        ↓         ↓                 ↓         ↓
    [Switch A] [Switch B]       [Switch A] [Switch B]
    
Note: Can use same switches or separate switch pairs for each bond
```

**Bonding Configuration**:

Mode
: 802.3ad (LACP)

bond0
: eth0 + eth1 = 2Gbps aggregate (management). eth0 connects to Switch A, eth1 connects to Switch B.

bond1
: eth2 + eth3 = 20Gbps aggregate (VXLAN + storage). eth2 connects to Switch A (or Switch C), eth3 connects to Switch B (or Switch D).

Hash policy
: layer3+4 (IP + port based distribution)

**Characteristics**:

- Maximum bandwidth: 22Gbps total (2G management + 20G data)
- Link-level redundancy within each bond
- Switch-level redundancy (each bond spans two switches)
- Load balancing across links (per-flow)
- Works with independent switches using standard LACP

**Switch Requirements**:

- LACP/802.3ad support (standard feature on managed switches)
- Each switch independently configured with LACP
- No switch stacking or MC-LAG required
- Traffic distributed per-flow between switches

**Important**: Each bond operates independently with standard LACP on each switch. This is the base Profile 4 configuration and works with any LACP-capable managed switches.

---

### Optional Enhancement: MC-LAG for Profile 2+

**MC-LAG (Multi-Chassis Link Aggregation)** is an **optional enhancement** available for Profile 2, 3, or 4 when using advanced switches that support this feature.

MC-LAG allows two independent switches to coordinate and appear as a single logical switch for LACP purposes. This provides:

**Benefits over standard LACP**:

- Simpler host configuration (single bond instead of multiple independent bonds)
- Faster failover (sub-second vs 1-2 seconds)
- Active-active links (both links in bond actively used)
- No reconfiguration needed on switch failure

**Requirements**:

- Enterprise switches with MC-LAG capability
- Peer link between switches (high bandwidth)
- Vendor-specific configuration

**Tradeoffs**:

- More complex switch configuration
- Higher switch cost (enterprise feature)
- Vendor-specific setup

**Recommendation**: Start without MC-LAG using standard LACP (Profile 4 base configuration). This works with any LACP-capable managed switch and provides excellent redundancy and performance. Add MC-LAG later if you upgrade to enterprise switches with this capability and need sub-second failover for critical workloads.

---

## Storage Host Considerations

### Storage Host Network Configuration

Storage hosts (providing iSCSI targets) have similar but simplified networking:

```
┌────────────────────────────────────────────────────┐
│              Storage Host                          │
│                                                    │
│  ┌──────────────┐         ┌──────────────┐        │
│  │ Management   │         │  Storage NIC │        │
│  │ NIC: eth0    │         │  eth1        │        │
│  │ 1Gbps        │         │  10Gbps      │        │
│  └──────┬───────┘         └──────┬───────┘        │
│         │                        │                │
│  ┌──────┴───────┐         ┌──────┴───────┐        │
│  │ eth0.10      │         │ eth1.31      │        │
│  │ Management   │         │ Storage 1    │        │
│  │ 192.168.10.x │         │ 10.31.0.100  │        │
│  │              │         │ iSCSI target │        │
│  │              │         │ MTU: 9000    │        │
│  └──────────────┘         └──────────────┘        │
│                                                    │
│  No VXLAN network needed (not hosting VMs)        │
│                                                    │
└────────────────────────────────────────────────────┘
```

**VLANs used**:

- VLAN 10: Management (SSH, monitoring)
- VLAN 31: Storage network for this host's iSCSI target
- No VLAN 20 (VXLAN) - storage hosts don't participate in customer networks

**Each storage host uses one storage VLAN**:

- Storage Host 1: VLAN 31 (10.31.0.100)
- Storage Host 2: VLAN 32 (10.32.0.100)
- Storage Host 3: VLAN 33 (10.33.0.100)
- etc.

---

## VXLAN Customer Network Architecture

### Host-Level VXLAN Configuration

```
┌─────────────────────────────────────────────────────────────┐
│                      KVM/Docker Host                         │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                  │
│  │   VM1    │  │   VM2    │  │Container │                  │
│  │  eth0    │  │  eth0    │  │  eth0    │                  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                  │
│       └─────────────┼─────────────┘                         │
│                     │                                        │
│              ┌──────┴────────┐                               │
│              │ br-vxlan-1000 │  Linux Bridge                 │
│              └──────┬────────┘                               │
│                     │                                        │
│              ┌──────┴────────┐                               │
│              │  vxlan-1000   │  VXLAN Interface              │
│              │  VNI: 1000    │  - Multicast: 239.1.1.100    │
│              │  MTU: 1450    │  - Learning: enabled         │
│              └──────┬────────┘                               │
│                     │                                        │
│              ┌──────┴────────┐                               │
│              │   eth0.20     │  VXLAN Transport VLAN         │
│              │  (or eth1.20  │  (dedicated for VXLAN)        │
│              │   or bond.20) │                               │
│              └──────┬────────┘                               │
│                     │                                        │
│              ┌──────┴────────┐                               │
│              │  eth0/eth1/   │  Physical/Bonded Interface    │
│              │     bond      │                               │
│              └───────────────┘                               │
└─────────────────────────────────────────────────────────────┘
```

### Multi-Host VXLAN Communication

```
     KVM Host 1                       KVM Host 2
┌──────────────────┐           ┌──────────────────┐
│                  │           │                  │
│  VM1             │           │  VM2             │
│  MAC: aa:bb:cc:1 │           │  MAC: aa:bb:cc:2 │
│  IP: 10.200.1.10 │           │  IP: 10.200.1.20 │
│       │          │           │       │          │
│  ┌────┴────┐     │           │  ┌────┴────┐     │
│  │ Bridge  │     │           │  │ Bridge  │     │
│  └────┬────┘     │           │  └────┬────┘     │
│       │          │           │       │          │
│  ┌────┴────────┐ │           │  ┌────┴────────┐ │
│  │ vxlan-1000  │ │           │  │ vxlan-1000  │ │
│  │ VNI: 1000   │ │           │  │ VNI: 1000   │ │
│  │ Group:      │ │           │  │ Group:      │ │
│  │ 239.1.1.100 │ │           │  │ 239.1.1.100 │ │
│  └─────┬───────┘ │           │  └─────┬───────┘ │
│        │         │           │        │         │
│  ┌─────┴───────┐ │           │  ┌─────┴───────┐ │
│  │  eth0.20    │ │           │  │  eth0.20    │ │
│  │ (or eth1.20)│ │           │  │ (or eth1.20)│ │
│  │ 10.20.0.11  │ │           │  │ 10.20.0.12  │ │
│  └─────┬───────┘ │           │  └─────┬───────┘ │
└────────┼─────────┘           └────────┼─────────┘
         │                              │
         └──────────┬───────────────────┘
                    │
              ┌─────┴─────┐
              │  Switch   │
              │ (VLAN 20) │
              └───────────┘

Communication Flow:
1. VM1 sends to VM2 (10.200.1.20)
2. ARP: Multicast 239.1.1.100 → all VTEPs receive
3. VM2 responds, Host 1 learns MAC aa:bb:cc:2 at 10.20.0.12
4. Future frames: unicast encapsulation to 10.20.0.12
5. VXLAN overhead: 50 bytes (hence MTU 1450 for VMs)
```

### VXLAN Packet Encapsulation

```
Inside VM (payload):
┌──────────────────────────────────────────────┐
│ Ethernet Header (14 bytes)                   │
│  Dest MAC: aa:bb:cc:2                        │
│  Src MAC:  aa:bb:cc:1                        │
├──────────────────────────────────────────────┤
│ IP Header (20+ bytes)                        │
│  Dest IP: 10.200.1.20                        │
│  Src IP:  10.200.1.10                        │
├──────────────────────────────────────────────┤
│ TCP/UDP + Application Data                   │
└──────────────────────────────────────────────┘

After VXLAN encapsulation (on wire):
┌──────────────────────────────────────────────┐
│ Outer Ethernet (14 bytes)                    │
│  Dest MAC: Switch MAC                        │
│  Src MAC:  Host 1 eth0.20 MAC                │
├──────────────────────────────────────────────┤
│ Outer IP (20 bytes)                          │
│  Dest IP: 10.20.0.12 (Host 2 on VLAN 20)    │
│  Src IP:  10.20.0.11 (Host 1 on VLAN 20)    │
├──────────────────────────────────────────────┤
│ Outer UDP (8 bytes)                          │
│  Dest Port: 4789 (VXLAN standard)            │
│  Src Port:  Random (flow hash)               │
├──────────────────────────────────────────────┤
│ VXLAN Header (8 bytes)                       │
│  VNI: 1000                                   │
├──────────────────────────────────────────────┤
│ Inner Ethernet + IP + Data (original frame)  │
│  (Same as payload above)                     │
└──────────────────────────────────────────────┘

Total overhead: 50 bytes
VM MTU: 1500 - 50 = 1450 bytes
VXLAN transport VLAN 20 MTU: 1504 bytes (accommodates overhead)
```

**Key Point:** VXLAN traffic is isolated on VLAN 20, separate from management (VLAN 10) and storage (VLAN 31, 32). This provides clear traffic separation and allows independent QoS policies.

---

## MTU Configuration Strategy

### Per-Network MTU Settings

```
Network Layer                         MTU Setting
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Physical Interfaces (Profile 1):
├─ eth0                               1504 bytes

Physical Interfaces (Profile 2+):
├─ eth0 (management)                  1500 bytes
└─ eth1 (VXLAN + storage)             9000 bytes

Bonded Interfaces (Profile 3+):
├─ bond0 (management)                 1500 bytes
└─ bond1 (VXLAN + storage)            9000 bytes

VLAN Interfaces:
├─ vlan.10 (management)               1500 bytes
├─ vlan.20 (VXLAN transport)          1504 bytes
├─ vlan.31 (storage1)                 9000 bytes
├─ vlan.32 (storage2)                 9000 bytes
└─ vlan.33+ (additional storage)      9000 bytes

VXLAN Interfaces:
└─ vxlan-* (all customer VXLANs)      1450 bytes

Bridges:
├─ br-vxlan-* (customer bridges)      1450 bytes
└─ br-storage (if used)               9000 bytes

VM/Container Interfaces:
├─ Customer network VMs               1450 bytes
└─ Storage network VMs                9000 bytes
```

### Rationale

VLAN 20 (VXLAN transport): 1504
: Accommodates VXLAN overhead (50 bytes) while keeping customer VM MTU at 1450

VLAN 10 (Management): 1500
: Standard MTU, no special requirements

Storage VLANs (31, 32+): 9000
: Jumbo frames improve iSCSI performance (10-15% throughput gain, reduced CPU)

VXLAN interfaces: 1450
: Leaves headroom for encapsulation without fragmentation

Customer VMs: 1450
: Standard for internet connectivity, prevents fragmentation issues

---

## Switch Configuration Requirements

### Minimum Requirements (All Stages)

**VLAN Support**:

- Trunk port configuration
- Multiple VLANs per port (10, 20, 31, 32 minimum)
- Native VLAN handling (recommend unused VLAN for security)

**Frame Size**:

- Support for 1522+ byte frames (VLAN tagged)
- Support for 1608+ byte frames (VXLAN on VLAN 20)
- Jumbo frame support on storage ports (9000+ bytes)

### Profile 2+ Requirements

**IGMP Snooping** (recommended for VXLAN efficiency on VLAN 20):

Purpose
: Intelligent multicast forwarding

Without IGMP snooping
: Multicast flooded to all ports (works but inefficient)

With IGMP snooping
: Multicast only to interested ports

Configuration concept (vendor agnostic):

- Enable IGMP snooping globally
- Enable on VLAN 20 (VXLAN transport network)
- Optionally enable IGMP querier if no router present

**Port Configuration** (management network example):

```
Interface: Port connecting to host management NIC (eth0)
Mode: Trunk
Allowed VLANs: 10
Native VLAN: None (or unused VLAN 999)
Allow untagged: Yes (for bootstrap only, can be removed after)
MTU: 1600
```

**Port Configuration** (data network example):

```
Interface: Port connecting to host data NIC (eth1)
Mode: Trunk
Allowed VLANs: 20, 31, 32
MTU: 9216 (accommodates jumbo frames + overhead)
IGMP Snooping: Enabled (for VLAN 20)
Spanning Tree: Edge port (PortFast equivalent)
```

**Port Configuration** (storage host example):

```
Interface: Port connecting to storage host
Mode: Trunk
Allowed VLANs: 10, 31 (or 32, 33, etc.)
MTU: 9216
```

### Profile 4 Base Requirements (Standard LACP)

**Link Aggregation (LACP/802.3ad)**:

Purpose
: Bonding multiple links for bandwidth aggregation

Requirement
: Standard LACP support on managed switches

Configuration notes:

- Each switch independently configured
- No coordination between switches required
- Standard feature on managed switches
- Each bond member connects to different switch

**LAG Configuration Concept (per switch)**:

```
Port-Channel/LAG: lag1
Members: port1 (from this switch only)
Mode: LACP Active
Load Balance: src-dst-ip-port
Allowed VLANs: 10, 20, 31, 32
MTU: 9216

Note: Each switch has its own LAG config
Host bond spans both switches independently
```

### Vendor-Agnostic Configuration Checklist

**For all switches supporting HPS**:

- [ ] VLAN support with trunk ports
- [ ] MTU 1522+ on management ports
- [ ] MTU 1608+ on VXLAN transport ports (VLAN 20)
- [ ] MTU 9216+ on storage network ports (VLAN 31+)
- [ ] IGMP snooping available and enabled on VLAN 20
- [ ] Spanning tree configured (edge ports for host connections)
- [ ] Allow untagged traffic for bootstrap (can be removed after deployment)

**For Profile 4 base deployments**:

- [ ] LACP/802.3ad support (standard on managed switches)
- [ ] Per-switch LAG configuration
- [ ] No coordination between switches needed

**For Profile 4 with MC-LAG enhancement (optional)**:

- [ ] Switch stacking OR MC-LAG capability
- [ ] Peer link configuration between switches
- [ ] Coordinated LAG across switch pair

---

## Essential Configuration Commands

### Bootstrap: iPXE VLAN Transition Script

**Served to host during initial PXE boot:**

```ipxe
#!ipxe
# HPS Bootstrap Script - Transition to VLAN 10

echo ========================================
echo HPS Network Bootstrap
echo ========================================

echo Configuring management VLAN 10
vcreate --tag 10 net0 || goto failed

echo Requesting IP address on VLAN 10
dhcp net0-10 || goto failed

echo Management network configured
echo IP: ${net0-10/ip}
echo Gateway: ${net0-10/gateway}

echo Chainloading main boot manager
chain http://${next-server}/cgi-bin/boot_manager.sh?phase=main || goto failed

:failed
echo Bootstrap failed - dropping to iPXE shell
shell
```

### Host-Level VXLAN Setup

**Create VXLAN interface with multicast on VLAN 20:**

```bash
ip link add vxlan-cust-a type vxlan \
  id 1000 \
  dstport 4789 \
  group 239.1.1.100 \
  dev eth0.20 \
  ttl 5 \
  learning

# Note: dev eth0.20 (or eth1.20) - VXLAN on dedicated VLAN 20
```

**Create bridge and attach VXLAN:**

```bash
ip link add br-vxlan-cust-a type bridge
ip link set br-vxlan-cust-a type bridge stp_state 0
ip link set vxlan-cust-a master br-vxlan-cust-a
```

**Set MTU and bring up:**

```bash
ip link set vxlan-cust-a mtu 1450
ip link set br-vxlan-cust-a mtu 1450
ip link set vxlan-cust-a up
ip link set br-vxlan-cust-a up
```

**Verify multicast group membership:**

```bash
ip maddr show dev eth0.20 | grep 239.1.1.100
```

**Check learned MAC addresses:**

```bash
bridge fdb show dev vxlan-cust-a
```

### Bonding Configuration

**Active-backup bond (Profile 3)**:

```bash
ip link add bond0 type bond mode active-backup
ip link set bond0 type bond miimon 100 primary eth0
ip link set eth0 master bond0
ip link set eth1 master bond0
ip link set bond0 up
```

**LACP bond (Profile 4 base)**:

```bash
ip link add bond0 type bond mode 802.3ad
ip link set bond0 type bond miimon 100 lacp_rate fast xmit_hash_policy layer3+4
ip link set eth0 master bond0
ip link set eth1 master bond0
ip link set bond0 up
```

---

## Network Component Summary

The following components require configuration management functions. Each represents a distinct functional area for automation:

### 1. Bootstrap Manager

**Purpose**: Handle diskless PXE boot and rapid VLAN transition

**Responsibilities**:

- Serve DHCP responses for untagged bootstrap requests
- Provide iPXE bootloader binary
- Generate iPXE VLAN configuration script
- Detect bootstrap vs runtime phase
- Serve appropriate boot files per phase
- Log bootstrap attempts and transitions

**Key considerations**:

- Untagged phase exposure (~3-7 seconds)
- VLAN 10 transition via iPXE
- Security mode handling (exploratory/production/high)
- Fallback mechanisms if iPXE fails

---

### 2. Physical Interface Management

**Purpose**: Detect, configure, and manage physical NICs (eth0, eth1, etc.)

**Responsibilities**:

- Enumerate available physical interfaces
- Detect link speed and status (1G vs 10G)
- Set MTU on physical interfaces based on purpose
- Configure promiscuous mode if needed
- Handle interface state (up/down)
- Identify management vs data interfaces

**Key considerations**:

- Profile detection (how many NICs available?)
- 1G management, 10G data differentiation
- Validation of physical connectivity
- MTU requirements per profile and purpose

---

### 3. VLAN Interface Management

**Purpose**: Create and manage 802.1Q VLAN interfaces on physical or bonded interfaces

**Responsibilities**:

- Create VLAN interfaces (vlan.10, vlan.20, vlan.31, vlan.32+)
- Map VLANs to physical interfaces based on deployment profile
- Set MTU on VLAN interfaces (1500 mgmt, 1504 VXLAN, 9000 storage)
- Handle VLAN interface lifecycle
- Validate VLAN tag configuration

**Key considerations**:

- Profile-specific VLAN-to-interface mapping
- Infrastructure VLANs (10, 20, 31, 32+) are predefined
- VLAN 10: Management
- VLAN 20: VXLAN transport (dedicated)
- VLAN 31+: Storage networks (one per storage host)
- MTU inheritance and override per VLAN purpose

---

### 4. Bonding/Link Aggregation Management

**Purpose**: Create and manage bonded interfaces for redundancy and bandwidth aggregation

**Responsibilities**:

- Create bond interfaces (bond0, bond1)
- Configure bonding mode (active-backup, 802.3ad)
- Add/remove slave interfaces
- Set bonding parameters (miimon, lacp_rate, xmit_hash_policy)
- Monitor bond status and failover
- Handle primary interface selection

**Key considerations**:

- Profile 3 uses active-backup (no switch dependency)
- Profile 4 uses 802.3ad/LACP (standard managed switch feature)
- Separate bonds for management and data
- Failover detection and recovery
- MC-LAG is optional enhancement (not required)

---

### 5. Bridge Management

**Purpose**: Create and manage Linux bridges for VM/container attachment

**Responsibilities**:

- Create bridge interfaces
- Configure bridge parameters (STP state, filtering)
- Attach interfaces to bridges (VLAN, VXLAN)
- Set MTU on bridges
- Manage bridge FDB (forwarding database)

**Key considerations**:

- Bridges for VXLAN customer networks
- Optional bridges for storage networks
- STP disabled for VXLAN bridges (no loops with VXLAN)
- MTU matching underlying interfaces

---

### 6. VXLAN Interface Management

**Purpose**: Create and manage VXLAN tunnel endpoints (VTEPs)

**Responsibilities**:

- Create VXLAN interfaces with VNI assignment
- Configure multicast groups
- Set VXLAN parameters (dstport, ttl, learning)
- Attach VXLAN to VLAN 20 transport interface
- Set MTU (1450) on VXLAN interfaces
- Monitor VXLAN FDB and remote VTEPs

**Key considerations**:

- VNI allocation per customer network
- Multicast group assignment (one per VNI)
- Transport over VLAN 20 (dedicated VXLAN transport VLAN)
- VLAN 20 on appropriate physical interface (eth0.20, eth1.20, or bond.20)
- MAC learning enabled for automatic peer discovery
- Isolation from management and storage traffic

---

### 7. IP Address Management

**Purpose**: Assign and manage IP addresses on interfaces

**Responsibilities**:

- Assign static IPs to infrastructure interfaces
- Configure subnet masks and network parameters
- Set default routes if needed
- Handle IP address conflicts
- Manage IP address pools for allocation
- Track bootstrap vs runtime IP assignments

**Key considerations**:

- Bootstrap network: 192.168.100.0/24 (untagged, temporary)
- Management network: 192.168.10.0/24 (VLAN 10)
- VXLAN transport: 10.20.0.0/24 (VLAN 20)
- Storage networks: 10.31.0.0/24, 10.32.0.0/24, etc. (VLAN 31+)
- Customer networks: 10.200.0.0/16+ (VXLAN overlays)
- Per-host IP assignments from registry

---

### 8. Routing and Policy Configuration

**Purpose**: Configure routing tables and policy routing

**Responsibilities**:

- Set default routes (if needed)
- Configure source-based routing (if multiple networks)
- Ensure storage traffic uses correct interface
- Ensure VXLAN traffic uses VLAN 20
- Prevent unwanted cross-network routing
- Configure IP forwarding state

**Key considerations**:

- Typically no routing needed (all services local)
- Disable IP forwarding unless host is router/firewall
- Firewall rules to prevent customer-to-infrastructure access
- Separate management, VXLAN, and storage paths

---

### 9. Multicast Configuration

**Purpose**: Enable and configure multicast support for VXLAN

**Responsibilities**:

- Enable multicast reception on VLAN 20 interfaces
- Configure IGMP parameters
- Join multicast groups (automatic via VXLAN, but validate)
- Monitor multicast group membership
- Handle multicast routing settings if needed

**Key considerations**:

- Required for VXLAN multicast mode on VLAN 20
- IGMP version compatibility
- Multicast TTL settings
- IGMP snooping on switches (VLAN 20)

---

### 10. MTU Management

**Purpose**: Configure Maximum Transmission Unit across network stack

**Responsibilities**:

- Set MTU on physical interfaces based on purpose
- Propagate MTU to VLAN interfaces
- Set appropriate MTU on VXLAN interfaces (1450)
- Configure MTU on VLAN 20 (1504 for VXLAN overhead)
- Configure MTU on storage VLANs (9000 for jumbo frames)
- Validate MTU path between hosts

**Key considerations**:

- Profile 1: 1504 on eth0 (accommodates all traffic)
- Profile 2+: 1500 on management NIC, 9000 on data NIC
- VLAN 10 (management): 1500
- VLAN 20 (VXLAN transport): 1504
- VLAN 31+ (storage): 9000
- VXLAN interfaces: 1450 (accounting for 50-byte overhead)
- Path MTU discovery testing

---

### 11. Network Validation and Testing

**Purpose**: Verify network configuration correctness and connectivity

**Responsibilities**:

- Validate interface state (up/down, link speed)
- Test VLAN connectivity between hosts
- Verify VXLAN tunnel establishment on VLAN 20
- Check multicast group membership
- Test MTU end-to-end (ping with DF flag)
- Validate bridge FDB learning
- Monitor for errors/drops
- Verify bootstrap to runtime transition

**Key considerations**:

- Pre-deployment validation
- Bootstrap phase verification
- VLAN 10 management connectivity
- VLAN 20 VXLAN multicast functionality
- Storage VLAN (31+) jumbo frame support
- Continuous health monitoring
- Troubleshooting support
- Performance metrics collection

---

### 12. Network Registry/Configuration Management

**Purpose**: Store and manage network definitions and host assignments

**Responsibilities**:

- Define logical networks (management, VXLAN transport, storage)
- Map networks to VLANs (10, 20, 31+)
- Assign VNI numbers to customer networks
- Store per-host interface assignments
- Track IP address allocations
- Store multicast group assignments
- Maintain deployment profile configuration
- Track bootstrap security mode

**Key considerations**:

- Central source of truth for network config
- VLAN numbering scheme (10, 20, 31+)
- Storage VLAN allocation (one per storage host)
- VXLAN on dedicated VLAN 20
- Version control of network definitions
- Cluster-specific configurations
- Customer network isolation mappings
- Bootstrap mode configuration

---

### 13. VM/Container Network Attachment

**Purpose**: Attach VMs and containers to customer network bridges

**Responsibilities**:

- Configure libvirt/KVM network definitions
- Attach VM interfaces to specific bridges
- Create veth pairs for container attachment
- Set MAC addresses
- Configure MTU on VM/container interfaces (1450 for VXLAN networks)
- Handle hot-plug/unplug if needed

**Key considerations**:

- Libvirt XML generation
- Docker network integration
- Customer network isolation enforcement
- MAC address management
- MTU settings (1450 for customer VMs on VXLAN)

---

## Integration Points

These components interact as follows:

```
Bootstrap Manager
      ↓
Physical Interface
      ↓
   Bonding (optional, Profile 3+4)
      ↓
   VLAN Interface
      ↓
   ┌───────────┴─────────────┐
   ↓                         ↓
Management (VLAN 10)    Data Networks
                             ↓
                        ┌────┴────┐
                        ↓         ↓
                   VXLAN (20)  Storage (31+)
                        ↓
                   VXLAN Interface
                        ↓
                   Bridge (customer network)
                        ↓
                   VM/Container attachment
```

Each component should be implemented as independent, testable functions that can be composed to build the complete network stack based on the deployment profile.

---

## Deployment Profile Decision Matrix

```
Available Hardware            Recommended Profile      Management NIC
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1 NIC per host               Profile 1 (Testing only) Shared 10G
Any switch                   No switch config       Bootstrap: untagged
                                                    Runtime: VLAN 10

1G + 10G NIC per host        Profile 2 (Production)   Dedicated 1G
1 managed switch             Configure VLANs        Bootstrap: untagged
                             IGMP snooping          Runtime: VLAN 10

1G + 10G NIC per host        Profile 3 (HA)           Dedicated 1G
2 independent switches       Configure VLANs        Optional bonding
                             Optional bonding       Bootstrap: untagged

2x1G + 2x10G per host        Profile 4 (Max perf)     Bonded 2x1G
2 switches with LACP         LACP bonding           Bootstrap: untagged
                             VLANs + LAG            Runtime: bond.10
```

### VLAN Usage Summary by Profile

**Profile 1 (Single 10G NIC)**:

- VLAN 10: Management (eth0.10)
- VLAN 20: VXLAN transport (eth0.20)
- VLAN 31: Storage 1 (eth0.31)
- VLAN 32: Storage 2 (eth0.32)

**Profile 2 (1G mgmt + 10G data)**:

- VLAN 10: Management (eth0.10) - on 1G NIC
- VLAN 20: VXLAN transport (eth1.20) - on 10G NIC
- VLAN 31: Storage 1 (eth1.31) - on 10G NIC
- VLAN 32: Storage 2 (eth1.32) - on 10G NIC

**Profile 3 (with optional bonding)**:

- Same as Profile 2, but interfaces may be bonded
- VLAN 10: Management (bond0.10)
- VLAN 20: VXLAN transport (bond1.20)
- VLAN 31: Storage 1 (bond1.31)
- VLAN 32: Storage 2 (bond1.32)

**Profile 4 (full bonding)**:

- VLAN 10: Management (bond0.10) - on 2x1G bonded
- VLAN 20: VXLAN transport (bond1.20) - on 2x10G bonded
- VLAN 31: Storage 1 (bond1.31) - on 2x10G bonded
- VLAN 32: Storage 2 (bond1.32) - on 2x10G bonded

Each profile builds upon the same logical network definitions (VLANs 10, 20, 31, 32+), differing only in physical interface mapping and redundancy features. This allows progressive hardware enhancement without reconfiguring the logical network layer.
