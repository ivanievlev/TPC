SELECT split_part(description, '.', 2) AS id,
       coalesce(nullif(split_part(description, '.', 3), ''), '1')::int AS iteration,
       tuples,
       round(extract('epoch' from duration)::numeric, 3) AS duration,
       query_status
FROM tpcds_reports.sql
ORDER BY iteration, id;
