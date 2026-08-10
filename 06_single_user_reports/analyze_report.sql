SELECT split_part(description, '.', 1) AS schema_name,
       split_part(description, '.', 2) AS table_name,
       extract('epoch' from duration) AS seconds
FROM tpcds_reports.load
WHERE tuples = 0
  AND split_part(description, '.', 2) NOT LIKE 'idx\_%' ESCAPE '\'
  AND split_part(description, '.', 2) NOT LIKE '%\_pkey' ESCAPE '\'
  AND split_part(description, '.', 2) NOT LIKE 'constraint\_%' ESCAPE '\'
ORDER BY 1, 2;
