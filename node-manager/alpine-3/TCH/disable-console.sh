



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





