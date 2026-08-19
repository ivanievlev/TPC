SELECT split_part(description, '.', 1) AS schema_name,
       split_part(description, '.', 2) AS table_name,
       round(extract('epoch' from duration)::numeric, 3) AS seconds
FROM tpcds_reports.load
WHERE tuples = 0
  AND split_part(description, '.', 2) NOT LIKE 'idx\_%' ESCAPE E'\\'
  AND split_part(description, '.', 2) NOT LIKE '%\_pkey' ESCAPE E'\\'
  AND split_part(description, '.', 2) NOT LIKE 'constraint\_%' ESCAPE E'\\'
ORDER BY 1, 2;
