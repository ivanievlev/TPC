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

# Validate SKIP_QUERIES_LIST: empty or comma-separated integers in 1..99.
# Examples OK: "", "85", "1,64,85". Bad: "164,85", "n4".
validate_skip_queries_list()
{
	local list="${1:-}"
	local item n
	list=$(echo "$list" | tr -d '[:space:]')
	if [ -z "$list" ]; then
		return 0
	fi
	IFS=',' read -ra _skip_items <<< "$list"
	for item in "${_skip_items[@]}"; do
		if [ -z "$item" ]; then
			echo "ERROR: SKIP_QUERIES_LIST has an empty entry (got: ${1})"
			echo "Expected comma-separated query numbers in 1..99, e.g. \"85\" or \"1,64,85\"."
			exit 1
		fi
		if ! [[ "$item" =~ ^[0-9]+$ ]]; then
			echo "ERROR: SKIP_QUERIES_LIST invalid entry \"$item\" (must be an integer 1..99)."
			echo "Example: SKIP_QUERIES_LIST=\"85\" or SKIP_QUERIES_LIST=\"1,64,85\"."
			exit 1
		fi
		# Force decimal (avoid octal for 08/09); strip leading zeros.
		n=$((10#$item))
		if [ "$n" -lt 1 ] || [ "$n" -gt 99 ]; then
			echo "ERROR: SKIP_QUERIES_LIST query $n is out of range (must be 1..99)."
			echo "Example: SKIP_QUERIES_LIST=\"85\" or SKIP_QUERIES_LIST=\"1,64,85\"."
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
