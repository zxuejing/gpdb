#!/bin/bash

DATADIRS=/home/gpadmin/datadirs
ipprefix='10.123.119'
sdbid=8
N=4

function prepareEnv() {
# assume network namespace is setup properly
# run as root
local vmdir=/home/gpadmin/VM
mkdir -p $vmdir
rm -rf $vmdir/*
for((i=1;i<=N;i++))
do
mkdir -p $vmdir/datadirs/node$i
mkdir -p $vmdir/config/node$i
mkdir -p $vmdir/local/node$i
mkdir -p $vmdir/tmp/node$i
done

chown gpadmin:gpadmin -R $vmdir
pkill -9 myinit 2>/dev/null
pkill -9 /usr/sbin/sshd
for((i=1;i<=N;i++))
do
ip netns exec cauto$i unshare -m  bash <<EOF
#!/bin/bash
set -exo
mount -B --make-private -o 'rw' $vmdir/datadirs/node$i     /home/gpadmin/datadirs/
mount -B --make-private -o 'rw' $vmdir/config/node$i       /home/gpadmin/.config
mount -B --make-private -o 'rw' $vmdir/local/node$i        /home/gpadmin/.local
mount -B --make-private -o 'rw' $vmdir/tmp/node$i          /tmp
/usr/sbin/sshd
#unshare -pf --mount-proc ./fakeinit &
exit 0
EOF
done
/usr/sbin/sshd
pkill unshare
}
function cleanDirs() {
rm -rf /tmp/.s* 2>/dev/null
rm -rf /tmp/pg_autoctl 2>/dev/null
rm -rf /home/gpadmin/.config/pg_autoctl 2>/dev/null
rm -rf /home/gpadmin/.local/share/pg_autoctl 2>/dev/null
rm -rf $DATADIRS/* 2>/dev/null
}
function destroyEnv() {
destroy
echo "destroy Env"
}

function initSegs() {
# init segments
. /usr/local/greenplum-db-devel/greenplum_path.sh
local pgdata=$DATADIRS
cleanDirs
initdb -kn -D $pgdata/node1 >/dev/null
cat >> $pgdata/node1/postgresql.conf <<CEOF
listen_addresses = '*'
unix_socket_directories = ''
CEOF

cat >> $pgdata/node1/pg_hba.conf <<CEOF
host all all $ipprefix.0/24 trust
host replication all $ipprefix.0/24 trust
CEOF

cp -r $pgdata/node1 $pgdata/node3
cp -r $pgdata/node1 $pgdata/node5
local idx=0
local dbid=3
local dbids=(2 3 4 5 6 7)
local content=(-1 0 0 1 1 2 2)
local ports=(7002 7003 7004 7005 7006 7007)

for((i=1;i<6;i+=2))
do
datadir="$pgdata/node$i"
datadir2="$pgdata/node$((i+1))"
port=${ports[idx]}
port2=${ports[idx+3]}
#
    echo "gp_contentid = $idx" >> "$datadir/postgresql.conf"
    echo "gp_dbid=${dbids[idx]}" > "$datadir/internal.auto.conf"
    pg_ctl -D $datadir -o "-p $port -c gp_role=execute" -l $datadir/logfile start
    pg_basebackup -X stream -R --target-gp-dbid ${dbids[idx+3]} -D "$datadir2" -d "postgres://$ipprefix.4:$port/postgres"
#
#    # update dbid, port
    echo "port = $port" >> "$datadir/postgresql.conf"
    echo "port = ${port2}" >> "$datadir2/postgresql.conf"
    echo "gp_dbid=${dbids[idx+3]}" > "$datadir2/internal.auto.conf"
#
    pg_ctl -D $datadir2 -o "-p $port2 -c gp_role=execute" -l $datadir2/logfile start
    echo "i = $idx"
    idx=$((idx+1))
done

}

function initM() {
. /usr/local/greenplum-db-devel/greenplum_path.sh
local pgdata=$DATADIRS
local segip="$ipprefix.4"
cleanDirs
initdb -kn -D $pgdata/nodeM >/dev/null
cat >> $pgdata/nodeM/postgresql.conf <<CEOF
hot_standby = on
listen_addresses = '*'
unix_socket_directories = ''
gp_contentid = -1
port = 7000
CEOF
echo "host all all $ipprefix.0/24 trust"  >> $pgdata/nodeM/pg_hba.conf
echo "host replication all $ipprefix.0/24 trust"  >> $pgdata/nodeM/pg_hba.conf
echo "gp_dbid = 1" > $pgdata/nodeM/internal.auto.conf

postgres --single -D $pgdata/nodeM -O postgres <<PQEOF
insert into gp_segment_configuration select i+2,i,'p','p','s','u',i+7002,'$segip','$segip','$pgdata/node'||(2*i+1) from generate_series(0,2)i
insert into gp_segment_configuration select i+5,i,'m','m','s','u',i+7005,'$segip','$segip','$pgdata/node'||(2*i+2) from generate_series(0,2)i
insert into gp_segment_configuration values(1,-1, 'p', 'p', 's', 'u',7000,'$ipprefix.1', '$ipprefix.1', '$pgdata/nodeM')
insert into gp_segment_configuration values($sdbid,-1,'m','m','s','u',7001,'$ipprefix.2', '$ipprefix.2', '$pgdata/nodeS')
PQEOF

pg_ctl -D $pgdata/nodeM -l $pgdata/nodeM/logfile -o "-p 7000 -c gp_role=dispatch" start

}

function initS() {
. /usr/local/greenplum-db-devel/greenplum_path.sh
local pgdata=$DATADIRS
cleanDirs
pg_basebackup -X stream -R --target-gp-dbid $sdbid -D $pgdata/nodeS -d postgres://$ipprefix.1:7000/postgres
echo "gp_dbid = $sdbid" > $pgdata/nodeS/internal.auto.conf
echo "port = 7001" >> $pgdata/nodeS/postgresql.conf
pg_ctl -D $pgdata/nodeS -l $pgdata/nodeS/logfile -o "-p 7001 -c gp_role=dispatch" start

}

function configMonitor() {
set -exo
. /usr/local/greenplum-db-devel/greenplum_path.sh
cleanDirs
pg_autoctl create monitor --pgdata $DATADIRS/pgmonitor --hostname $ipprefix.3 --pgport 7999 --auth trust --ssl-self-signed
cat >> $DATADIRS/pgmonitor/postgresql.conf <<CEOF
listen_addresses = '*'
#unix_socket_directories = ''
CEOF
setsid bash -c "pg_autoctl run --pgdata $DATADIRS/pgmonitor &"
exit 0
}

function configM() {
set -exo
local pgdata=$DATADIRS/nodeM
local monitorURI="$1"
configNode "$pgdata" 1 7000 pgm "$monitorURI" 1
}
# TODO: file system is not isolated.
# datadir_monitor
# datadir, host, port, name, dbid, AUTH-SSL

function configS() {
set -exo
local pgdata=$DATADIRS/nodeS
local monitorURI="$1"
configNode "$pgdata" 2 7001 pgs "$monitorURI" 8
}
function configNode() {
local pgdata="$1"
local index="$2"
local port="$3"
local name="$4"
local monitorURI="$5"
local dbid="$6"
. /usr/local/greenplum-db-devel/greenplum_path.sh
pg_ctl stop -D $pgdata
pg_autoctl create postgres --pgdata $pgdata --pgport $port --hostname $ipprefix.$index --pghost $ipprefix.$index --name $name --monitor "$monitorURI" --auth trust --ssl-self-signed --gp_dbid $dbid --gp_role dispatch
setsid bash -c "pg_autoctl run --pgdata $pgdata &"
exit 0
}
function destroy() {
pkill -SIGTERM pg_autoctl
pkill -SIGTERM postgres
for d in config local tmp datadirs
do
rm -rf /home/gpadmin/VM/$d/*/*
done
}

function startSegs() {
. /usr/local/greenplum-db-devel/greenplum_path.sh
for((i=1;i<=6;i++))
do
pg_ctl -D $DATADIRS/node$i -o "-c gp_role=execute" start
done
}
function stopSegs() {
local mode="$1"
. /usr/local/greenplum-db-devel/greenplum_path.sh
[[ -n "$mode" ]] && mode="-m $mode"
for((i=6;i>0;i--))
do
pg_ctl -D $DATADIRS/node$i $mode stop 2>/dev/null
done
}
function autoctlRun() {
local datadir="$1"
. /usr/local/greenplum-db-devel/greenplum_path.sh
# pg_ctl -D "$datadir" -o '-c gp_role=dispatch' start
setsid bash -c "pg_autoctl run --pgdata $datadir &"
}

$*
