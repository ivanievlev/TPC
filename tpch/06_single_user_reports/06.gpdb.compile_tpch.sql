CREATE TABLE tpch_reports.compile_tpch
(timing varchar, id int, description varchar, tuples bigint, duration time) 
DISTRIBUTED BY (id);
