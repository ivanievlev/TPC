CREATE TABLE tpcds_reports.load
(timing varchar, id int, description varchar, tuples bigint, duration time) 
DISTRIBUTED BY (id);
