
# make functions for tests of key operations
# such as cgi-param get/set etc, and cliuster conf, hostconf, restarts etc
# also test cgi functions as follows

#env QUERY_STRING="cmd=get_config&mac=525400123456" bash -x /srv/hps-system/http/cgi-bin/boot_manager.sh

env QUERY_STRING="mac=52540061c8c9&cmd=determine_state" bash -x /srv/hps-system/http/cgi-bin/boot_manager.sh

# then run test suite from here



