SELECT split_part(description, '.', 2) AS table_name,
       sum(tuples) AS tuples,
       round(sum(extract('epoch' from duration))::numeric, 3) AS seconds
FROM tpcds_reports.load
WHERE tuples > 0
GROUP BY split_part(description, '.', 2)
ORDER BY 1;
