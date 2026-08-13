#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc

GEN_DATA_SCALE=$1
EXPLAIN_ANALYZE=$2
RANDOM_DISTRIBUTION=$3
MULTI_USER_COUNT=$4
SINGLE_USER_ITERATIONS=$5
DBNAME=${27}

if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$SINGLE_USER_ITERATIONS" == "" ]]; then
	echo "You must provide the scale as a parameter in terms of Gigabytes, true/false to run queries with EXPLAIN ANALYZE option, true/false to use random distrbution, multi-user count, and the number of sql iterations."
	echo "Example: ./rollout.sh 100 false false 5 1"
	exit 1
fi

step="score"
init_log $step

# Load: COPY / external convert rows (tuples > 0)
load_time=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select coalesce(sum(extract('epoch' from duration)),0) from tpcds_reports.load where tuples > 0")
# Constraints after load: PK / indexes (tuples = 0, name patterns)
constraints_time=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "
select coalesce(sum(extract('epoch' from duration)),0)
from tpcds_reports.load
where tuples = 0
  and (
       split_part(description, '.', 2) like 'idx\_%' escape '\'
       or split_part(description, '.', 2) like '%\_pkey' escape '\'
       or split_part(description, '.', 2) like 'constraint\_%' escape '\'
      )")
# Analyze: only ANALYZE commands (tuples = 0, not constraints)
analyze_time=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "
select coalesce(sum(extract('epoch' from duration)),0)
from tpcds_reports.load
where tuples = 0
  and split_part(description, '.', 2) not like 'idx\_%' escape '\'
  and split_part(description, '.', 2) not like '%\_pkey' escape '\'
  and split_part(description, '.', 2) not like 'constraint\_%' escape '\'")
queries_time=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select coalesce(sum(extract('epoch' from duration)),0) from (SELECT split_part(description, '.', 2) AS id,  min(duration) AS duration FROM tpcds_reports.sql GROUP BY split_part(description, '.', 2)) as sub")
concurrent_queries_time=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select coalesce(sum(extract('epoch' from duration)),0) from tpcds_testing.sql")

# Normalize empty/whitespace to 0 for arithmetic and printf.
for v in load_time constraints_time analyze_time queries_time concurrent_queries_time; do
	eval "val=\${$v}"
	val=$(echo "$val" | tr -d '[:space:]')
	if [ -z "$val" ]; then
		eval "$v=0"
	else
		eval "$v=\$val"
	fi
done

q=$((3*MULTI_USER_COUNT*99))

tpt=$(echo "$queries_time*$MULTI_USER_COUNT" | bc)
tld=$(echo "0.01*$MULTI_USER_COUNT*$load_time" | bc)
num_score=$(echo "$GEN_DATA_SCALE*$q" | bc)
dem_score=$(echo "$tpt+2*$concurrent_queries_time+$tld" | bc)
# Avoid divide-by-zero in bc
if [ "$(echo "$dem_score == 0" | bc)" -eq 1 ]; then
	score=0
else
	score=$(echo "scale=3; $num_score/$dem_score" | bc)
fi

printf "%-24s %14s\n" "Metric" "Value"
printf "%-24s %14s\n" "------------------------" "--------------"
printf "%-24s %14s\n" "Scale Factor" "$GEN_DATA_SCALE"
printf "%-24s %14.3f\n" "Load" "$load_time"
printf "%-24s %14.3f\n" "Constraints after load" "$constraints_time"
printf "%-24s %14.3f\n" "Analyze" "$analyze_time"
printf "%-24s %14.3f\n" "1 User Queries" "$queries_time"
printf "%-24s %14.3f\n" "Concurrent Queries" "$concurrent_queries_time"
printf "%-24s %14s\n" "Q" "$q"
printf "%-24s %14.3f\n" "TPT" "$tpt"
printf "%-24s %14.3f\n" "TTT" "$concurrent_queries_time"
printf "%-24s %14.3f\n" "TLD" "$tld"
printf "%-24s %14.3f\n" "Score" "$score"

end_step $step
