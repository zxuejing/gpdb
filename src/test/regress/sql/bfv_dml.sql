-- MPP-21622 Update with primary key: only sort if the primary key is updated
--
-- Aside from testing that bug, this also tests EXPLAIN of an DMLActionExpr
-- that ORCA generates for plans that update the primary key.
create table update_pk_test (a int primary key, b int) distributed by (a);
insert into update_pk_test values(1,1);

explain update update_pk_test set b = 5;
update update_pk_test set b = 5;
select * from update_pk_test order by 1,2;

explain update update_pk_test set a = 5;
update update_pk_test set a = 5;
select * from update_pk_test order by 1,2;
