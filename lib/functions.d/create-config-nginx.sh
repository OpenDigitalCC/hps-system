
# Define your functions below

create_config_nginx () {
  # Load system paths
  source /srv/hps-config/hps.conf

  # Load cluster config into environment

  load_cluster_config

  # Paths
  local NGINX_CONF="$(get_path_cluster_services_dir)/nginx.conf"

  hps_log info "Configuring nginx"

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

    # API Bash scripts via fcgiwrap
    location /api/ {
#      root ${HPS_HTTP_STATIC_DIR}/api;
      gzip off;
      include /etc/nginx/fastcgi_params;
      fastcgi_pass unix:/var/run/fcgiwrap.socket;
      fastcgi_param SCRIPT_FILENAME ${HPS_HTTP_STATIC_DIR}/\$fastcgi_script_name;
      fastcgi_param DOCUMENT_ROOT ${HPS_HTTP_STATIC_DIR}/;
      fastcgi_param REDIRECT_STATUS 200;
    }

    # CGI Bash scripts via fcgiwrap
    location /cgi-bin/ {
#      root ${HPS_HTTP_CGI_DIR};
      gzip off;
      include /etc/nginx/fastcgi_params;
      fastcgi_pass unix:/var/run/fcgiwrap.socket;
      fastcgi_param SCRIPT_FILENAME ${HPS_HTTP_STATIC_DIR}/\$fastcgi_script_name;
      fastcgi_param DOCUMENT_ROOT ${HPS_HTTP_STATIC_DIR}/;
      fastcgi_param REDIRECT_STATUS 200;
    }

    # ISO trees (multiple distros/versions)
    location /distros/ {
      autoindex on;
      alias $(_get_distro_dir)/;
    }

    # Local package repo (multiple distros/versions)
    location /packages/ {
      autoindex on;
      alias ${HPS_PACKAGES_DIR}/;
    }

    location = /favicon.ico {
      access_log off;
     log_not_found off;
     return 204;
   }

  }
}
EOF

hps_log info "[OK] NGINX config generated at: ${NGINX_CONF}"

}
