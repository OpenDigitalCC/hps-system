#!/bin/bash

n_remote_log () {
  logger -t osvc-build "$1"
}

get_src_dir () {
  echo "/srv/build/opensvc-om3"
#/srv/hps-resources/packages/src/opensvc-om3"
}

source 01-install-build-files.sh  
source 05-install-utils.sh  
source 10-build_opensvc.sh


