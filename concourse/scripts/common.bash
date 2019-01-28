#!/bin/bash -l

## ----------------------------------------------------------------------
## General purpose functions
## ----------------------------------------------------------------------

function set_env() {
    export TERM=xterm-256color
    export TIMEFORMAT=$'\e[4;33mIt took %R seconds to complete this step\e[0m';
}

## ----------------------------------------------------------------------
## Test functions
## ----------------------------------------------------------------------

function install_gpdb() {
    [ ! -d /usr/local/greenplum-db-devel ] && mkdir -p /usr/local/greenplum-db-devel
    tar -xzf bin_gpdb/bin_gpdb.tar.gz -C /usr/local/greenplum-db-devel
}

function setup_configure_vars() {
    # We need to add GPHOME paths for configure to check for packaged
    # libraries (e.g. ZStandard).
    source /usr/local/greenplum-db-devel/greenplum_path.sh
    export LDFLAGS="-L${GPHOME}/lib"
    export CPPFLAGS="-I${GPHOME}/include"
}

function configure() {
  source /opt/gcc_env.sh
  pushd gpdb_src
      # The full set of configure options which were used for building the
      # tree must be used here as well since the toplevel Makefile depends
      # on these options for deciding what to test. Since we don't ship
      # Perl on SLES we must also skip GPMapreduce as it uses pl/perl.
      if [ "$TEST_OS" == "sles" ]; then
        # TODO: remove this line as soon as the SLES image has zstd baked in
        CONFIGURE_FLAGS="${CONFIGURE_FLAGS} --without-zstd"
        ./configure --prefix=/usr/local/greenplum-db-devel --with-python --with-libxml --enable-orafce --disable-orca ${CONFIGURE_FLAGS}
      else
        ./configure --prefix=/usr/local/greenplum-db-devel --with-perl --with-python --with-libxml --enable-mapreduce --enable-orafce --enable-tap-tests --disable-orca ${CONFIGURE_FLAGS}
      fi
  popd
}

function install_and_configure_gpdb() {
  install_gpdb
  setup_configure_vars
  configure
}

# usage: gen_gpexpand_input <old_size> <new_size>
function gen_gpexpand_input() {
  local old="$1"
  local new="$2"
  local inputfile="/tmp/inputfile.${old}-${new}"
  local i

  for ((i=old; i<new; i++)); do
    cat <<EOF
$HOSTNAME:$HOSTNAME:$((25432+i*2)):$PWD/datadirs/expand/primary${i}:$((3+i*2)):${i}:p
$HOSTNAME:$HOSTNAME:$((25433+i*2)):$PWD/datadirs/expand/mirror${i}:$((4+i*2)):${i}:m
EOF
  done | tee $inputfile

  chmod a+r $inputfile
}

# extract PGOPTIONS from MAKE_TEST_COMMAND
function get_pgoptions() {
  local pgoptions

  cat >/tmp/get_pgoptions.mk <<"EOF"
$(info $(PGOPTIONS))
EOF

  pgoptions="$(eval make $MAKE_TEST_COMMAND -f /tmp/get_pgoptions.mk -nq 2>/dev/null)"
  echo "$pgoptions"
}

# detect for partial tables from all the non-template databases,
# exit code is 0 if no partial table is found, or 1 otherwise
function list_partial_tables() {
  local pgoptions="$(get_pgoptions)"

  su gpadmin -c bash <<EOF
. /usr/local/greenplum-db-devel/greenplum_path.sh
export PGOPTIONS='$pgoptions'
python $CWDIR/scan_partial_table.py
EOF
}

# usage: sort_dump < input_file > output_file
#
# filter and sort the 'INSERT INTO' lines of "pg_dumpall --inserts" output.
# will also append the database name to end of each line as comment.
function sort_dump() {
  sed -nrf "$CWDIR/filter_dump.sed" | sort
}

# usage: expand_cluster <old_size> <new_size>
function expand_cluster() {
  local old="$1"
  local new="$2"
  local inputfile="/tmp/inputfile.${old}-${new}"
  local pidfile="/tmp/postmaster.pid.${old}-${new}"
  local dump_before="/tmp/dump.${old}-${new}.before.sql"
  local dump_after="/tmp/dump.${old}-${new}.after.sql"
  local sorted_dump_before="/tmp/sorted-dump.${old}-${new}.before.sql"
  local sorted_dump_after="/tmp/sorted-dump.${old}-${new}.after.sql"
  local sorted_dump_diff="/tmp/sorted-dump.${old}-${new}.diff"
  local dbname="postgres"
  local pgoptions="$(get_pgoptions)"
  local retval=0
  local uncompleted

  pushd gpdb_src/gpAux/gpdemo

  gen_gpexpand_input "$old" "$new"

  # dump before expansion
  su gpadmin -c "pg_dumpall --inserts -Oxaf '$dump_before'"

  # Backup master pid, by checking it later we can know whether the cluster is
  # restarted during the tests.
  su gpadmin -c "head -n 1 $MASTER_DATA_DIRECTORY/postmaster.pid >$pidfile"
  # begin expansion
  su gpadmin -c "yes | PGOPTIONS='$pgoptions' gpexpand -s -i $inputfile"
  # redistribute tables
  su gpadmin -c "yes | PGOPTIONS='$pgoptions' gpexpand -s"
  # check the result
  uncompleted=$(su gpadmin -c "psql -Aqtd $dbname -c \"select count(*) from gpexpand.status_detail where status <> 'COMPLETED'\"")
  # cleanup
  su gpadmin -c "yes | PGOPTIONS='$pgoptions' gpexpand -s -c"
  su gpadmin -c "dropdb $dbname" 2>/dev/null || : # ignore failure

  # dump after expansion
  su gpadmin -c "pg_dumpall --inserts -Oxaf '$dump_after'"

  popd

  if [ "$uncompleted" -ne 0 ]; then
    echo "error: fail to expand some tables"
    retval=1
  fi

  # double check gp_distribution_policy.numsegments in every database
  if ! list_partial_tables; then
    echo "error: some tables are not expanded"
    retval=1
  fi

  echo "checking for data integration after expansion..."
  sort_dump < "$dump_before" > "$sorted_dump_before"
  sort_dump < "$dump_after" > "$sorted_dump_after"
  if diff -u0 "$sorted_dump_before" "$sorted_dump_after" >"$sorted_dump_diff"; then
    echo "before and after dumps have no difference"
  else
    echo "error: before and after dumps differ, here are part of the sorted diff:"
    head -n50 "$sorted_dump_diff"
    retval=1
  fi

  if [ "$retval" -eq 0 ]; then
    echo "all the tables are successfully expanded"
  fi

  return $retval
}

# usage: make_cluster [<demo_cluster_options>]
#
# demo_cluster_options are passed to `make create-demo-cluster` literally,
# any options accepted by that command are acceptable here.
#
# e.g. make_cluster WITH_MIRRORS=false
function make_cluster() {
  source /usr/local/greenplum-db-devel/greenplum_path.sh
  export BLDWRAP_POSTGRES_CONF_ADDONS=${BLDWRAP_POSTGRES_CONF_ADDONS}
  # Currently, the max_concurrency tests in src/test/isolation2
  # require max_connections of at least 129.
  export DEFAULT_QD_MAX_CONNECT=150
  export STATEMENT_MEM=250MB
  pushd gpdb_src/gpAux/gpdemo
  export MASTER_DATA_DIRECTORY=`pwd`"/datadirs/qddir/demoDataDir-1"
  su gpadmin -c "make create-demo-cluster $@"
  popd
}

function run_test() {
  # is this particular python version giving us trouble?
  ln -s "$(pwd)/gpdb_src/gpAux/ext/rhel6_x86_64/python-2.7.12" /opt
  su gpadmin -c "bash /opt/run_test.sh $(pwd)"
}
