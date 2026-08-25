CREATE TABLE tpcds_testing.sql
(timing varchar, id int, description varchar, tuples bigint, duration time, query_status varchar, backend_host varchar)
DISTRIBUTED BY (id);
