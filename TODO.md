
# To Do list

List of requirements and ideas not yet implemented


## ZFS

- add the multi disk 
- add clin to chose storgae config

## syslog

- Add syslog daemon to hps, send all messages to syslog
- add buffering on sending hosts
- Create standardised syslog tag structure, so messages can be managed accordingly
    - manage messages that are not tagged
- don't store local logs on machines
- add dhcp option to set syslog server

## time

- add time service to IPS

## DNS

- Add dns via dnsmasq to IPS

## create node by duplication

- zvol image duplication
- duplicate config file
- set key variables
- Create new host by duplicating zvol
- for thin compute nodes
- Implement function, available in ipxe and cli

## Security

- only send my config to my MAC address, decline to anyone else
- only send my cluster ifo to members of my cluster
- reject all queries from unknown MAC, with one exception
    - only allow initial config options to systems that we have dhcp booted


