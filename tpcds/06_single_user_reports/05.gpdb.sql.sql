CREATE TABLE tpcds_reports.sql
(timing varchar, id int, description varchar, tuples bigint, duration time, query_status varchar) 
DISTRIBUTED BY (id);
