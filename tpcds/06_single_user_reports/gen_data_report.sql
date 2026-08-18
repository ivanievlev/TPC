WITH x AS (SELECT duration FROM tpcds_reports.gen_data)
SELECT 'Seconds' AS time, round(extract('epoch' from duration)::numeric, 3) AS value
FROM x
UNION ALL
SELECT 'Minutes', round((extract('epoch' from duration)/60)::numeric, 3)
FROM x
UNION ALL
SELECT 'Hours', round((extract('epoch' from duration)/(60*60))::numeric, 3)
FROM x;
