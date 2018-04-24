-- If we properly detect the system timezone during startup, then the timezone
-- will not be set to GMT. If we ever run into a test environment with GMT as
-- the default, it may be necessary to reconsider this.
\! PGTZ='DEFAULT' psql binswap_connect -c "select count(*) from pg_settings where name='TimeZone' and setting != 'GMT';"
