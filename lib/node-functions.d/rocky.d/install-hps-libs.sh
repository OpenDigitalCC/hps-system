

echo "Loading functions from IPS"
curl -fsSL "http://ips/cgi-bin/boot_manager.sh?cmd=node_get_bootstrap_functions" >/usr/local/lib/hps-bootstrap-lib.sh

source /usr/local/lib/hps-bootstrap-lib.sh
hps_load_node_functions

