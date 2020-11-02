#!/bin/bash

set -exo pipefail

CWDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TOP_DIR=${CWDIR}/../../../
source "${TOP_DIR}/gpdb_src/concourse/scripts/common.bash"
export PATH=/usr/bin:$PATH
gphome=/usr/local/greenplum-db-devel

function prepare_test() {
rm -f `which sudo`
yum install -y sudo patchelf
hash -r

#patch the runpath
patchelf --set-rpath /usr/local/greenplum-db-devel/lib /usr/local/greenplum-db-devel/bin/pg_autoctl
patchelf --set-rpath /usr/local/greenplum-db-devel/lib /usr/local/greenplum-db-devel/lib/postgresql/pgautofailover.so

pip3 install nose pyroute2
PATH=$gphome/bin:$PATH pip3 install psycopg2
echo "gpadmin ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

cat > /home/gpadmin/test.sh <<-EOF
#!/bin/bash

pushd $PWD/pg_auto_failover_src

. $gphome/greenplum_path.sh
TEST=single PGVERSION=12 make test

popd
EOF

chown gpadmin:gpadmin /home/gpadmin/test.sh
chmod a+x /home/gpadmin/test.sh
}
function run_test() {
    su gpadmin -c "bash /home/gpadmin/test.sh"
}

function _main() {
time install_gpdb
${TOP_DIR}/gpdb_src/concourse/scripts/setup_gpadmin_user.bash

time prepare_test
time run_test

}
_main
