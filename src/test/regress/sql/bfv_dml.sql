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


--
-- Check that INSERT and DELETE triggers don't fire on UPDATE.
--
-- It may seem weird how that could happen, but with ORCA, UPDATEs are
-- implemented as a "split update", which is really a DELETE and an INSERT.
--
CREATE TABLE bfv_dml_trigger_test (id int4, t text);

INSERT INTO bfv_dml_trigger_test VALUES (1, 'foo');

CREATE OR REPLACE FUNCTION bfv_dml_error_func() RETURNS trigger AS
$$
BEGIN
   RAISE EXCEPTION 'trigger was called!';
   RETURN NEW;
END
$$ LANGUAGE 'plpgsql';

CREATE TRIGGER before_trigger BEFORE INSERT or DELETE ON bfv_dml_trigger_test
FOR EACH ROW
EXECUTE PROCEDURE bfv_dml_error_func();

CREATE TRIGGER after_trigger AFTER INSERT or DELETE ON bfv_dml_trigger_test
FOR EACH ROW
EXECUTE PROCEDURE bfv_dml_error_func();

UPDATE bfv_dml_trigger_test SET t = 'bar';
UPDATE bfv_dml_trigger_test SET id = id + 1;
