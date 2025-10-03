

#===============================================================================
# n_display_info_before_prompt
# -----------------------------
# Display node information before login prompt or in console.
#
# Usage:
#   n_display_info_before_prompt
#
# Behaviour:
#   - If console login is enabled: shows info then prompt
#   - If console login is disabled: shows info and refreshes
#   - Can be called at end of boot sequence
#
# Returns:
#   0 on success
#===============================================================================
n_display_info_before_prompt() {
    n_remote_log "Displaying node information on console"
    
    # Check if getty is disabled
    local console_disabled=0
    if grep -q "hps-console-display" /etc/inittab 2>/dev/null || \
       grep -q "#.*getty" /etc/inittab 2>/dev/null || \
       ! grep -q "getty" /etc/inittab 2>/dev/null; then
        console_disabled=1
    fi
    
    if [[ ${console_disabled} -eq 1 ]]; then
        # Console is disabled - display will be handled by init respawn
        n_remote_log "Console is disabled - display will start via inittab"
        
        # Don't start it immediately - let boot messages show first
        return 0
    else
        # Console is enabled - show info before prompt
        # First, ensure n_node_information is available
        if ! command -v n_node_information >/dev/null 2>&1; then
            # Try to source it
            for f in /usr/local/bin/n_node_information /srv/*/n_node_information; do
                [[ -f "$f" ]] && . "$f" && break
            done
        fi
        
        # Create issue file that displays before login
        if command -v n_node_information >/dev/null 2>&1; then
            # Get node info without console-specific messages
            local node_info=$(n_node_information 2>/dev/null | grep -v "^Console access")
            
            cat > /etc/issue <<EOF

${node_info}

Alpine Linux \r on \l
EOF
        else
            # Fallback if function not available
            cat > /etc/issue <<EOF

HPS Node: $(hostname -f 2>/dev/null || hostname)
IP: $(ip addr show | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}')

Alpine Linux \r on \l
EOF
        fi
        
        # Make sure it's readable
        chmod 644 /etc/issue
        
        # Also display immediately on console
        cat /etc/issue >/dev/console 2>/dev/null
        
        n_remote_log "Created /etc/issue with node info"
    fi
    
    return 0
}

#===============================================================================
# n_configure_motd
# ----------------
# Configure message of the day to show node info after login.
#
# Usage:
#   n_configure_motd
#
# Returns:
#   0 on success
#===============================================================================
n_configure_motd() {
    n_remote_log "Configuring MOTD with node information"
    
    # Create a script that generates dynamic MOTD
    cat > /etc/profile.d/hps-motd.sh <<'EOF'
#!/bin/sh
# Display node information on login
if [ -n "$PS1" ] && command -v n_node_information >/dev/null 2>&1; then
    n_node_information 2>/dev/null
fi
EOF
    chmod +x /etc/profile.d/hps-motd.sh
    
    # Also create static MOTD
    n_node_information > /etc/motd 2>/dev/null
    
    n_remote_log "MOTD configured"
    return 0
}




#===============================================================================
# n_disable_getty_alpine
# ----------------------
# Disable getty on Alpine Linux by removing it from inittab.
#
# Usage:
#   n_disable_getty_alpine
#
# Behaviour:
#   - Removes getty entries from inittab
#   - Creates a custom service to show info on console
#   - Works with Alpine's OpenRC boot sequence
#
# Returns:
#   0 on success
#===============================================================================
n_disable_getty_alpine() {
    n_remote_log "Disabling getty on Alpine Linux"
    
    # Backup inittab
    cp /etc/inittab /etc/inittab.orig
    
    # Remove or comment getty lines
    sed -i '/getty/d' /etc/inittab
    
    # Add our custom console display instead
    echo "" >> /etc/inittab
    echo "# HPS Console Display" >> /etc/inittab
    echo "tty1::respawn:/usr/local/bin/hps-console-display" >> /etc/inittab
    
    # Create the console display script
    cat > /usr/local/bin/hps-console-display <<'EOF'
#!/bin/sh
# HPS Console Display
exec 0</dev/tty1 1>/dev/tty1 2>&1

# Wait a bit to let boot messages show
sleep 10

# Source node functions
for f in /usr/local/bin/n_*; do
    [ -f "$f" ] && . "$f"
done

# Clear any login prompts
clear

# Initial display
if command -v n_node_information >/dev/null 2>&1; then
    n_node_information
fi

# Main display loop
while true; do
    # Wait before refresh
    for i in $(seq 30 -1 1); do
        printf "\033[23;65H[Refresh: %2ds]\033[0m" "$i"
        sleep 1
    done
    
    # Refresh display
    if command -v n_node_information >/dev/null 2>&1; then
        n_node_information
    else
        clear
        echo "================================================================================"
        echo "                     HPS Node - Console Access Disabled"
        echo "================================================================================"
        echo ""
        echo "System is operational. Connect via network."
        echo ""
        hostname -f 2>/dev/null
        ip addr show | grep "inet " | grep -v "127.0.0.1"
        echo ""
    fi
done
EOF
    chmod +x /usr/local/bin/hps-console-display
    
    # Don't start the display immediately - let boot complete first
    # Tell init to reload
    kill -HUP 1
    
    n_remote_log "Getty disabled, console display configured"
    n_remote_log "Console display will start after getty respawn"
    
    # Remove the late startup script - not needed since inittab will handle it
    rm -f /etc/local.d/99-console-display.start
    
    return 0
}





