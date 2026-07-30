#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../functions.sh
source_bashrc

DBNAME=${27}

TRUNCATE_BEFORE_LOAD=$9
step=load
init_log $step

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

copy_script()
{
	echo "copy the start and stop scripts to the hosts in the cluster"
	for i in $(cat $PWD/../segment_hosts.txt); do
		echo "scp start_gpfdist.sh stop_gpfdist.sh $ADMIN_USER@$i:$ADMIN_HOME/"
		scp $PWD/start_gpfdist.sh $PWD/stop_gpfdist.sh $ADMIN_USER@$i:$ADMIN_HOME/
	done
}
stop_gpfdist()
{
	echo "stop gpfdist on all ports"
	for i in $(cat $PWD/../segment_hosts.txt); do
		ssh -n -f $i "bash -l -c 'cd ~/; ./stop_gpfdist.sh'"
	done
}
start_gpfdist()
{
	stop_gpfdist
	sleep 1
	get_gpfdist_port
	if [[ "$VERSION" == "gpdb_6" || "$VERSION" == "gpdb_7" ]]; then
		for i in $(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "select rank() over(partition by g.hostname order by g.datadir), g.hostname, g.datadir from gp_segment_configuration g where g.content >= 0 and g.role = 'p' order by g.hostname"); do
			CHILD=$(echo $i | awk -F '|' '{print $1}')
			EXT_HOST=$(echo $i | awk -F '|' '{print $2}')
			GEN_DATA_PATH=$(echo $i | awk -F '|' '{print $3}')
			GEN_DATA_PATH=$GEN_DATA_PATH/arenadata
			PORT=$(($GPFDIST_PORT + $CHILD))
			echo "executing on $EXT_HOST ./start_gpfdist.sh $PORT $GEN_DATA_PATH"
			ssh -n -f $EXT_HOST "bash -l -c 'cd ~/; ./start_gpfdist.sh $PORT $GEN_DATA_PATH'"
			sleep 1
		done
	else
		for i in $(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "select rank() over (partition by g.hostname order by p.fselocation), g.hostname, p.fselocation as path from gp_segment_configuration g join pg_filespace_entry p on g.dbid = p.fsedbid join pg_tablespace t on t.spcfsoid = p.fsefsoid where g.content >= 0 and g.role = 'p' and t.spcname = 'pg_default' order by g.hostname"); do
			CHILD=$(echo $i | awk -F '|' '{print $1}')
			EXT_HOST=$(echo $i | awk -F '|' '{print $2}')
			GEN_DATA_PATH=$(echo $i | awk -F '|' '{print $3}')
			GEN_DATA_PATH=$GEN_DATA_PATH/arenadata
			PORT=$(($GPFDIST_PORT + $CHILD))
			echo "executing on $EXT_HOST ./start_gpfdist.sh $PORT $GEN_DATA_PATH"
			ssh -n -f $EXT_HOST "bash -l -c 'cd ~/; ./start_gpfdist.sh $PORT $GEN_DATA_PATH'"
			sleep 1
		done
	fi
}

get_count_load_data()
{
	count="0"
	for i in $(cat $PWD/../segment_hosts.txt); do
		next_count=$(ssh -o ConnectTimeout=0 -n -f $i "bash -c 'ps -ef | grep $table_name | grep -v grep | wc -l'" 2>&1 || true)
		check="^[0-9]+$"
		if ! [[ $next_count =~ $check ]] ; then
			next_count="1"
		fi
		count=$(($count + $next_count))
	done
}


if [ "$TRUNCATE_BEFORE_LOAD" == "true" ]; then
	echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -f 000.truncate.sql"
	psql -d $DBNAME -v ON_ERROR_STOP=1 -f $PWD/000.truncate.sql
fi

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
	echo "parallel data chunks: $PARALLEL"

	# Лимит одновременных COPY: min(80% max_connections, число CPU).
	MAX_CONN=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "SHOW max_connections;")
	CPU_COUNT=$(nproc)
	MAX_BY_CONN=$(( MAX_CONN * 80 / 100 ))
	[ "$MAX_BY_CONN" -lt 1 ] && MAX_BY_CONN=1
	[ "$CPU_COUNT" -lt 1 ] && CPU_COUNT=1
	if [ "$MAX_BY_CONN" -lt "$CPU_COUNT" ]; then
		MAX_JOBS=$MAX_BY_CONN
	else
		MAX_JOBS=$CPU_COUNT
	fi
	echo "max_connections: $MAX_CONN, cpus: $CPU_COUNT, parallel COPY limit: $MAX_JOBS"

	# Планировщик: держим MAX_JOBS занятыми, но предпочитаем РАЗНЫЕ таблицы
	# (минимум активных COPY на таблицу), чтобы не биться в relation extension lock.
	# Второй чанк в ту же таблицу — только если свободных таблиц уже нет.
	declare -A TABLE_SIZE
	declare -A TABLE_ACTIVE
	declare -A PID_TABLE

	table_entries=()
	total_size=0
	for i in $(ls $PWD/*.$filter.*.sql); do
		short_i=$(basename $i)
		id=$(echo $short_i | awk -F '.' '{print $1}')
		schema_name=$(echo $short_i | awk -F '.' '{print $2}')
		table_name=$(echo $short_i | awk -F '.' '{print $3}')
		sz=0
		for p in $(seq 1 $PARALLEL); do
			raw_filename=$PGDATA/arenadata_$p/"$table_name"_"$p"_"$PARALLEL".dat
			if [[ -f $raw_filename && -s $raw_filename ]]; then
				fsz=$(stat -c%s "$raw_filename")
				sz=$((sz + fsz))
			fi
		done
		if [ "$sz" -gt 0 ]; then
			TABLE_SIZE[$table_name]=$sz
			TABLE_ACTIVE[$table_name]=0
			total_size=$((total_size + sz))
			table_entries+=("$table_name|$i|$id|$schema_name")
		fi
	done

	if [ "$total_size" -eq 0 ]; then
		echo "ERROR: no non-empty .dat files found under $PGDATA/arenadata_*"
		exit 1
	fi

	echo "Tables to load:"
	for entry in "${table_entries[@]}"; do
		IFS='|' read -r table_name sql_file id schema_name <<<"$entry"
		echo "  $table_name: size=${TABLE_SIZE[$table_name]}"
	done

	pending=()
	for entry in "${table_entries[@]}"; do
		IFS='|' read -r table_name sql_file id schema_name <<<"$entry"
		for p in $(seq 1 $PARALLEL); do
			raw_filename=$PGDATA/arenadata_$p/"$table_name"_"$p"_"$PARALLEL".dat
			if [[ -f $raw_filename && -s $raw_filename ]]; then
				pending+=("$table_name|$sql_file|$id|$schema_name|$raw_filename")
			fi
		done
	done
	echo "COPY jobs queued: ${#pending[@]}"

	fail=0
	active=0

	launch_one()
	{
		local idx job table_name sql_file id schema_name raw_filename
		local best_idx=-1 best_active=999999 best_size=-1 ta sz

		for idx in "${!pending[@]}"; do
			job=${pending[$idx]}
			table_name=${job%%|*}
			ta=${TABLE_ACTIVE[$table_name]:-0}
			sz=${TABLE_SIZE[$table_name]:-0}
			# 1) меньше активных COPY на таблицу
			# 2) при равенстве — более крупная таблица
			if [ "$ta" -lt "$best_active" ] || { [ "$ta" -eq "$best_active" ] && [ "$sz" -gt "$best_size" ]; }; then
				best_idx=$idx
				best_active=$ta
				best_size=$sz
			fi
		done

		[ "$best_idx" -lt 0 ] && return 1

		job=${pending[$best_idx]}
		IFS='|' read -r table_name sql_file id schema_name raw_filename <<<"$job"
		unset "pending[$best_idx]"
		pending=("${pending[@]}")

		active=$((active + 1))
		TABLE_ACTIVE[$table_name]=$(( ${TABLE_ACTIVE[$table_name]:-0} + 1 ))
		echo "[LAUNCH] $table_name $(basename "$raw_filename") table_active=${TABLE_ACTIVE[$table_name]} pool=$active/$MAX_JOBS left=${#pending[@]}"
		(
			start_log
			i=$sql_file
			schema_name=$schema_name
			table_name=$table_name
			filename="'""$raw_filename""'"
			tuples=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -f $sql_file -v filename="$filename" | grep COPY | awk -F ' ' '{print $2}'; exit ${PIPESTATUS[0]})
			log $tuples >/dev/null
			echo "[DONE] $table_name $(basename "$raw_filename") tuples=$tuples"
		) &
		PID_TABLE[$!]=$table_name
		return 0
	}

	echo "Starting parallel COPY (prefer different tables, keep $MAX_JOBS busy)..."
	while [ ${#pending[@]} -gt 0 ] || [ "$active" -gt 0 ]; do
		while [ "$active" -lt "$MAX_JOBS" ] && [ ${#pending[@]} -gt 0 ]; do
			launch_one || break
		done

		if [ "$active" -eq 0 ]; then
			break
		fi

		finished_pid=""
		if wait -n -p finished_pid; then
			:
		else
			fail=1
		fi
		table_name=${PID_TABLE[$finished_pid]}
		if [ -n "$table_name" ]; then
			TABLE_ACTIVE[$table_name]=$(( TABLE_ACTIVE[$table_name] - 1 ))
			unset "PID_TABLE[$finished_pid]"
		fi
		active=$((active - 1))
	done

	if [ "$fail" -ne 0 ]; then
		echo "ERROR: one or more parallel COPY jobs failed"
		exit 1
	fi
	echo "All parallel COPY jobs finished successfully."
fi


max_id=$(ls $PWD/*.sql | tail -1)
i=$(basename $max_id | awk -F '.' '{print $1}' | sed 's/^0*//')

if [[ "$VERSION" == *"gpdb"* ]]; then
	dbname="$PGDATABASE"
	if [ "$dbname" == "" ]; then
		dbname="$DBNAME"
	fi

	if [ "$PGPORT" == "" ]; then
		export PGPORT=5432
	fi
fi


if [[ "$VERSION" == *"gpdb"* ]]; then
	schema_name="tpcds"
	table_name="tpcds"

	start_log
	#Analyze schema using analyzedb
	analyzedb -d $dbname -s tpcds --full -a

	#make sure root stats are gathered
	if [[ "$VERSION" == "gpdb_6" || "$VERSION" == "gpdb_7" ]]; then
		for t in $(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select n.nspname, c.relname from pg_class c join pg_namespace n on c.relnamespace = n.oid left outer join (select starelid from pg_statistic group by starelid) s on c.oid = s.starelid join (select tablename from pg_partitions group by tablename) p on p.tablename = c.relname where n.nspname = 'tpcds' and s.starelid is null order by 1, 2"); do
			schema_name=$(echo $t | awk -F '|' '{print $1}')
			table_name=$(echo $t | awk -F '|' '{print $2}')
			echo "Missing root stats for $schema_name.$table_name"
			echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c \"ANALYZE ROOTPARTITION $schema_name.$table_name;\""
			psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "ANALYZE ROOTPARTITION $schema_name.$table_name;"
		done
	elif [ "$VERSION" == "gpdb_5" ]; then
		for t in $(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select n.nspname, c.relname from pg_class c join pg_namespace n on c.relnamespace = n.oid join pg_partitions p on p.schemaname = n.nspname and p.tablename = c.relname where n.nspname = 'tpcds' and p.partitionrank is null and c.reltuples = 0 order by 1, 2"); do
			schema_name=$(echo $t | awk -F '|' '{print $1}')
			table_name=$(echo $t | awk -F '|' '{print $2}')
			echo "Missing root stats for $schema_name.$table_name"
			echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c \"ANALYZE ROOTPARTITION $schema_name.$table_name;\""
			psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "ANALYZE ROOTPARTITION $schema_name.$table_name;"
		done
	fi

	tuples="0"
	log $tuples
else
	#postgresql analyze
	for t in $(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'tpcds' and c.relkind='r'"); do
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
