CREATE TABLE tpch_reports.load
(timing varchar, id int, description varchar, tuples bigint, duration time) 
DISTRIBUTED BY (id);
