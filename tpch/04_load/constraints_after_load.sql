-- PK, индексы и FK создаются ПОСЛЕ COPY, чтобы ускорить параллельную загрузку.
-- Порядок: сначала PRIMARY KEY (нужны для FK), затем индексы, затем FOREIGN KEY.

ALTER TABLE tpch.region ADD PRIMARY KEY (r_regionkey);
ALTER TABLE tpch.nation ADD PRIMARY KEY (n_nationkey);
ALTER TABLE tpch.customer ADD PRIMARY KEY (c_custkey);
ALTER TABLE tpch.part ADD PRIMARY KEY (p_partkey);
ALTER TABLE tpch.supplier ADD PRIMARY KEY (s_suppkey);
ALTER TABLE tpch.partsupp ADD PRIMARY KEY (ps_partkey, ps_suppkey);
ALTER TABLE tpch.orders ADD PRIMARY KEY (o_orderkey);
ALTER TABLE tpch.lineitem ADD PRIMARY KEY (l_orderkey, l_linenumber);

CREATE INDEX lineitem_idx3 ON tpch.lineitem (l_partkey, l_suppkey);

ALTER TABLE tpch.nation ADD CONSTRAINT nation_region_fk FOREIGN KEY (n_regionkey) REFERENCES tpch.region (r_regionkey);
ALTER TABLE tpch.supplier ADD CONSTRAINT supplier_nation_fk FOREIGN KEY (s_nationkey) REFERENCES tpch.nation (n_nationkey);
ALTER TABLE tpch.customer ADD CONSTRAINT customer_nation_fk FOREIGN KEY (c_nationkey) REFERENCES tpch.nation (n_nationkey);
ALTER TABLE tpch.partsupp ADD CONSTRAINT partsupp_part_fk FOREIGN KEY (ps_partkey) REFERENCES tpch.part (p_partkey);
ALTER TABLE tpch.partsupp ADD CONSTRAINT partsupp_supplier_fk FOREIGN KEY (ps_suppkey) REFERENCES tpch.supplier (s_suppkey);
ALTER TABLE tpch.orders ADD CONSTRAINT orders_customer_fk FOREIGN KEY (o_custkey) REFERENCES tpch.customer (c_custkey);
ALTER TABLE tpch.lineitem ADD CONSTRAINT lineitem_order_fk FOREIGN KEY (l_orderkey) REFERENCES tpch.orders (o_orderkey);
ALTER TABLE tpch.lineitem ADD CONSTRAINT lineitem_part_fk FOREIGN KEY (l_partkey) REFERENCES tpch.part (p_partkey);
ALTER TABLE tpch.lineitem ADD CONSTRAINT lineitem_partsupp_fk FOREIGN KEY (l_partkey, l_suppkey) REFERENCES tpch.partsupp (ps_partkey, ps_suppkey);
