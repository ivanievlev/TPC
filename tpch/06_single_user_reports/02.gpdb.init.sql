CREATE TABLE tpch_reports.init
(timing varchar, id int, description varchar, tuples bigint, duration time) 
DISTRIBUTED BY (id);
