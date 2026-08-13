CREATE TABLE tpcds_reports.ddl
(timing varchar, id int, description varchar, tuples bigint, duration time) 
DISTRIBUTED BY (id);
