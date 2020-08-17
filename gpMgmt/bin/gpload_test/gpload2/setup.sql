DROP DATABASE IF EXISTS reuse_gptest;

CREATE DATABASE reuse_gptest;

\c reuse_gptest

CREATE SCHEMA test;

DROP EXTERNAL TABLE IF EXISTS temp_gpload_staging_table;
DROP TABLE IF EXISTS texttable;
DROP TABLE IF EXISTS csvtable;
CREATE TABLE texttable (
            s1 text, s2 text, s3 text, dt timestamp,
            n1 smallint, n2 integer, n3 bigint, n4 decimal,
            n5 numeric, n6 real, n7 double precision) DISTRIBUTED BY (n1);
CREATE TABLE csvtable (
	    year int, make text, model text, decription text, price decimal)
            DISTRIBUTED BY (year);
CREATE TABLE test.csvtable (
	    year int, make text, model text, decription text, price decimal)
            DISTRIBUTED BY (year);
create table testpk (n1 integer, s1 integer, s2 varchar(128), n2 integer, primary key(n1,s1,s2))
partition by range (s1)
 subpartition by list(s2)
 SUBPARTITION TEMPLATE
 ( SUBPARTITION usa VALUES ('usa'),
        SUBPARTITION asia VALUES ('asia'),
        SUBPARTITION europe VALUES ('europe'),
        DEFAULT SUBPARTITION other_regions)
(start (1) end (13) every (1),
default partition others)
;
