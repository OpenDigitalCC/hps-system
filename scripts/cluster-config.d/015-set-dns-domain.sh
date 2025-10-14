#!/bin/bash
#===============================================================================
# 030-set-dns-domain.sh
# ---------------------
# Configuration fragment to set cluster DNS domain
#===============================================================================

cli_info "Configure DNS domain"

# Get current value with precedence
current_domain=$(config_get_value "DNS_DOMAIN" "cluster.local")

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
  
  [[ "$valid" == "true" ]] && break
done


cli_info "DNS domain set to: $dnsdomain"

# Store configuration
CLUSTER_CONFIG_PENDING+=("DNS_DOMAIN:$dnsdomain")
