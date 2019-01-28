#!/usr/bin/env python

import sys
from gppylib.db import dbconn

list_dbs_sql = '''
    select datname from pg_database
     where datallowconn and not datistemplate
'''

get_cluster_size_sql = '''
    select numsegments from gp_toolkit.__gp_number_of_segments
'''

scan_sql = '''
    select n.nspname, c.relname
      from gp_distribution_policy d
      join pg_class c on c.oid = d.localoid
      join pg_namespace n on n.oid = c.relnamespace
     where d.numsegments <> {cluster_size:d}
       and c.relstorage <> 'x'
'''

dburl = dbconn.DbURL()
conn = dbconn.connect(dburl)

cursor = dbconn.execSQL(conn, list_dbs_sql)
dbnames = [row[0] for row in cursor]
cursor.close()

cluster_size = int(dbconn.execSQLForSingleton(conn, get_cluster_size_sql))

conn.close()

print('scanning for partial tables...')
retval = 0
for dbname in dbnames:
    dburl = dbconn.DbURL(dbname=dbname)
    conn = dbconn.connect(dburl)

    cursor = dbconn.execSQL(conn, scan_sql.format(cluster_size=cluster_size))
    if cursor.rowcount > 0:
        retval = 1

    for row in cursor:
        print('- "{dbname}"."{namespace}"."{relname}"'.format(
            dbname=dbname.replace('"', '""'),
            namespace=row[0].replace('"', '""'),
            relname=row[1].replace('"', '""')))

    cursor.close()
    conn.close()

sys.exit(retval)
