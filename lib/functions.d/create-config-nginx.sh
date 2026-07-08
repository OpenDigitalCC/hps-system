#===============================================================================
# create_config_nginx
# -------------------
# Generate nginx configuration file for HPS.
#
# Behaviour:
#   - Gets all paths via hps_get_config
#   - Creates nginx.conf in cluster services directory
#   - Configures HTTP server, CGI, and resource locations
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   create_config_nginx
#
#===============================================================================
create_config_nginx() {
  # Get paths via hps_get_config
  local cluster_services
  cluster_services=$(hps_get_config cluster_services) || {
    hps_log error "Cannot determine cluster services directory"
    return 1
  }
  
  local system_base
  system_base=$(hps_get_config system_base) || {
    hps_log error "Cannot determine system base directory"
    return 1
  }
  
  local resources
  resources=$(hps_get_config resources) || {
    hps_log error "Cannot determine resources directory"
    return 1
  }
  
  # Derived paths
  local http_config_dir="${system_base}/http"
  local http_static_dir="${system_base}/http"
  local distros_dir="${resources}/distros"
  local packages_dir="${resources}/packages"
  
  local nginx_conf="${cluster_services}/nginx.conf"
  
  hps_log info "Configuring nginx"

cat > "${nginx_conf}" <<EOF
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
    root ${http_config_dir}/;

    location / {
      # Root directory for HTTP content
      alias ${http_config_dir}/;
      # TODO: turn off autoindex
      autoindex on;
    }

    # API Bash scripts via fcgiwrap
    location /api/ {
      gzip off;
      include /etc/nginx/fastcgi_params;
      fastcgi_pass unix:/var/run/fcgiwrap.socket;
      fastcgi_param SCRIPT_FILENAME ${http_static_dir}/\$fastcgi_script_name;
      fastcgi_param DOCUMENT_ROOT ${http_static_dir}/;
      fastcgi_param REDIRECT_STATUS 200;
    }

    # CGI Bash scripts via fcgiwrap
    location /cgi-bin/ {
      gzip off;
      include /etc/nginx/fastcgi_params;
      fastcgi_pass unix:/var/run/fcgiwrap.socket;
      fastcgi_param SCRIPT_FILENAME ${http_static_dir}/\$fastcgi_script_name;
      fastcgi_param DOCUMENT_ROOT ${http_static_dir}/;
      fastcgi_param REDIRECT_STATUS 200;
    }

    # ISO trees (multiple distros/versions)
    location /distros/ {
      autoindex on;
      alias ${distros_dir}/;
    }

    # Local package repo (multiple distros/versions)
    location /packages/ {
      autoindex on;
      alias ${packages_dir}/;
    }

    location = /favicon.ico {
      access_log off;
      log_not_found off;
      return 204;
    }
  }
}
EOF

  hps_log info "NGINX config generated at: ${nginx_conf}"
  return 0
}
