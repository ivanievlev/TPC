#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
source $PWD/../../parse_step_args.sh
source $PWD/../../mode.sh
init_tpc_mode

if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$SINGLE_USER_ITERATIONS" == "" ]]; then
	echo "Missing required parameters from tpc_variables.sh (scale, explain, random, multi-user, iterations)."
	exit 1
fi
validate_skip_queries_list "$SKIP_QUERIES_LIST"

step=sql
init_log $step

echo "SQL_ON_ERROR_STOP = $SQL_ON_ERROR_STOP"
echo "STATEMENT_TIMEOUT = $STATEMENT_TIMEOUT"
echo "SINGLE_USER_ITERATIONS = $SINGLE_USER_ITERATIONS"
echo "DROP_CACHE_BEFORE_SQL = $DROP_CACHE_BEFORE_SQL"
echo "RUN_SQL_WITH_DUCKDB = $RUN_SQL_WITH_DUCKDB"
echo "DUCKDB_MEMORY_LIMIT = $DUCKDB_MEMORY_LIMIT"
echo "DUCKDB_THREADS = $DUCKDB_THREADS"
echo "DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN = $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN"
echo "DUCKDB_THREADS_FOR_POSTGRES_SCAN = $DUCKDB_THREADS_FOR_POSTGRES_SCAN"
echo "SKIP_QUERIES_LIST = $SKIP_QUERIES_LIST"
echo "USE_EXTERNAL_FORMAT = $USE_EXTERNAL_FORMAT"
if [ "$SQL_ON_ERROR_STOP" == "true" ]; then
	ON_ERROR_STOP=1
else
	ON_ERROR_STOP=0
fi

PSQL_SESSION_SETS="SET statement_timeout='$STATEMENT_TIMEOUT';"
if [ "$RUN_SQL_WITH_DUCKDB" == "true" ]; then
	append_duckdb_session_sets
fi

get_version
if [[ "$VERSION" == *"gpdb"* ]]; then
  echo "DELETE_DAT_FILES_BEFORE_SQL: $DELETE_DAT_FILES_BEFORE_SQL"
  if [ "$DELETE_DAT_FILES_BEFORE_SQL" == "true" ]; then
    gpssh -f /home/gpadmin/arenadata_configs/arenadata_segment_hosts.hosts -e "rm -Rf ${DAT_FILE_DIRECTORY_PATH}/primary/gpseg*/../datfiles/*.dat ${DAT_FILE_DIRECTORY_PATH}/mirror/gpseg*/../datfiles/*.dat"
  fi

  echo "Checking optimizer settings"
  gpconfig -s optimizer
fi

mkdir -p $PWD/../../log/single_explain_analyze_log
rm -f $PWD/../../log/single_explain_analyze_log/*single.explain_analyze*.log
sql_file_list=""
for i in $(ls $PWD/*.tpcds.*.sql); do
	qnum=`echo $i | awk -F '.' '{print $3}'`
	if should_skip_tpcds_query "$qnum"; then
		echo "Skipping $qnum due to $(_tpc_skip_list_var_name)=${SKIP_QUERIES_LIST}."
		continue
	fi
	if [ "$EXCLUDE_HEAVY_QUERIES" == "true" ]; then

		if [[ 
		"$qnum" == "02" ||
		"$qnum" == "04" ||
		"$qnum" == "05" ||
		"$qnum" == "09" ||
		"$qnum" == "10" ||
		"$qnum" == "11" ||
		"$qnum" == "14" ||
		"$qnum" == "16" ||
		"$qnum" == "17" ||
		"$qnum" == "18" ||
		"$qnum" == "22" ||
		"$qnum" == "23" ||
		"$qnum" == "24" ||
		"$qnum" == "25" ||
		"$qnum" == "28" ||
		"$qnum" == "29" ||
		"$qnum" == "31" ||
		"$qnum" == "35" ||
		"$qnum" == "36" ||
		"$qnum" == "38" ||
		"$qnum" == "39" ||
		"$qnum" == "44" ||
		"$qnum" == "46" ||
		"$qnum" == "47" ||
		"$qnum" == "50" ||
		"$qnum" == "51" ||
		"$qnum" == "57" ||
		"$qnum" == "59" ||
		"$qnum" == "64" ||
		"$qnum" == "65" ||
		"$qnum" == "67" ||
		"$qnum" == "70" ||
		"$qnum" == "72" ||
		"$qnum" == "74" ||
		"$qnum" == "75" ||
		"$qnum" == "76" ||
		"$qnum" == "78" ||
		"$qnum" == "79" ||
		"$qnum" == "80" ||
		"$qnum" == "82" ||
		"$qnum" == "87" ||
		"$qnum" == "88" ||
		"$qnum" == "93" ||
		"$qnum" == "94" ||
		"$qnum" == "95" ||
		"$qnum" == "96" ||
		"$qnum" == "97" ||
		"$qnum" == "99" ]]; then

			echo "Skipping $qnum due to EXCLUDE_HEAVY_QUERIES=true."
		continue
		fi
	fi
	sql_file_list="$sql_file_list $i"
done

for x in $(seq 1 $SINGLE_USER_ITERATIONS); do
	echo "SQL iteration $x of $SINGLE_USER_ITERATIONS"
	drop_os_page_cache_before_sql_iteration "$x" || exit 1
	for i in $sql_file_list; do
		id=`echo $i | awk -F '.' '{print $1}'`
		schema_name=`echo $i | awk -F '.' '{print $2}'`
		# description = schema.query.iteration so SCORE can split 05_sql passes
		table_name="$(echo $i | awk -F '.' '{print $3}').${x}"
		start_log
		sql_outfile=$(mktemp)
		sql_errfile=$(mktemp)
		hostfile=$(mktemp)
		psql_rc=0
		if [ "$EXPLAIN_ANALYZE" == "false" ]; then
			echo "psql -d $DBNAME -U $RUN_SQL_FROM_ROLE -c \"$PSQL_SESSION_SETS\" -v ON_ERROR_STOP=$ON_ERROR_STOP -A -q -t -P pager=off -v EXPLAIN_ANALYZE=\"\" -f $i | wc -l"
			set +e
			psql_run_sql_capturing_host "$i" "$sql_outfile" "$sql_errfile" "$hostfile" ""
			psql_rc=$?
			set -e
			# Keep stderr visible in the step log (same as before when psql wrote to the terminal).
			if [ -s "$sql_errfile" ]; then
				cat "$sql_errfile" >&2
			fi
			tuples=$(wc -l < "$sql_outfile" | tr -d ' ')
		else
			myfilename=$(basename $i)
			mylogfile=$PWD/../../log/single_explain_analyze_log/$myfilename.single.explain_analyze.log
			echo "psql -d $DBNAME -U $RUN_SQL_FROM_ROLE -c \"$PSQL_SESSION_SETS\" -v ON_ERROR_STOP=$ON_ERROR_STOP -A -q -t -P pager=off -v EXPLAIN_ANALYZE=\"EXPLAIN ANALYZE\" -f $i > $mylogfile"
			set +e
			psql_run_sql_capturing_host "$i" "$mylogfile" "$sql_errfile" "$hostfile" "EXPLAIN ANALYZE"
			psql_rc=$?
			set -e
			if [ -s "$sql_errfile" ]; then
				cat "$sql_errfile" >&2
			fi
			tuples=$(tuples_from_explain_log "$mylogfile")
		fi
		QUERY_STATUS=$(sql_query_status "$sql_errfile" "$psql_rc")
		log $tuples
		sql_exit_if_query_error "$sql_outfile" "$sql_errfile" "$hostfile"
		unset QUERY_STATUS QUERY_BACKEND_HOST
		rm -f "$sql_outfile" "$sql_errfile" "$hostfile"
	done
done

end_step $step
