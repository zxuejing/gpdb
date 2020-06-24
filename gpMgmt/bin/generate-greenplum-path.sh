#!/usr/bin/env bash

if [ -z "$1" ]; then
  printf "Must specify a value for GPHOME"
  exit 1
fi

GPHOME_PATH="$1"
cat <<EOF
GPHOME="${GPHOME_PATH}"

PYTHONHOME="${GPHOME}/ext/python"
PYTHONPATH="${GPHOME}/lib/python"
PATH="${GPHOME}/bin:${PYTHONHOME}/bin:${PATH}"
LD_LIBRARY_PATH="${GPHOME}/lib:${PYTHONHOME}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# openssl configuration file path
if [ -e "$GPHOME/etc/openssl.cnf" ]; then
	OPENSSL_CONF="$GPHOME/etc/openssl.cnf"
fi

export GPHOME
export PATH
export PYTHONHOME
export PYTHONPATH
export LD_LIBRARY_PATH
export OPENSSL_CONF
EOF
