--
-- Validate GPDB can create unique index on a table created in utility mode
--
-- NOTICE: we must connect to master in utility mode because the oid of table is
-- preassigned in QD, if we create a table in utility mode in QE, the oid might
-- conflict with preassigned oid.
-1U: create table utilitymode_primary_key_tab (c1 int);
-1U: create unique index idx_utilitymode_c1 on utilitymode_primary_key_tab (c1);
-1U: drop table utilitymode_primary_key_tab;

0U: explain analyze select * from gp_segment_configuration order by dbid;

--
-- Temp tables should have a different schema name pattern in utility mode.
--
-- A temp table's schema name used to be pg_temp_<session_id> in normal mode
-- and pg_temp_<backend_id> in utility mode, once the normal-mode session id
-- equals to the utility-mode backend id they will conflict with each other and
-- cause catalog corruption on the segment.
--
-- We have changed the name to pg_temp_0<backend_id> in utility mode.
0U: CREATE TEMP TABLE utilitymode_tmp_tab (c1 int) DISTRIBUTED BY (c1);
0U: SELECT substring(n.nspname FROM 1 FOR 9)
      FROM pg_namespace n
      JOIN pg_class c
        ON n.oid = c.relnamespace
     WHERE c.relname = 'utilitymode_tmp_tab';
0U: SELECT substring(n2.nspname FROM 1 FOR 15)
      FROM pg_namespace n1
      JOIN pg_class c
        ON n1.oid = c.relnamespace
      JOIN pg_namespace n2
        ON n2.nspname = 'pg_toast_temp_0' || substring(n1.nspname FROM 10)
     WHERE c.relname = 'utilitymode_tmp_tab';

--
-- Validate GPDB doesn't crash when creating partitioned table in utility mode
--
0U: create table utilitymode_pt_lt_tab (col1 int, col2 decimal)
	distributed by (col1) partition by list(col2) (partition part1 values(1));

--
-- gp_dist_random('<view>') should not crash in utility mode
--
create or replace view misc_v as select 1;
0U: select 1 from gp_dist_random('misc_v') union select 1 from misc_v;
0U: select count(*) from gp_dist_random('misc_v');
-- But views created in utility mode should not throw away gp_dist_random
0U: create or replace view misc_v2 as select 1 from gp_dist_random('pg_class');
0U: select definition from pg_views where viewname = 'misc_v2';
0U: select count(*) > 0 from gp_dist_random('misc_v2');
0U: drop view misc_v2;
drop view misc_v;
