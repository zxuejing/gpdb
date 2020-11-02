#!/bin/bash

if [ -z "${MASTER_DATADIR}" ]; then
  DATADIRS=${DATADIRS:-`pwd`/datadirs}
else
  DATADIRS="${MASTER_DATADIR}/datadirs"
fi

QDDIR=$DATADIRS/qddir/demoDataDir-1
STANDBYDIR=$DATADIRS/standby

# network split
# cauto1: 10.123.119.1  used by master node
# cauto2: 10.123.119.2  used by standby node
# cauto3: 10.123.119.3  used by monitor node
# default: 10.123.119.254 used by the segment nodes

function init_monitor() {
ip netns exec cauto3 su gpadmin -c bash <<EOF
. /usr/local/greenplum-db-devel/greenplum_path.sh
pg_autoctl create monitor --pgdata $DATADIRS/pgmonitor --pgport 7999 --auth trust --ssl-self-signed
pg_autoctl run --pgdata $DATADIRS/pgmonitor &
EOF
}
function init_M() {
su gpadmin -c bash <<EOF
# update gp_segment_configuration
. /usr/local/greenplum-db-devel/greenplum_path.sh
echo "QDDIR = '$QDDIR'"
echo "STANDBYDIR = '$STANDBYDIR'"
pg_ctl -D $QDDIR stop 2>/dev/null
pg_ctl -D $STANDBYDIR stop 2>/dev/null
postgres --single -D $QDDIR -O postgres <<GPEOF
update gp_segment_configuration set hostname='10.123.119.1', address='10.123.119.1' where dbid=1;
update gp_segment_configuration set hostname='10.123.119.2', address='10.123.119.2' where dbid=8;
GPEOF

sed -i 's/#hot_standby = off/hot_standby = on/' $QDDIR/postgresql.conf
sed -i 's/#hot_standby = off/hot_standby = on/' $STANDBYDIR/postgresql.conf
# coordinator and standby should be able to contact each other by the internal network IP
#echo "host all gpadmin 10.123.119.1/32 trust" >> $STANDBYDIR/pg_hba.conf
#echo "host all gpadmin 10.123.119.2/32 trust" >> $QDDIR/pg_hba.conf
#echo "hostssl all gpadmin 10.123.119.1/32 trust" >> $STANDBYDIR/pg_hba.conf
#echo "hostssl all gpadmin 10.123.119.2/32 trust" >> $QDDIR/pg_hba.conf
# the segments should be able to accept other nodes from 10.123.119.X
for((i=0;i<3;i++))
do
    echo "host all gpadmin 10.123.119.0/24 trust" >> $DATADIRS/dbfast$((i+1))/demoDataDir$((i))/pg_hba.conf
    echo "hostssl all gpadmin 10.123.119.0/24 trust" >> $DATADIRS/dbfast$((i+1))/demoDataDir$((i))/pg_hba.conf
    echo "host all gpadmin 10.123.119.0/24 trust" >> $DATADIRS/dbfast_mirror$((i+1))/demoDataDir$((i))/pg_hba.conf
    echo "hostssl all gpadmin 10.123.119.0/24 trust" >> $DATADIRS/dbfast_mirror$((i+1))/demoDataDir$((i))/pg_hba.conf
done
EOF
}

function config_M() {

pgdata=$QDDIR
#ip netns exec cauto1 su gpadmin --shell /usr/bin/bash -c bash <<MEOF
echo 'WTF #################'
echo "WTF #################"
. /usr/local/greenplum-db-devel/greenplum_path.sh
pg_ctl stop -D $pgdata 2>/dev/null
export PGDATA=$DATADIRS/pgmonitor
monitorURI=`/usr/local/greenplum-db-devel/bin/pg_autoctl show uri --pgdata $DATADIRS/pgmonitor --monitor`
echo monitor uri:$monitorURI
pg_autoctl create postgres --pgdata $pgdata --pgport 7000 --name pgm --monitor "$monitorURI" --auth trust --ssl-self-signed --gp_dbid 1 --gp_role dispatch
pg_autoctl run --pgdata $pgdata &
#MEOF
}


function config_S() {
pgdata=$STANDBYDIR
#ip netns exec cauto2 su gpadmin -c bash <<EOF
. /usr/local/greenplum-db-devel/greenplum_path.sh
pg_ctl stop -D $pgdata
export PGDATA=$DATADIRS/pgmonitor
#monitorURI=`pg_autoctl show uri --monitor`
monitorURI=`/usr/local/greenplum-db-devel/bin/pg_autoctl show uri --pgdata "$DATADIRS/pgmonitor" --monitor`
echo "monitor uri:'$monitorURI'"
pg_autoctl create postgres --pgdata $pgdata --pgport 7001 --name pgs --monitor "$monitorURI" --auth trust --ssl-self-signed --gp_dbid 8 --gp_role dispatch
pg_autoctl run --pgdata $pgdata &
#EOF

}

function init_nodes_ns() {
init_monitor
sleep 10
init_M
#config_M
}
function init_nodes() {
sed -i 's/#hot_standby = off/hot_standby = on/' $QDDIR/postgresql.conf
sed -i 's/#hot_standby = off/hot_standby = on/' $STANDBYDIR/postgresql.conf
MASTER_DATA_DIRECTORY=$QDDIR PGPORT=7000 gpstop -air

pg_autoctl create monitor --pgdata $DATADIRS/pgmonitor --pgport 7999 --auth trust --ssl-self-signed
pg_autoctl run --pgdata $DATADIRS/pgmonitor &

MPID=$!
sleep 10 # wait until the monitor is ready
echo "MPID = $MPID"

monitorURI=$(PGDATA=$DATADIRS/pgmonitor pg_autoctl show uri --monitor)

pgdata=$QDDIR
pg_ctl stop -D $pgdata
pg_autoctl create postgres --pgdata $pgdata --pgport 7000 --name pgm --monitor 'postgres://autoctl_node@localhost:7999/pg_auto_failover?sslmode=require' --auth trust --ssl-self-signed --gp_dbid 1 --gp_role dispatch
#echo 'hostssl "postgres" "gpadmin" localhost trust' >> $pgdata/pg_hba.conf
#echo 'hostssl all "pgautofailover_monitor" localhost trust' >>  $pgdata/pg_hba.conf
#echo 'host "postgres" "gpadmin" localhost trust' >> $pgdata/pg_hba.conf
#echo 'host all "pgautofailover_monitor" localhost trust' >>  $pgdata/pg_hba.conf
pg_autoctl run --pgdata $pgdata &
QPID=$!
echo "PID of the pg_autoctl in master = $QPID"

pg_ctl stop -D $STANDBYDIR
pg_autoctl create postgres --pgdata $STANDBYDIR --pgport 7001 --hostname localhost --name pgs --monitor 'postgres://autoctl_node@localhost:7999/pg_auto_failover?sslmode=require' --auth trust --ssl-self-signed --gp_dbid 8 --gp_role dispatch

# Add missing hba rules.
# hostssl "postgres" "gpadmin" localhost trust # Auto-generated by pg_auto_failover
# hostssl all "pgautofailover_monitor" localhost trust # Auto-generated by pg_auto_failover

pgdata=$STANDBYDIR
#echo 'hostssl "postgres" "gpadmin" localhost trust' >> $pgdata/pg_hba.conf
#echo 'hostssl all "pgautofailover_monitor" localhost trust' >>  $pgdata/pg_hba.conf
#echo 'host "postgres" "gpadmin" localhost trust' >> $pgdata/pg_hba.conf
#echo 'host all "pgautofailover_monitor" localhost trust' >>  $pgdata/pg_hba.conf
pg_autoctl run --pgdata $pgdata &
SPID=$!
echo "PID of the pg_autoctl in standby = $SPID"

sleep 1
# kill $QPID
wait $MPID
}

function start_cluster() {
su gpadmin -c bash <<EOF
. /usr/local/greenplum-db-devel/greenplum_path.sh
pkill -9 pg_autoctl 2>/dev/null
pg_ctl stop -D $DATADIRS/pgmonitor 2>/dev/null
pg_ctl stop -D $QDDIR 2>/dev/null
pg_ctl stop -D $STANDBYDIR 2>/dev/null

for((i=0;i<3;i++))
do
    pg_ctl -D $DATADIRS/dbfast$((i+1))/demoDataDir$i -o '-c gp_role=execute' start
    pg_ctl -D $DATADIRS/dbfast_mirror$((i+1))/demoDataDir$i -o '-c gp_role=execute' start
done

EOF
# start monitor
ip netns exec cauto3 su gpadmin -c bash <<EOF
. /usr/local/greenplum-db-devel/greenplum_path.sh
pg_autoctl run --pgdata $DATADIRS/pgmonitor &
EOF
sleep 5

# start coordinator & standby
ip netns exec cauto1 su gpadmin -c bash <<EOF
. /usr/local/greenplum-db-devel/greenplum_path.sh
pg_autoctl run --pgdata $QDDIR &
EOF
sleep 3

ip netns exec cauto2 su gpadmin -c bash <<EOF
. /usr/local/greenplum-db-devel/greenplum_path.sh
pg_autoctl run --pgdata $STANDBYDIR &
EOF

}

function stop_cluster() {
pkill -9 pg_autoctl 2>/dev/null
pkill postgres 2>/dev/null
pkill postgres 2>/dev/null
}
function restart_cluster() {
stop_cluster
start_cluster
}

case $1 in
	init_nodes)
		init_nodes_ns
		;;
    configm)
        config_M
        ;;
    configs)
        config_S
        ;;
    start)
        start_cluster
        ;;
    stop)
        stop_cluster
        ;;
    restart)
        restart_cluster
        ;;
	*)
		echo "??? $1"
		;;
esac
