SELECT query_id,
       round(sum(session_1)::numeric, 3) AS session_1,
       round(sum(session_2)::numeric, 3) AS session_2,
       round(sum(session_3)::numeric, 3) AS session_3,
       round(sum(session_4)::numeric, 3) AS session_4,
       round(sum(session_5)::numeric, 3) AS session_5,
       round(sum(session_6)::numeric, 3) AS session_6,
       round(sum(session_7)::numeric, 3) AS session_7,
       round(sum(session_8)::numeric, 3) AS session_8,
       round(sum(session_9)::numeric, 3) AS session_9,
       round(sum(session_10)::numeric, 3) AS session_10
FROM (
	SELECT split_part(description, '.', 2) AS query_id,
	CASE WHEN split_part(description, '.', 1) = '1' THEN extract('epoch' from duration) ELSE 0 END AS session_1,
	CASE WHEN split_part(description, '.', 1) = '2' THEN extract('epoch' from duration) ELSE 0 END AS session_2,
	CASE WHEN split_part(description, '.', 1) = '3' THEN extract('epoch' from duration) ELSE 0 END AS session_3,
	CASE WHEN split_part(description, '.', 1) = '4' THEN extract('epoch' from duration) ELSE 0 END AS session_4,
	CASE WHEN split_part(description, '.', 1) = '5' THEN extract('epoch' from duration) ELSE 0 END AS session_5,
	CASE WHEN split_part(description, '.', 1) = '6' THEN extract('epoch' from duration) ELSE 0 END AS session_6,
	CASE WHEN split_part(description, '.', 1) = '7' THEN extract('epoch' from duration) ELSE 0 END AS session_7,
	CASE WHEN split_part(description, '.', 1) = '8' THEN extract('epoch' from duration) ELSE 0 END AS session_8,
	CASE WHEN split_part(description, '.', 1) = '9' THEN extract('epoch' from duration) ELSE 0 END AS session_9,
	CASE WHEN split_part(description, '.', 1) = '10' THEN extract('epoch' from duration) ELSE 0 END AS session_10
	FROM tpcds_testing.sql
) AS sub
GROUP BY query_id
ORDER BY 1;
