
__guard_source || return
# Define your functions below

configure_nginx () {

source $(get_active_cluster_filename 2>/dev/null)

# Paths

local NGINX_CONF="${HPS_SERVICE_CONFIG_DIR}/nginx.conf"

cat > "${NGINX_CONF}" <<EOF
worker_processes auto;
events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout  65;

    server {
        listen 80 default_server;
        server_name _;

        # Root directory for PXE HTTP content
        root ${HPS_HTTP};

        # iPXE menu files (e.g. /boot.ipxe, /menus/*.ipxe)
        location ~ \.ipxe\$ {
            default_type text/plain;
        }

        # Kickstart files
        location ~ \.ks\$ {
            default_type text/plain;
        }

        # CGI Bash scripts via fcgiwrap (e.g. /cgi-bin/host-config.sh)
        location /cgi-bin/ {
            gzip off;
            include /etc/nginx/fastcgi_params;
            fastcgi_pass unix:/var/run/fcgiwrap.socket;
            fastcgi_param SCRIPT_FILENAME ${HPS_HTTP}\$fastcgi_script_name;
            fastcgi_param DOCUMENT_ROOT ${HPS_HTTP};
        }

        # ISO trees (multiple distros/versions)
        location /distros/ {
            autoindex on;
            alias ${HPS_HTTP}/distros/;
        }

        # Default Rocky Linux ISO tree
        location /rocky/ {
            autoindex on;
            alias ${HPS_HTTP}/distros/rocky/;
        }

        # Text-based file types
        location ~* \.(cfg|conf|ks|ipxe|sh|txt|ini)\$ {
            default_type text/plain;
        }

        # Optional: logs directory (for debugging)
        location /logs/ {
            autoindex on;
            alias /var/log/nginx/;
        }
    }
}
EOF

echo "[OK] NGINX config generated at: ${NGINX_CONF}"

}
