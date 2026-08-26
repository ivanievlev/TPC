SELECT split_part(r.description, '.', 2) AS id,
       coalesce(nullif(split_part(r.description, '.', 3), ''), '1')::int AS iteration,
       r.tuples,
       round(extract('epoch' from r.duration)::numeric, 3) AS duration,
       r.query_status,
       coalesce(l.query_label, '') AS "query label",
       r.backend_host
FROM tpch_reports.sql r
LEFT JOIN tpc_query_labels l ON l.id = lpad(split_part(r.description, '.', 2), 2, '0')
ORDER BY iteration, id;
