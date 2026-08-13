SELECT split_part(description, '.', 2) AS id,
       max(tuples) AS tuples,
       round(min(extract('epoch' from duration))::numeric, 3) AS duration,
       (array_agg(query_status ORDER BY
          CASE
            WHEN query_status LIKE 'ERROR:%' THEN 0
            WHEN query_status = 'cancelled due to timeout' THEN 1
            ELSE 2
          END,
          timing DESC))[1] AS query_status
FROM tpch_reports.sql
GROUP BY split_part(description, '.', 2)
ORDER BY id;
