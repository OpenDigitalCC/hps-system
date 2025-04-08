
__guard_source || return
# Define your functions below

configure_nginx () {

source $(get_active_cluster_filename 2>/dev/null)

# Paths

local NGINX_CONF="${HPS_SERVICE_CONFIG_DIR}/nginx.conf"

cat > "${NGINX_CONF}" <<EOF

worker_processes auto;
user www-data;
events {
  worker_connections 1024;
}

http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;
  sendfile      on;
  keepalive_timeout  65;
  access_log /dev/stdout;
  error_log /dev/stderr warn;

  server {
    listen 80 default_server;
    server_name _;
    root ${HPS_HTTP_CONFIG_DIR}/;
    
    # Text-based file types
#    location ~* \.(cfg|conf|ks|ipxe|sh|txt|ini)\$ {
#        default_type text/plain;
#    }

    location / {
    # Root directory for HTTP content
      alias ${HPS_HTTP_CONFIG_DIR}/;
# TODO: turn off autoindex
      autoindex on;
    }

    location /menu/ {
      alias ${HPS_MENU_CONFIG_DIR}/;
      default_type text/plain;
      autoindex on;
# TODO: turn off autoindex
#      autoindex off;
#      try_files \$uri =404;
    }

    location /hosts/ {
      alias ${HPS_HOST_CONFIG_DIR}/;
      default_type text/plain;
      autoindex on;
# TODO: turn off autoindex
#      autoindex off;
#      try_files \$uri =404;
    }


    # CGI Bash scripts via fcgiwrap
    location /cgi-bin/ {
      root ${HPS_HTTP_CGI_DIR};
      gzip off;
      include /etc/nginx/fastcgi_params;
      fastcgi_pass unix:/var/run/fcgiwrap.socket;
      fastcgi_param SCRIPT_FILENAME ${HPS_HTTP_STATIC_DIR}\$fastcgi_script_name;
      fastcgi_param DOCUMENT_ROOT ${HPS_HTTP_STATIC_DIR};
    }

    # ISO trees (multiple distros/versions)
    location /distros/ {
      autoindex on;
      alias ${HPS_HTTP_CONFIG_DIR}/distros/;
    }

    location = /favicon.ico {
      access_log off;
     log_not_found off;
     return 204;
   }

  }
}
EOF

echo "[OK] NGINX config generated at: ${NGINX_CONF} with root ${HPS_HTTP_CONFIG_DIR}"

}
