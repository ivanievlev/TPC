#!/bin/bash
set -e

count=$(alias | grep -w grep | wc -l)
if [ "$count" -gt "0" ]; then
	unalias grep
fi
count=$(alias | grep -w ls | wc -l)
if [ "$count" -gt "0" ]; then
	unalias ls
fi

#LD_PRELOAD=/lib64/libz.so.1 ps is optional and it caused problems on Astra Linux
#export LD_PRELOAD=/lib64/libz.so.1 ps


LOCAL_PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
OSVERSION=`uname`
ADMIN_USER=`whoami`
ADMIN_HOME=$(eval echo ~$ADMIN_USER)
MASTER_HOST=$(hostname -s)

# Flush OS page cache (pagecache + dentries + inodes). Requires passwordless sudo.
drop_os_page_cache()
{
	echo "DROP_CACHE_BEFORE_SQL: sync && echo 3 > /proc/sys/vm/drop_caches"
	sync
	if ! sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches'; then
		echo "ERROR: failed to write /proc/sys/vm/drop_caches (need passwordless sudo)."
		return 1
	fi
	echo "DROP_CACHE_BEFORE_SQL: OS page cache dropped"
	return 0
}

get_gpfdist_port()
{
	all_ports=$(psql -d postgres -t -A -c "select min(case when role = 'p' then port else 999999 end), min(case when role = 'm' then port else 999999 end) from gp_segment_configuration where content >= 0")
	primary_base=$(echo $all_ports | awk -F '|' '{print $1}' | head -c1)
	mirror_base=$(echo $all_ports | awk -F '|' '{print $2}' | head -c1)

	for i in $(seq 4 9); do
		if [ "$primary_base" -ne "$i" ] && [ "$mirror_base" -ne "$i" ]; then
			GPFDIST_PORT="$i""000"
			break
		fi
	done
}

source_bashrc()
{
	if [ -f ~/.bashrc ]; then
		# don't fail if an error is happening in the admin's profile
		source ~/.bashrc || true
	fi

        if [ -f ~/.bash_profile ]; then
                source ~/.bash_profile || true
        fi
	
        if [ -f ~/.profile ]; then
                # don't fail if an error is happening in the admin's profile
                source ~/.profile || true
        fi

	count=$(grep -v "^#" ~/.bashrc  ~/.*profile | grep "greenplum_path" | wc -l)
	if [ "$count" -eq "0" ]; then
		get_version
		if [[ "$VERSION" == *"gpdb"* ]]; then
			echo "$startup_file does not contain greenplum_path.sh"
			echo "Please update your $startup_file for $ADMIN_USER and try again."
			exit 1
		fi
	fi
}

# Validate SKIP_QUERIES_LIST: empty or comma-separated integers in 1..TPC_QUERY_ID_MAX
# (99 for TPC-DS, 22 for TPC-H). Examples OK: "", "85", "1,64,85".
validate_skip_queries_list()
{
	local list="${1:-}"
	local item n
	local max="${TPC_QUERY_ID_MAX:-99}"
	list=$(echo "$list" | tr -d '[:space:]')
	if [ -z "$list" ]; then
		return 0
	fi
	IFS=',' read -ra _skip_items <<< "$list"
	for item in "${_skip_items[@]}"; do
		if [ -z "$item" ]; then
			echo "ERROR: SKIP_QUERIES_LIST has an empty entry (got: ${1})"
			echo "Expected comma-separated query numbers in 1..${max}."
			exit 1
		fi
		if ! [[ "$item" =~ ^[0-9]+$ ]]; then
			echo "ERROR: SKIP_QUERIES_LIST invalid entry \"$item\" (must be an integer 1..${max})."
			exit 1
		fi
		# Force decimal (avoid octal for 08/09); strip leading zeros.
		n=$((10#$item))
		if [ "$n" -lt 1 ] || [ "$n" -gt "$max" ]; then
			echo "ERROR: SKIP_QUERIES_LIST query $n is out of range (must be 1..${max} for ${TPC_MODE:-TPC-DS})."
			exit 1
		fi
	done
}

# Return 0 if TPC-DS query number $1 is listed in SKIP_QUERIES_LIST ($2 optional override).
# $1 may be zero-padded (e.g. "01", "85").
should_skip_tpcds_query()
{
	local qnum="$1"
	local list="${2:-${SKIP_QUERIES_LIST:-}}"
	local item n q
	list=$(echo "$list" | tr -d '[:space:]')
	[ -z "$list" ] && return 1
	if ! [[ "$qnum" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	q=$((10#$qnum))
	IFS=',' read -ra _skip_items <<< "$list"
	for item in "${_skip_items[@]}"; do
		[ -z "$item" ] && continue
		[[ "$item" =~ ^[0-9]+$ ]] || continue
		n=$((10#$item))
		if [ "$n" -eq "$q" ]; then
			return 0
		fi
	done
	return 1
}

get_version()
{
	#need to call source_bashrc first
	VERSION=$(psql -d postgres -v ON_ERROR_STOP=1 -t -A -c "SELECT CASE WHEN POSITION ('Greenplum Database 4.3' IN version) > 0 THEN 'gpdb_4_3' WHEN POSITION ('Greenplum Database 5' IN version) > 0 THEN 'gpdb_5' WHEN POSITION ('Greenplum Database 6' IN version) > 0 THEN 'gpdb_6' WHEN POSITION ('Greenplum Database 7' IN version) > 0 THEN 'gpdb_7' ELSE 'postgresql' END FROM version();") 
	if [[ "$VERSION" == *"gpdb"* ]]; then
		if [ "${HEAP_ONLY}" == "true" ]; then
    			HEAP_STORAGE="appendonly=false"
			SMALL_STORAGE="${HEAP_STORAGE}"
    			MEDIUM_STORAGE="${HEAP_STORAGE}"
    			LARGE_STORAGE="${HEAP_STORAGE}"
		else
			if [ "${REFERENCE_TABLE_TYPE}" == "aoco" ]; then
				SMALL_STORAGE="appendonly=true, orientation=column"
			elif [ "${REFERENCE_TABLE_TYPE}" == "aoro" ]; then
				SMALL_STORAGE="appendonly=true, orientation=row"
			elif [ "${REFERENCE_TABLE_TYPE}" == "heap" ]; then
				echo "checked luka"
				SMALL_STORAGE="appendonly=false"
			fi
		MEDIUM_STORAGE="appendonly=true, orientation=column"
		LARGE_STORAGE="appendonly=true, orientation=column, compresstype=zstd, compresslevel=5"
		fi
	else
		SMALL_STORAGE=""
		MEDIUM_STORAGE=""
		LARGE_STORAGE=""
	fi
}
format_duration()
{
	# $1 = elapsed nanoseconds (Linux) or seconds (other)
	local elapsed=$1
	local s m
	if [ "$OSVERSION" == "Linux" ]; then
		s=$((elapsed/1000000000))
		m=$(( (elapsed/1000000) % 1000 ))
	else
		s=$elapsed
		m=0
	fi
	printf "%02d:%02d:%02d.%03d" "$((s/3600%24))" "$((s/60%60))" "$((s%60))" "$m"
}

# Ensure standard log/ layout exists.
ensure_log_dirs()
{
	mkdir -p \
		"$LOCAL_PWD/log" \
		"$LOCAL_PWD/log/end_testing_log" \
		"$LOCAL_PWD/log/rollout_testing_log" \
		"$LOCAL_PWD/log/testing_session_log" \
		"$LOCAL_PWD/log/single_explain_analyze_log" \
		"$LOCAL_PWD/log/multi_explain_analyze_log" \
		"$LOCAL_PWD/log/archived_results"
}

# Resolve directories for end_*.log / rollout_*.log of a step.
# testing_* → log/end_testing_log and log/rollout_testing_log; others → log/.
resolve_step_log_dirs()
{
	local step=$1
	ensure_log_dirs
	case "$step" in
		testing_*)
			STEP_END_LOG_DIR="$LOCAL_PWD/log/end_testing_log"
			STEP_ROLLOUT_LOG_DIR="$LOCAL_PWD/log/rollout_testing_log"
			;;
		*)
			STEP_END_LOG_DIR="$LOCAL_PWD/log"
			STEP_ROLLOUT_LOG_DIR="$LOCAL_PWD/log"
			;;
	esac
}

init_log()
{
	resolve_step_log_dirs "$1"

	if [ -f "$STEP_END_LOG_DIR/end_$1.log" ]; then
		echo "We are skipping step $1"
		exit 0
	else
		echo "end_$1.log is absent so we are starting step $1"
	fi

	logfile=rollout_$1.log
	STEP_ROLLOUT_LOGFILE="$STEP_ROLLOUT_LOG_DIR/$logfile"

	#A bug when process expects rollout_sql.log occures and I replaced rm for empty 
	> "$STEP_ROLLOUT_LOGFILE"
	#rm -f $LOCAL_PWD/log/$logfile

	# wall-clock старта шага (не путать с T из start_log/log по объектам)
	STEP_NAME=$1
	STEP_START_TS=$(date +%F_%T)
	if [ "$OSVERSION" == "Linux" ]; then
		STEP_START_NS="$(date +%s%N)"
	else
		STEP_START_NS="$(date +%s)"
	fi
	echo "Step $STEP_NAME started at $STEP_START_TS"
}

start_log()
{
	if [ "$OSVERSION" == "Linux" ]; then
		T="$(date +%s%N)"
	else
		T="$(date +%s)"
	fi
}

log()
{
	#timestamp
	timing=$(date +%F_%T)
	#duration
	if [ "$OSVERSION" == "Linux" ]; then
		T="$(($(date +%s%N)-T))"
		# whole seconds
		S="$((T/1000000000))"
		# fractional milliseconds (0..999)
		M="$(( (T/1000000) % 1000 ))"
	else
		#must be OSX which doesn't have nano-seconds
		T="$(($(date +%s)-T))"
		S=$T
		M=0
	fi

	# Derive id from SQL path $i (e.g. 001.postgresql.inventory.sql -> 1).
	# Do not reuse a stale $id. If $i is unset or not a numbered SQL file
	# (e.g. leftover hostname from a host loop in gen_data), fall back to 1.
	if [ "${i:-}" = "" ]; then
		id="1"
	else
		id=$(basename "$i" | awk -F '.' '{print $1}')
	fi
	id=$(echo "$id" | sed 's/^0*//')
	if ! [[ "$id" =~ ^[0-9]+$ ]]; then
		id="1"
	fi

	tuples=$1
	if [ "$tuples" == "" ]; then
		tuples="0"
	fi

	# Prefer path from init_log; fall back to log/ for callers that set logfile only.
	local out_file="${STEP_ROLLOUT_LOGFILE:-$LOCAL_PWD/log/$logfile}"

	# Optional 6th field for SQL reports (see sql_query_status / QUERY_STATUS).
	if [ -n "${QUERY_STATUS:-}" ]; then
		qs=$(printf '%s' "$QUERY_STATUS" | tr '|\n\r\t' '    ' | sed 's/  */ /g' | head -c 500)
		printf "$timing|$id|$schema_name.$table_name|$tuples|%02d:%02d:%02d.%03d|%s\n" "$((S/3600%24))" "$((S/60%60))" "$((S%60))" "${M}" "$qs" | tee -a "$out_file"
	else
		printf "$timing|$id|$schema_name.$table_name|$tuples|%02d:%02d:%02d.%03d\n" "$((S/3600%24))" "$((S/60%60))" "$((S%60))" "${M}" | tee -a "$out_file"
	fi
}

# Result tuple count from an EXPLAIN ANALYZE log (stdout of psql -f with EXPLAIN ANALYZE).
# EXPLAIN does not return result rows to the client, so we parse the plan instead.
tuples_from_explain_log()
{
	local f=$1
	local total=0
	local n

	if [ ! -f "$f" ] || [ ! -s "$f" ]; then
		echo 0
		return
	fi

	if grep -q 'DuckDB Execution Plan' "$f" 2>/dev/null; then
		# DuckDB ascii plan: under each EXPLAIN_ANALYZE node the 1st "N rows" is the
		# meta node (always 0); the 2nd is the root operator's returned rows.
		# Match EXPLAIN_ANALYZE (underscore) so the "EXPLAIN ANALYZE <sql>" dump is ignored.
		while IFS= read -r n; do
			total=$((total + n))
		done < <(
			awk '
				/EXPLAIN_ANALYZE/ { in_ea=1; ea_rows=0; next }
				in_ea && /[0-9][0-9,]*[[:space:]]+rows?/ {
					line=$0
					gsub(/,/, "", line)
					if (match(line, /[0-9]+[[:space:]]+rows?/)) {
						n = substr(line, RSTART, RLENGTH)
						gsub(/[^0-9]/, "", n)
						ea_rows++
						if (ea_rows == 2) { print n+0; in_ea=0 }
					}
				}
			' "$f"
		)
		echo "$total"
		return
	fi

	# Native Postgres/GPDB: sum top-level "actual ... rows=N" (unindented plan roots).
	while IFS= read -r n; do
		total=$((total + n))
	done < <(
		grep -E '^[^[:space:]].*\(actual time=[^)]*rows=[0-9]+' "$f" \
			| grep -oE 'rows=[0-9]+' \
			| cut -d= -f2
	)
	echo "$total"
}

# Classify SQL run from psql stderr + exit code → query_status for reports.
sql_query_status()
{
	local errfile=$1
	local rc=${2:-0}
	local err=""

	if [ -f "$errfile" ] && grep -Eiq 'canceling statement due to statement timeout|Executor Error: Query cancelled|query cancelled' "$errfile"; then
		echo "cancelled due to timeout"
		return 0
	fi

	if [ -f "$errfile" ]; then
		err=$(grep -E 'ERROR:' "$errfile" | head -1 | sed -E 's/^.*ERROR:[[:space:]]*//' | tr '|\n\r\t' '    ' | sed 's/  */ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 400 || true)
	fi
	if [ -n "$err" ]; then
		echo "ERROR:$err"
		return 0
	fi

	if [ "$rc" -ne 0 ]; then
		if [ -f "$errfile" ]; then
			err=$(tr '\n\r\t|' '    ' < "$errfile" | sed 's/  */ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 400 || true)
		fi
		if [ -n "$err" ]; then
			echo "ERROR:$err"
		else
			echo "ERROR:psql exit code $rc"
		fi
		return 0
	fi

	echo "succesfull"
}

end_step()
{
	local step=$1
	local end_file end_ts elapsed duration

	resolve_step_log_dirs "$step"
	end_file="$STEP_END_LOG_DIR/end_$step.log"

	end_ts=$(date +%F_%T)
	if [ -n "${STEP_START_NS:-}" ]; then
		if [ "$OSVERSION" == "Linux" ]; then
			elapsed="$(($(date +%s%N)-STEP_START_NS))"
		else
			elapsed="$(($(date +%s)-STEP_START_NS))"
		fi
		duration=$(format_duration "$elapsed")
	else
		STEP_START_TS=${STEP_START_TS:-unknown}
		duration="unknown"
	fi

	{
		echo "step=$step"
		echo "start=${STEP_START_TS:-unknown}"
		echo "end=$end_ts"
		echo "duration=$duration"
	} > "$end_file"

	echo "Step $step finished: start=${STEP_START_TS:-unknown} end=$end_ts duration=$duration"
}

create_hosts_file()
{
	get_version

	if [[ "$VERSION" == *"gpdb"* ]]; then
		psql -d postgres -v ON_ERROR_STOP=1 -t -A -c "SELECT DISTINCT hostname FROM gp_segment_configuration WHERE role = 'p' AND content >= 0" -o $LOCAL_PWD/segment_hosts.txt
	else
		#must be PostgreSQL
		echo $MASTER_HOST > $LOCAL_PWD/segment_hosts.txt
	fi
}

# segment_hosts.txt is written by the compile step (create_hosts_file).
# Missing/empty file usually means RUN_COMPILE_TPC=false, so later steps
# skip host loops and then hang on SSH without dsdgen/dbgen copied.
require_segment_hosts_file()
{
	local hosts_file="${1:-$LOCAL_PWD/segment_hosts.txt}"

	if [ ! -f "$hosts_file" ] || ! grep -q '[^[:space:]]' "$hosts_file" 2>/dev/null; then
		echo "ERROR: segment_hosts.txt is missing or empty ($hosts_file)."
		echo "В tpc_variables.sh включите compile, чтобы появились dsdgen и segment_hosts.txt"
		exit 1
	fi
}

# BatchMode + timeout: never prompt on TTY (background jobs hang in STAT T).
SSH_BATCH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes"

# True if $1 is this machine (short name, FQDN, localhost). Single-node
# PostgreSQL/GPDB should copy and generate locally — SSH is a cluster leftover.
is_local_host()
{
	local host="$1"
	local host_short local_short local_fqdn

	[ -z "$host" ] && return 1
	host=$(echo "$host" | tr -d '[:space:]')
	host_short=$(echo "$host" | awk -F. '{print $1}')
	local_short=$(hostname -s 2>/dev/null || true)
	local_fqdn=$(hostname -f 2>/dev/null || true)

	case "$host" in
		localhost|localhost.localdomain|127.0.0.1|::1) return 0 ;;
	esac
	if [ -n "$local_short" ]; then
		if [ "$host" = "$local_short" ] || [ "$host_short" = "$local_short" ]; then
			return 0
		fi
	fi
	if [ -n "$local_fqdn" ] && [ "$host" = "$local_fqdn" ]; then
		return 0
	fi
	if [ -n "${HOSTNAME:-}" ] && [ "$host" = "$HOSTNAME" ]; then
		return 0
	fi
	if [ -n "${MASTER_HOST:-}" ]; then
		if [ "$host" = "$MASTER_HOST" ] || [ "$host_short" = "$MASTER_HOST" ]; then
			return 0
		fi
	fi
	return 1
}

copy_to_host_home()
{
	local host="$1"
	shift

	if [ "$#" -lt 1 ]; then
		echo "ERROR: copy_to_host_home: missing files"
		exit 1
	fi
	if is_local_host "$host"; then
		echo "copy $* to local $ADMIN_HOME"
		cp "$@" "$ADMIN_HOME/"
	else
		echo "copy $* to $host:$ADMIN_HOME"
		scp $SSH_BATCH_OPTS "$@" "$host:$ADMIN_HOME/"
	fi
}

count_processes_on_host()
{
	local host="$1"
	local pattern="$2"
	local next_count

	if is_local_host "$host"; then
		next_count=$(ps -ef | grep -E -- "$pattern" | grep -v grep | wc -l)
	else
		next_count=$(ssh -n $SSH_BATCH_OPTS "$host" "ps -ef | grep -E -- '$pattern' | grep -v grep | wc -l" 2>&1 || true)
	fi
	if ! [[ $next_count =~ ^[0-9]+$ ]]; then
		next_count="1"
	fi
	echo "$next_count"
}

kill_processes_on_host()
{
	local host="$1"
	local pattern="$2"
	local k

	echo "$host: kill processes matching $pattern"
	if is_local_host "$host"; then
		for k in $(ps -ef | grep -E -- "$pattern" | grep -v grep | awk '{print $2}'); do
			[ -n "$k" ] || continue
			echo "killing $k"
			kill "$k" 2>/dev/null || true
		done
	else
		for k in $(ssh -n $SSH_BATCH_OPTS "$host" "ps -ef | grep -E -- '$pattern' | grep -v grep" | awk '{print $2}'); do
			[ -n "$k" ] || continue
			echo "killing $k"
			ssh -n $SSH_BATCH_OPTS "$host" "kill $k" || true
		done
	fi
}

start_generate_data_on_host()
{
	local host="$1"
	local scale="$2"
	local child="$3"
	local parallel="$4"
	local gen_data_path="$5"
	local logfile="$ADMIN_HOME/generate_data.${child}.log"

	if is_local_host "$host"; then
		echo "local generate_data.sh $scale $child $parallel $gen_data_path"
		(
			cd "$ADMIN_HOME"
			./generate_data.sh "$scale" "$child" "$parallel" "$gen_data_path"
		) > "$logfile" 2>&1 &
	else
		echo "ssh -n -f $host generate_data.sh $scale $child $parallel $gen_data_path"
		ssh -n -f $SSH_BATCH_OPTS "$host" "bash -c 'cd ~/; ./generate_data.sh $scale $child $parallel $gen_data_path > generate_data.$child.log 2>&1 < generate_data.$child.log &'"
	fi
}

require_ssh_access()
{
	local host="$1"
	local ssh_err
	local user="${ADMIN_USER:-$(whoami)}"

	if [ -z "$host" ]; then
		echo "ERROR: require_ssh_access: host is empty"
		exit 1
	fi

	if ! ssh_err=$(ssh -n $SSH_BATCH_OPTS "$host" "true" 2>&1); then
		echo "ERROR: у пользователя $user нет SSH на $host"
		echo "$ssh_err"
		exit 1
	fi
}

# Passwordless SSH is required only for remote segment hosts.
# Local-only (single-node PostgreSQL) uses cp / local generate_data.sh.
require_ssh_to_segment_hosts()
{
	local hosts_file="${1:-$LOCAL_PWD/segment_hosts.txt}"
	local host
	local seen="|"
	local remote_count=0

	require_segment_hosts_file "$hosts_file"

	while IFS= read -r host || [ -n "$host" ]; do
		host=$(echo "$host" | tr -d '[:space:]')
		[ -z "$host" ] && continue
		case "$seen" in
			*"|$host|"*) continue ;;
		esac
		seen="${seen}${host}|"
		if is_local_host "$host"; then
			continue
		fi
		remote_count=$((remote_count + 1))
		require_ssh_access "$host"
	done < "$hosts_file"

	if [ -n "${HOSTNAME:-}" ]; then
		host=$(echo "$HOSTNAME" | tr -d '[:space:]')
		if [ -n "$host" ]; then
			case "$seen" in
				*"|$host|"*) ;;
				*)
					if ! is_local_host "$host"; then
						remote_count=$((remote_count + 1))
						require_ssh_access "$host"
					fi
					;;
			esac
		fi
	fi

	if [ "$remote_count" -eq 0 ]; then
		echo "All segment hosts are local; SSH is not required"
	fi
}

# Ensure a rollout_*.log exists and is readable for server-side COPY FROM (reports).
# Missing files happen when the corresponding step was skipped (e.g. no compile_tpch run).
ensure_rollout_log_for_copy()
{
	local logfile="$1"
	mkdir -p "$(dirname "$logfile")"
	if [ ! -f "$logfile" ]; then
		echo "WARNING: $logfile not found (step may have been skipped); creating empty file for COPY"
		: > "$logfile"
	fi
	chmod a+r "$logfile" 2>/dev/null || true
}

# Apply one DDL file into target schema $1.
# Files with :SCHEMA use psql -v SCHEMA=; otherwise substitute TPC_SCHEMA / ext_TPC_SCHEMA (postgresql hardcodes).
# Extra args after $2 are passed to psql (e.g. -v EVERY_STORE_SALES=10).
run_ddl_sql_for_schema()
{
	local target_schema="$1"
	local sqlfile="$2"
	shift 2
	local base="${TPC_SCHEMA:-tpcds}"

	if grep -q ':SCHEMA' "$sqlfile"; then
		PGOPTIONS='--client-min-messages=warning' psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -P pager=off \
			-f "$sqlfile" -v SCHEMA="$target_schema" "$@"
	else
		sed -E \
			-e "s/\\bext_${base}\\./ext_${target_schema}./g" \
			-e "s/\\b${base}\\./${target_schema}./g" \
			-e "s/EXISTS ext_${base}\\b/EXISTS ext_${target_schema}/g" \
			-e "s/EXISTS ${base}\\b/EXISTS ${target_schema}/g" \
			-e "s/SCHEMA ext_${base}\\b/SCHEMA ext_${target_schema}/g" \
			-e "s/SCHEMA ${base}\\b/SCHEMA ${target_schema}/g" \
			"$sqlfile" \
		| PGOPTIONS='--client-min-messages=warning' psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -P pager=off "$@"
	fi
}

# Create all *.$filter.*.sql objects in $1 schema. Expects cwd/PWD = 03_ddl step dir.
# $2 = filter (gpdb|postgresql). Remaining args go to psql as -v ….
create_tables_for_schema()
{
	local schema="$1"
	local filter="$2"
	shift 2
	local i id schema_name table_name z table_name2 distribution DISTRIBUTED_BY

	for i in $(ls "$PWD"/*."$filter".*.sql); do
		id=$(echo "$i" | awk -F '.' '{print $1}')
		schema_name=$(echo "$i" | awk -F '.' '{print $2}')
		table_name=$(echo "$i" | awk -F '.' '{print $3}')
		start_log

		if [ "$filter" == "gpdb" ]; then
			if [ "${RANDOM_DISTRIBUTION:-false}" == "true" ]; then
				DISTRIBUTED_BY="DISTRIBUTED RANDOMLY"
			else
				DISTRIBUTED_BY=""
				if [ -f "$PWD/distribution.txt" ]; then
					for z in $(cat "$PWD/distribution.txt"); do
						table_name2=$(echo "$z" | awk -F '|' '{print $2}')
						if [ "$table_name2" == "$table_name" ]; then
							distribution=$(echo "$z" | awk -F '|' '{print $3}')
							DISTRIBUTED_BY="DISTRIBUTED BY (""$distribution"")"
						fi
					done
				fi
			fi
		else
			DISTRIBUTED_BY=""
		fi

		run_ddl_sql_for_schema "$schema" "$i" -v SMALL_STORAGE="${SMALL_STORAGE:-}" \
			-v MEDIUM_STORAGE="${MEDIUM_STORAGE:-}" -v LARGE_STORAGE="${LARGE_STORAGE:-}" \
			-v DISTRIBUTED_BY="$DISTRIBUTED_BY" "$@"
		log
	done
}

# Create EMPTY_SCHEMAS_CNT extra schemas (${TPC_SCHEMA}1..) with the same empty objects as the main schema.
# $1 = filter; remaining optional psql -v args for table DDL (partition EVERY_*, etc.).
create_empty_catalog_schemas()
{
	local filter="$1"
	shift
	local n i schema psql_count
	n="${EMPTY_SCHEMAS_CNT:-0}"
	if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -le 0 ]; then
		return 0
	fi

	echo "Creating DDL for $n empty catalog schema(s) (${TPC_SCHEMA}1..${TPC_SCHEMA}${n})"
	for i in $(seq 1 "$n"); do
		schema="${TPC_SCHEMA}${i}"
		echo "Running stream $i: Creating DDL for schema $schema"
		echo "Now executing DDLs. This may take a while..."
		create_tables_for_schema "$schema" "$filter" "$@" &
	done

	sleep 10
	psql_count=$(ps -ef | grep psql | grep 03_ddl | grep -v grep | wc -l)
	while [ "$psql_count" -gt "0" ]; do
		echo -ne "."
		sleep 10
		psql_count=$(ps -ef | grep psql | grep 03_ddl | grep -v grep | wc -l)
	done
	echo "done."
	echo ""
}
