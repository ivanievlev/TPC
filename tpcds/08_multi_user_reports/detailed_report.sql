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
       round(sum(session_10)::numeric, 3) AS session_10,
       (array_agg(query_status ORDER BY
          CASE
            WHEN query_status LIKE 'ERROR:%' THEN 0
            WHEN query_status = 'cancelled due to timeout' THEN 1
            ELSE 2
          END,
          timing DESC))[1] AS query_status,
       array_to_string(array_agg(DISTINCT backend_host), ', ') AS backend_hosts
FROM (
	SELECT split_part(description, '.', 2) AS query_id,
	timing,
	query_status,
	backend_host,
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
