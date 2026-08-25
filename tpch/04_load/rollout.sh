#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
source $PWD/../../parse_step_args.sh
source $PWD/../../mode.sh
init_tpc_mode
source $PWD/../../external_format.sh

step=load
init_log $step

if [ -z "$PURGE_OLD_EXTERNAL_DATA" ]; then
	PURGE_OLD_EXTERNAL_DATA="true"
fi

echo "GEN_DATA_SCALE: $GEN_DATA_SCALE"
echo "USE_EXTERNAL_FORMAT: $USE_EXTERNAL_FORMAT"
echo "PURGE_OLD_EXTERNAL_DATA: $PURGE_OLD_EXTERNAL_DATA"

purge_old_external_data
if { [ "$USE_EXTERNAL_FORMAT" = "parquet" ] || [ "$USE_EXTERNAL_FORMAT" = "csv" ] || [ "$USE_EXTERNAL_FORMAT" = "json" ]; } && [ -z "$GEN_DATA_SCALE" ]; then
	echo "ERROR: GEN_DATA_SCALE is empty; cannot build external path ${EXTERNAL_FILE_DIRECTORY_PATH}/tpch_<scale>_${USE_EXTERNAL_FORMAT}/"
	exit 1
fi

ADMIN_HOME=$(eval echo ~$ADMIN_USER)

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
	if [ "$PURGE_OLD_EXTERNAL_DATA" != "true" ] && [ "$TRUNCATE_BEFORE_LOAD" == "true" ]; then
		echo "Removing existing ${USE_EXTERNAL_FORMAT} tree $(external_data_root)"
		rm -rf "$(external_data_root)"
	fi
	load_external_from_dat
	end_step $step
	exit 0
fi

# Heap load expects real tables (not leftover external views).
heap_relkind=$(psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -A -t -c \
	"SELECT c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'tpch' AND c.relname = 'orders'" \
	|| true)
if [ "$heap_relkind" = "v" ]; then
	echo "ERROR: tpch.orders is a VIEW (left from a previous USE_EXTERNAL_FORMAT=parquet|csv|json run),"
	echo "       but USE_EXTERNAL_FORMAT=false expects heap TABLES for COPY."
	echo "       Set RUN_DDL=true (and keep USE_EXTERNAL_FORMAT=false) to recreate heap tables, then re-run load."
	exit 1
fi
if [ -z "$heap_relkind" ]; then
	echo "ERROR: tpch.orders does not exist. Set RUN_DDL=true to create heap tables before load."
	exit 1
fi

copy_script()
{
	echo "copy the start and stop scripts to the hosts in the cluster"
	for i in $(cat $PWD/../../segment_hosts.txt); do
		echo "scp start_gpfdist.sh stop_gpfdist.sh $ADMIN_USER@$i:$ADMIN_HOME/"
		scp $PWD/start_gpfdist.sh $PWD/stop_gpfdist.sh $ADMIN_USER@$i:$ADMIN_HOME/
	done
}
stop_gpfdist()
{
	echo "stop gpfdist on all ports"
	for i in $(cat $PWD/../../segment_hosts.txt); do
		ssh -n $SSH_BATCH_OPTS $i "bash -lc 'cd ~/; ./stop_gpfdist.sh'" || true
	done
}
start_gpfdist()
{
	stop_gpfdist
	sleep 1
	if [[ "$VERSION" == "gpdb_6" || "$VERSION" == "gpdb_7" ]]; then
		for i in $(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "select rank() over (partition by g.hostname order by g.datadir), g.hostname, g.datadir from gp_segment_configuration g where g.content >= 0 and g.role = 'p' order by g.hostname"); do
			CHILD=$(echo $i | awk -F '|' '{print $1}')
			EXT_HOST=$(echo $i | awk -F '|' '{print $2}')
			GEN_DATA_PATH=$(gp_dat_dir "$(echo $i | awk -F '|' '{print $3}')")
			PORT=$(($GPFDIST_PORT + $CHILD))
			echo `whoami`
			echo "executing on $EXT_HOST ./start_gpfdist.sh $PORT $GEN_DATA_PATH"
			ssh -n $SSH_BATCH_OPTS $EXT_HOST "bash -lc 'cd ~/; ./start_gpfdist.sh $PORT $GEN_DATA_PATH'"
			sleep 1
		done
	else
		for i in $(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "select rank() over (partition by g.hostname order by p.fselocation), g.hostname, p.fselocation as path from gp_segment_configuration g join pg_filespace_entry p on g.dbid = p.fsedbid join pg_tablespace t on t.spcfsoid = p.fsefsoid where g.content >= 0 and g.role = 'p' and t.spcname = 'pg_default' order by g.hostname"); do
			CHILD=$(echo $i | awk -F '|' '{print $1}')
			EXT_HOST=$(echo $i | awk -F '|' '{print $2}')
			GEN_DATA_PATH=$(gp_dat_dir "$(echo $i | awk -F '|' '{print $3}')")
			PORT=$(($GPFDIST_PORT + $CHILD))
			echo "executing on $EXT_HOST ./start_gpfdist.sh $PORT $GEN_DATA_PATH"
			ssh -n $SSH_BATCH_OPTS $EXT_HOST "bash -lc 'cd ~/; ./start_gpfdist.sh $PORT $GEN_DATA_PATH'"
			sleep 1
		done
	fi
}

if [[ "$VERSION" == *"gpdb"* ]]; then
	copy_script
	start_gpfdist

	for i in $(ls $PWD/*.$filter.*.sql); do
		start_log

		id=$(echo $i | awk -F '.' '{print $1}')
		schema_name=$(echo $i | awk -F '.' '{print $2}')
		table_name=$(echo $i | awk -F '.' '{print $3}')

		echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -f $i | grep INSERT | awk -F ' ' '{print \$3}'"
		tuples=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -f $i | grep INSERT | awk -F ' ' '{print $3}'; exit ${PIPESTATUS[0]})

		log $tuples
	done
	stop_gpfdist
else
	if [ "$PGDATA" == "" ]; then
		echo "ERROR: Unable to determine PGDATA environment variable.  Be sure to have this set for the admin user."
		exit 1
	fi

	PARALLEL=$(lscpu --parse=cpu | grep -v "#" | wc -l)
	echo "parallel: $PARALLEL"

	# для каждой таблицы все партиции COPY запускаются параллельно
	# в фоне (&), затем wait ждёт завершения всей пачки.
	# PK/FK/индексы намеренно НЕ создаются до COPY (см. constraints_after_load.sql).
	for i in $(ls $PWD/*.$filter.*.sql); do
		id=$(echo $i | awk -F '.' '{print $1}')
		schema_name=$(echo $i | awk -F '.' '{print $2}')
		table_name=$(echo $i | awk -F '.' '{print $3}')
		pids=()
		for p in $(seq 1 $PARALLEL); do
			# включчаем и выключаем nullglob: если файла нет, то не оставлять литерал со звездочкой
			shopt -s nullglob
			files=($(pg_chunk_dat_dir "$PGDATA" "$p")/$table_name.tbl*)
			shopt -u nullglob
			for raw_filename in "${files[@]}"; do
				if [[ -f $raw_filename && -s $raw_filename ]]; then
					echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -f $i -v filename=\"'$raw_filename'\" | grep COPY | awk -F ' ' '{print \$2}'"
					(
						start_log
						filename="'""$raw_filename""'"
						tuples=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -f $i -v filename="$filename" | grep COPY | awk -F ' ' '{print $2}'; exit ${PIPESTATUS[0]})
						log $tuples
					) &
					pids+=($!)
				fi
			done
		done
		# дожидаемся всех фоновых COPY по текущей таблице
		fail=0
		for pid in "${pids[@]}"; do
			if ! wait "$pid"; then
				fail=1
			fi
		done
		if [ "$fail" -ne 0 ]; then
			echo "ERROR: one or more parallel COPY jobs failed for $table_name"
			exit 1
		fi
	done

	# После загрузки данных: PRIMARY KEY, индексы, FOREIGN KEY
	# Каждый statement из constraints_after_load.sql — отдельно, со своим таймингом в логе
	echo "creating primary keys, indexes and foreign keys after load"
	constraint_id=59
	while IFS= read -r stmt || [ -n "$stmt" ]; do
		# пропускаем пустые строки и комментарии
		[[ "$stmt" =~ ^[[:space:]]*$ ]] && continue
		[[ "$stmt" =~ ^[[:space:]]*-- ]] && continue
		stmt="${stmt%"${stmt##*[![:space:]]}"}"  # trim trailing whitespace
		[[ "$stmt" != *\; ]] && continue

		# метка для лога: имя PK / INDEX / CONSTRAINT
		if [[ "$stmt" =~ CREATE[[:space:]]+INDEX[[:space:]]+([a-zA-Z0-9_]+) ]]; then
			table_name="${BASH_REMATCH[1]}"
		elif [[ "$stmt" =~ ADD[[:space:]]+CONSTRAINT[[:space:]]+([a-zA-Z0-9_]+) ]]; then
			table_name="${BASH_REMATCH[1]}"
		elif [[ "$stmt" =~ ALTER[[:space:]]+TABLE[[:space:]]+tpch\.([a-zA-Z0-9_]+)[[:space:]]+ADD[[:space:]]+PRIMARY[[:space:]]+KEY ]]; then
			table_name="${BASH_REMATCH[1]}_pkey"
		else
			table_name="constraint_${constraint_id}"
		fi

		start_log
		schema_name="tpch"
		# log() берёт id из basename $i до первой точки
		i=$(printf "%03d.tpch.%s.sql" "$constraint_id" "$table_name")
		echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -c \"$stmt\""
		psql -d $DBNAME -v ON_ERROR_STOP=1 -c "$stmt"
		log 0
		constraint_id=$((constraint_id + 1))
	done < "$PWD/constraints_after_load.sql"
fi

max_id=$(ls $PWD/*.$filter.*.sql | tail -1)
i=$(basename $max_id | awk -F '.' '{print $1}' | sed 's/^0*//')

if [[ "$VERSION" == *"gpdb"* ]]; then
	dbname="$PGDATABASE"
	if [ "$dbname" == "" ]; then
		dbname="$DBNAME"
	fi

	if [ "$PGPORT" == "" ]; then
		export PGPORT="${PGPORT:-${PGPORT_WRITE:-5432}}"
	fi
fi


if [[ "$VERSION" == *"gpdb"* ]]; then
	schema_name="tpch"
	table_name="tpch"

	start_log
	#Analyze schema using analyzedb
	analyzedb -d $dbname -s tpch --full -a

	tuples="0"
	log $tuples
else
	#postgresql analyze
	for t in $(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'tpch' and c.relkind='r'"); do
		start_log
		schema_name=$(echo $t | awk -F '|' '{print $1}')
		table_name=$(echo $t | awk -F '|' '{print $2}')
		echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c \"ANALYZE $schema_name.$table_name;\""
		psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "ANALYZE $schema_name.$table_name;"
		tuples="0"
		log $tuples
		i=$((i+1))
	done
fi

end_step $step
