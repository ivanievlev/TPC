#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
source $PWD/../../parse_step_args.sh
source $PWD/../../mode.sh
init_tpc_mode
source $PWD/../../external_format.sh

if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$SINGLE_USER_ITERATIONS" == "" ]]; then
	echo "Missing required parameters from unified rollout."
	exit 1
fi

echo "USE_EXTERNAL_FORMAT: $USE_EXTERNAL_FORMAT"
echo "EXTERNAL_HIVE_PARTITIONING: $EXTERNAL_HIVE_PARTITIONING"

step=ddl
init_log $step
get_version

if [[ "$VERSION" == *"gpdb"* ]]; then
	filter="gpdb"
elif [ "$VERSION" == "postgresql" ]; then
	filter="postgresql"
else
	echo "ERROR: Unsupported VERSION $VERSION!"
	exit 1
fi

if { [ "$USE_EXTERNAL_FORMAT" = "parquet" ] || [ "$USE_EXTERNAL_FORMAT" = "csv" ] || [ "$USE_EXTERNAL_FORMAT" = "json" ]; } && [ "$filter" != "postgresql" ]; then
	echo "ERROR: USE_EXTERNAL_FORMAT=${USE_EXTERNAL_FORMAT} is only supported for PostgreSQL/pg_duckdb"
	exit 1
fi

if [ "$USE_EXTERNAL_FORMAT" = "parquet" ] || [ "$USE_EXTERNAL_FORMAT" = "csv" ] || [ "$USE_EXTERNAL_FORMAT" = "json" ]; then
	echo "Creating ${USE_EXTERNAL_FORMAT} views for schema TPCH (no heap tables)"
	create_external_views
	end_step $step
	exit 0
fi

#Create heap tables
for i in $(ls $PWD/*.$filter.*.sql); do
	id=$(echo $i | awk -F '.' '{print $1}')
	schema_name=$(echo $i | awk -F '.' '{print $2}')
	table_name=$(echo $i | awk -F '.' '{print $3}')
	start_log

	if [ "$filter" == "gpdb" ]; then
		if [ "$RANDOM_DISTRIBUTION" == "true" ]; then
			DISTRIBUTED_BY="DISTRIBUTED RANDOMLY"
		else
			for z in $(cat $PWD/distribution.txt); do
				table_name2=$(echo $z | awk -F '|' '{print $2}')
				if [ "$table_name2" == "$table_name" ]; then
					distribution=$(echo $z | awk -F '|' '{print $3}')
				fi
			done
			DISTRIBUTED_BY="DISTRIBUTED BY (""$distribution"")"
		fi
	else
		DISTRIBUTED_BY=""
	fi

	echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -a -P pager=off -f $i -v SMALL_STORAGE=\"$SMALL_STORAGE\" -v MEDIUM_STORAGE=\"$MEDIUM_STORAGE\" -v LARGE_STORAGE=\"$LARGE_STORAGE\" -v DISTRIBUTED_BY=\"$DISTRIBUTED_BY\""
	psql -d $DBNAME -v ON_ERROR_STOP=1 -q -a -P pager=off -f $i -v SMALL_STORAGE="$SMALL_STORAGE" -v MEDIUM_STORAGE="$MEDIUM_STORAGE" -v LARGE_STORAGE="$LARGE_STORAGE" -v DISTRIBUTED_BY="$DISTRIBUTED_BY"

	log
done

#external tables are the same for all gpdb
if [ "$filter" == "gpdb" ]; then
	for i in $(ls $PWD/*.ext_tpch.*.sql); do
		start_log

		id=$(echo $i | awk -F '.' '{print $1}')
		schema_name=$(echo $i | awk -F '.' '{print $2}')
		table_name=$(echo $i | awk -F '.' '{print $3}')

		counter=0
		if [[ "$VERSION" == "gpdb_6" || "$VERSION" == "gpdb_7" ]]; then
			for x in $(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "select rank() over (partition by g.hostname order by g.datadir), g.hostname from gp_segment_configuration g where g.content >= 0 and g.role = 'p' order by g.hostname"); do
				CHILD=$(echo $x | awk -F '|' '{print $1}')
				EXT_HOST=$(echo $x | awk -F '|' '{print $2}')
				PORT=$(($GPFDIST_PORT + $CHILD))

				if [ "$counter" -eq "0" ]; then
					LOCATION="'"
				else
					LOCATION+="', '"
				fi
				LOCATION+="gpfdist://$EXT_HOST:$PORT/""$table_name.tbl*"

				counter=$(($counter + 1))
			done
		else
			for x in $(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "select rank() over (partition by g.hostname order by p.fselocation), g.hostname from gp_segment_configuration g join pg_filespace_entry p on g.dbid = p.fsedbid join pg_tablespace t on t.spcfsoid = p.fsefsoid where g.content >= 0 and g.role = 'p' and t.spcname = 'pg_default' order by g.hostname"); do
				CHILD=$(echo $x | awk -F '|' '{print $1}')
				EXT_HOST=$(echo $x | awk -F '|' '{print $2}')
				PORT=$(($GPFDIST_PORT + $CHILD))

				if [ "$counter" -eq "0" ]; then
					LOCATION="'"
				else
					LOCATION+="', '"
				fi
				LOCATION+="gpfdist://$EXT_HOST:$PORT/""$table_name.tbl*"

				counter=$(($counter + 1))
			done
		fi
		LOCATION+="'"
		echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -a -P pager=off -f $i -v LOCATION=\"$LOCATION\""
		psql -d $DBNAME -v ON_ERROR_STOP=1 -q -a -P pager=off -f $i -v LOCATION="$LOCATION"

		log
	done
fi

end_step $step
