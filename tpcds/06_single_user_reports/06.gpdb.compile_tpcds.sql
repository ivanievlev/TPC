CREATE TABLE tpcds_reports.compile_tpcds
(timing varchar, id int, description varchar, tuples bigint, duration time) 
DISTRIBUTED BY (id);
