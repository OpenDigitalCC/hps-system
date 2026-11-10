#!/bin/bash
#===============================================================================
# 030-set-dns-domain.sh
# ---------------------
# Configuration fragment to set cluster DNS domain
#===============================================================================

cli_info "Configure DNS domain"

# Get current value with precedence
current_domain=$(config_get_value "network_dns_domain" "cluster.local")

# Explain DNS domain usage
cli_note "Hosts will be known as <hostname>.<dnsdomain>"
cli_note "Example: node01.cluster.local or node01.cluster"

# DNS domain validation regex
dns_domain_regex="^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?))*$"




# Prompt for DNS domain
while true; do
  dnsdomain=$(cli_prompt "Enter DNS domain name for this cluster" "$current_domain" "$dns_domain_regex" \
    "Invalid domain: must be valid DNS format (e.g., local, cluster.local, prod.example.com)")
  
  # Check if empty (user pressed enter with no input and no default)
  if [[ -z "$dnsdomain" ]]; then
    hps_log "error" "DNS domain cannot be empty"
    continue
  fi
  
  # Additional validation - check label length
  valid=true
  IFS='.' read -ra labels <<< "$dnsdomain"
  for label in "${labels[@]}"; do
    if [[ ${#label} -gt 63 ]]; then
      hps_log "error" "DNS label '$label' too long (max 63 characters)"
      valid=false
      break
    fi
  done
  
  # One hostname rule (docs/NAMING.md): node FQDNs <name>.<domain> must stay
  # within 63 characters (om3 node names); 10 are kept for the name.
  if [[ ${#dnsdomain} -gt 52 ]]; then
    hps_log "error" "DNS domain '$dnsdomain' is ${#dnsdomain} characters; at most 52 so node FQDNs stay within 63"
    valid=false
  fi

  [[ "$valid" == "true" ]] && break
done


cli_info "DNS domain set to: $dnsdomain"

# Store configuration
CLUSTER_CONFIG_PENDING+=("network_dns_domain:$dnsdomain")
