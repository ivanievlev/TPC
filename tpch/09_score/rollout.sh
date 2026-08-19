#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
source $PWD/../../parse_step_args.sh
source $PWD/../../mode.sh
init_tpc_mode
source $PWD/../../external_format.sh
source $PWD/../../score_helpers.sh

if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$SINGLE_USER_ITERATIONS" == "" ]]; then
	echo "Missing required parameters from unified rollout."
	exit 1
fi

step="score"
init_log $step

load_time=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select coalesce(sum(extract('epoch' from duration)),0) from ${TPC_REPORT_SCHEMA}.load where tuples > 0")
constraints_time=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "
select coalesce(sum(extract('epoch' from duration)),0)
from ${TPC_REPORT_SCHEMA}.load
where tuples = 0
  and (
       split_part(description, '.', 2) like 'idx\_%' escape chr(92)
       or split_part(description, '.', 2) like '%\_pkey' escape chr(92)
       or split_part(description, '.', 2) like 'constraint\_%' escape chr(92)
      )")
analyze_time=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "
select coalesce(sum(extract('epoch' from duration)),0)
from ${TPC_REPORT_SCHEMA}.load
where tuples = 0
  and split_part(description, '.', 2) not like 'idx\_%' escape chr(92)
  and split_part(description, '.', 2) not like '%\_pkey' escape chr(92)
  and split_part(description, '.', 2) not like 'constraint\_%' escape chr(92)")
queries_time=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select coalesce(sum(extract('epoch' from duration)),0) from (SELECT split_part(description, '.', 2) AS id,  min(duration) AS duration FROM ${TPC_REPORT_SCHEMA}.sql GROUP BY split_part(description, '.', 2)) as sub")
concurrent_queries_time=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select coalesce(sum(extract('epoch' from duration)),0) from ${TPC_TESTING_SCHEMA}.sql")

for v in load_time constraints_time analyze_time queries_time concurrent_queries_time; do
	eval "val=\${$v}"
	val=$(echo "$val" | tr -d '[:space:]')
	if [ -z "$val" ]; then
		eval "$v=0"
	else
		eval "$v=\$val"
	fi
done

q=$((3*MULTI_USER_COUNT*TPC_QUERY_ID_MAX))

tpt=$(echo "$queries_time*$MULTI_USER_COUNT" | bc)
tld=$(echo "0.01*$MULTI_USER_COUNT*$load_time" | bc)
num_score=$(echo "$GEN_DATA_SCALE*$q" | bc)
dem_score=$(echo "$tpt+2*$concurrent_queries_time+$tld" | bc)
if [ "$(echo "$dem_score == 0" | bc)" -eq 1 ]; then
	score=0
else
	score=$(echo "scale=3; $num_score/$dem_score" | bc)
fi

printf "%-36s %14s\n" "Metric" "Value"
printf "%-36s %14s\n" "------------------------------------" "--------------"
printf "%-36s %14s\n" "TPC mode" "$TPC_MODE"
printf "%-36s %14s\n" "Scale Factor" "$GEN_DATA_SCALE"
printf "%-36s %14.3f\n" "Load" "$load_time"
printf "%-36s %14.3f\n" "Constraints after load" "$constraints_time"
printf "%-36s %14.3f\n" "Analyze" "$analyze_time"
printf "%-36s %14.3f\n" "1 User Queries" "$queries_time"
printf "%-36s %14.3f\n" "${MULTI_USER_COUNT} User Queries" "$concurrent_queries_time"
printf "%-36s %14s\n" "Q" "$q"
printf "%-36s %14.3f\n" "TPT" "$tpt"
printf "%-36s %14.3f\n" "TTT" "$concurrent_queries_time"
printf "%-36s %14.3f\n" "TLD" "$tld"
printf "%-36s %14.3f\n" "Score" "$score"
echo ""
print_extended_score_metrics "$TPC_REPORT_SCHEMA" "$TPC_TESTING_SCHEMA"

vas_rc=0
print_answer_set_validation_section || vas_rc=$?

end_step $step
exit $vas_rc
