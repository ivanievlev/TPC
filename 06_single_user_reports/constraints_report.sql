SELECT split_part(description, '.', 1) AS schema_name,
       split_part(description, '.', 2) AS table_name,
       extract('epoch' from duration) AS seconds
FROM tpcds_reports.load
WHERE tuples = 0
  AND (
       split_part(description, '.', 2) LIKE 'idx\_%' ESCAPE '\'
       OR split_part(description, '.', 2) LIKE '%\_pkey' ESCAPE '\'
       OR split_part(description, '.', 2) LIKE 'constraint\_%' ESCAPE '\'
      )
ORDER BY 1, 2;
