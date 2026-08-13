CREATE TABLE tpch_reports.gen_data
(timing varchar, id int, description varchar, tuples bigint, duration time) 
DISTRIBUTED BY (id);
