#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
DBNAME=${27}

step=gen_data
init_log $step

GEN_DATA_SCALE=$1

if [ "$GEN_DATA_SCALE" == "" ]; then
	echo "You must provide the scale as a parameter in terms of Gigabytes."
	echo "Example: ./rollout.sh 100"
	echo "This will create 100 GB of data for this test."
	exit 1
fi

get_count_generate_data()
{
	count="0"
	for i in $(cat $PWD/../../segment_hosts.txt); do
		next_count=$(count_processes_on_host "$i" "generate_data.sh")
		count=$(($count + $next_count))
	done
}
kill_orphaned_data_gen()
{
	for i in $(cat $PWD/../../segment_hosts.txt); do
		kill_processes_on_host "$i" "dsdgen"
	done
}

copy_generate_data()
{
	for i in $(cat $PWD/../../segment_hosts.txt); do
		copy_to_host_home "$i" "$PWD/generate_data.sh"
	done
}

gen_data()
{
	get_version
	if [[ "$VERSION" == *"gpdb"* ]]; then
		PARALLEL=$(gpstate | grep "Total primary segments" | awk -F '=' '{print $2}')
		if [ "$PARALLEL" == "" ]; then
			echo "ERROR: Unable to determine how many primary segments are in the cluster using gpstate."
			exit 1
		fi
		echo "parallel: $PARALLEL"
		if [[ "$VERSION" == "gpdb_6" || "$VERSION" == "gpdb_7" ]]; then
			for i in $(psql -d postgres -v ON_ERROR_STOP=1 -q -A -t -c "select row_number() over(), g.hostname, g.datadir from gp_segment_configuration g where g.content >= 0 and g.role = 'p' order by 1, 2, 3"); do
				CHILD=$(echo $i | awk -F '|' '{print $1}')
				EXT_HOST=$(echo $i | awk -F '|' '{print $2}')
				GEN_DATA_PATH=$(echo $i | awk -F '|' '{print $3}')
				GEN_DATA_PATH="$GEN_DATA_PATH""/arenadata"
				start_generate_data_on_host "$EXT_HOST" "$GEN_DATA_SCALE" "$CHILD" "$PARALLEL" "$GEN_DATA_PATH"
			done
		else
			for i in $(psql -d postgres -v ON_ERROR_STOP=1 -q -A -t -c "select row_number() over(), g.hostname, p.fselocation as path from gp_segment_configuration g join pg_filespace_entry p on g.dbid = p.fsedbid join pg_tablespace t on t.spcfsoid = p.fsefsoid where g.content >= 0 and g.role = 'p' and t.spcname = 'pg_default' order by 1, 2, 3"); do
				CHILD=$(echo $i | awk -F '|' '{print $1}')
				EXT_HOST=$(echo $i | awk -F '|' '{print $2}')
				GEN_DATA_PATH=$(echo $i | awk -F '|' '{print $3}')
				GEN_DATA_PATH="$GEN_DATA_PATH""/arenadata"
				start_generate_data_on_host "$EXT_HOST" "$GEN_DATA_SCALE" "$CHILD" "$PARALLEL" "$GEN_DATA_PATH"
			done
		fi
	else
		#PostgreSQL
		#use the number of cores to determine the level of parallelism
		PARALLEL=$(lscpu --parse=cpu | grep -v "#" | wc -l)
		echo "parallel: $PARALLEL"
		if [ "$PGDATA" == "" ]; then
			echo "ERROR: Unable to determine PGDATA environment variable.  Be sure to have this set for the admin user."
			exit 1
		fi
		CHILD="0"
		EXT_HOST=$HOSTNAME
		for x in $(seq 1 $PARALLEL); do
			CHILD=$(($CHILD + 1))
			GEN_DATA_PATH="$PGDATA""/arenadata_""$CHILD"
			start_generate_data_on_host "$EXT_HOST" "$GEN_DATA_SCALE" "$CHILD" "$PARALLEL" "$GEN_DATA_PATH"
		done
	fi
}

#step=gen_data
#init_log $step
start_log
schema_name="tpcds"
table_name="gen_data"

require_ssh_to_segment_hosts
kill_orphaned_data_gen
copy_generate_data
gen_data

echo ""
get_count_generate_data
echo "Now generating data.  This make take a while."
echo -ne "Generating data"
while [ "$count" -gt "0" ]; do
	echo -ne "."
	sleep 5
	get_count_generate_data
done

echo "Done generating data"
echo ""

echo "Generate queries based on scale"
cd $PWD
$PWD/generate_queries.sh $GEN_DATA_SCALE

# Clear host-loop leftover in $i so log() writes numeric id (not hostname).
i=""
id=""
log

end_step $step
