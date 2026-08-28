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

# .dat / gpfdist subdirectory name (not a clone path).
# EXTERNAL_FILE_DIRECTORY_PATH is only the root. .dat files:
#   GP:  $EXTERNAL_FILE_DIRECTORY_PATH/primary/gpseg<N>/$DAT_FILE_SUBDIRECTORY_NAME
#   PG:  $EXTERNAL_FILE_DIRECTORY_PATH/${DAT_FILE_SUBDIRECTORY_NAME}_<child>
# Do not take these from positional $42/$43 here: functions.sh is also sourced
# from the top-level rollout.sh, where those slots are other flags (e.g. false).

normalize_dat_file_subdirectory_name()
{
	local n="$DAT_FILE_SUBDIRECTORY_NAME"
	n="${n#"${n%%[![:space:]]*}"}"
	n="${n%"${n##*[![:space:]]}"}"
	n="${n%/}"
	# Allow leftover "/arenadata" (old INSTALL_DIR); reject nested paths.
	if [[ "$n" == */* ]]; then
		if [[ "$n" =~ ^/[^/]+$ ]]; then
			n="${n#/}"
		else
			echo "ERROR: DAT_FILE_SUBDIRECTORY_NAME must be a single directory name (got: ${DAT_FILE_SUBDIRECTORY_NAME})."
			echo "Example: DAT_FILE_SUBDIRECTORY_NAME=\"datfiles\" → /tmp/primary/gpseg0/datfiles"
			exit 1
		fi
	fi
	if [ -z "$n" ] || [ "$n" = "." ] || [ "$n" = ".." ]; then
		echo "ERROR: DAT_FILE_SUBDIRECTORY_NAME must be a single directory name (e.g. datfiles)."
		exit 1
	fi
	if [[ ! "$n" =~ ^[A-Za-z0-9._-]+$ ]]; then
		echo "ERROR: DAT_FILE_SUBDIRECTORY_NAME contains invalid characters: $n"
		echo "Use a name like datfiles (no slashes or spaces)."
		exit 1
	fi
	DAT_FILE_SUBDIRECTORY_NAME="$n"
}

normalize_external_file_directory_path()
{
	local p="$EXTERNAL_FILE_DIRECTORY_PATH"
	p="${p#"${p%%[![:space:]]*}"}"
	p="${p%"${p##*[![:space:]]}"}"
	p="${p%/}"
	if [[ "$p" != /* ]]; then
		echo "ERROR: EXTERNAL_FILE_DIRECTORY_PATH must be an absolute directory (got: ${EXTERNAL_FILE_DIRECTORY_PATH:-empty})."
		echo "Use the root only (e.g. /tmp). .dat files are written under"
		echo "  \$EXTERNAL_FILE_DIRECTORY_PATH/primary/gpseg<N>/\$DAT_FILE_SUBDIRECTORY_NAME"
		exit 1
	fi
	if [[ "$p" == */../* || "$p" == */.. || "$p" == ../* || "$p" == .. ]]; then
		echo "ERROR: EXTERNAL_FILE_DIRECTORY_PATH must not contain '..' (got: $p)."
		exit 1
	fi
	EXTERNAL_FILE_DIRECTORY_PATH="$p"
}

# Greenplum .dat dir: $EXTERNAL_FILE_DIRECTORY_PATH/primary/gpseg<N>/$DAT_FILE_SUBDIRECTORY_NAME
# N comes from the segment datadir basename (e.g. /data1/primary/gpseg0 → gpseg0).
gp_dat_dir()
{
	local datadir="$1"
	local leaf
	if [ -z "$datadir" ]; then
		echo "ERROR: gp_dat_dir: empty segment datadir" >&2
		exit 1
	fi
	leaf=$(basename "$datadir")
	echo "${EXTERNAL_FILE_DIRECTORY_PATH}/primary/${leaf}/${DAT_FILE_SUBDIRECTORY_NAME}"
}

# PostgreSQL parallel chunks: $EXTERNAL_FILE_DIRECTORY_PATH/<name>_<child>
pg_chunk_dat_dir()
{
	local child="$2"
	echo "${EXTERNAL_FILE_DIRECTORY_PATH}/${DAT_FILE_SUBDIRECTORY_NAME}_${child}"
}

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

# Used by 05_sql: drop OS page cache only before iteration 1 when DROP_CACHE_BEFORE_SQL=true.
# Later SINGLE_USER_ITERATIONS keep the cache from the first pass.
drop_os_page_cache_before_sql_iteration()
{
	local iter="${1:-1}"
	if [ "${DROP_CACHE_BEFORE_SQL}" != "true" ]; then
		return 0
	fi
	if [ "$iter" -gt 1 ]; then
		echo "DROP_CACHE_BEFORE_SQL: SQL iteration $iter - keeping OS page cache (no drop after first iteration)"
		return 0
	fi
	drop_os_page_cache
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

# Normalize one TCP port into the named variable (1..65535). Empty → 5432.
_tpc_set_port_var()
{
	local name="$1"
	local -n _portref="$1"
	local v n
	v="${_portref-}"
	v="${v#"${v%%[![:space:]]*}"}"
	v="${v%"${v##*[![:space:]]}"}"
	if [ -z "$v" ]; then
		v="5432"
	fi
	if ! [[ "$v" =~ ^[0-9]+$ ]]; then
		echo "ERROR: $name must be an integer 1..65535 (got: ${v})." >&2
		exit 1
	fi
	n=$((10#$v))
	if [ "$n" -lt 1 ] || [ "$n" -gt 65535 ]; then
		echo "ERROR: $name must be an integer 1..65535 (got: ${v})." >&2
		exit 1
	fi
	_portref="$n"
	export "$name"
}

# libpq uses PGPORT/PGHOST. PGPORT_WRITE vs PGPORT_SELECT come from tpc_variables.sh.
# Empty PGHOST → Unix socket. Set PGHOST=127.0.0.1 for HAProxy TCP.
apply_tpc_pgport()
{
	if [ -z "${PGPORT_WRITE:-}" ] && [ -z "${PGPORT_SELECT:-}" ]; then
		if [ -n "${PGPORT:-}" ]; then
			PGPORT_WRITE="$PGPORT"
			PGPORT_SELECT="$PGPORT"
		elif [ -n "${PORT:-}" ]; then
			PGPORT_WRITE="$PORT"
			PGPORT_SELECT="$PORT"
		fi
	fi
	_tpc_set_port_var PGPORT_WRITE
	_tpc_set_port_var PGPORT_SELECT

	if [ -z "${PGPORT:-}" ]; then
		PGPORT="$PGPORT_WRITE"
	fi
	_tpc_set_port_var PGPORT

	PGHOST="${PGHOST#"${PGHOST%%[![:space:]]*}"}"
	PGHOST="${PGHOST%"${PGHOST##*[![:space:]]}"}"
	if [ -z "$PGHOST" ]; then
		unset PGHOST
	else
		export PGHOST
	fi
}

# Active libpq PGPORT: SELECT for 05_sql / 07_multi_user, WRITE for all other steps.
set_tpc_pgport_for_step()
{
	local base
	base=$(basename "$1")
	case "$base" in
		05_sql|07_multi_user)
			PGPORT="${PGPORT_SELECT:-5432}"
			;;
		*)
			PGPORT="${PGPORT_WRITE:-5432}"
			;;
	esac
	export PGPORT
}

source_bashrc()
{
	# Keep harness libpq target; admin profile may overwrite PGHOST/PGPORT*.
	local tpc_pghost="${PGHOST-}"
	local tpc_pgport="${PGPORT-}"
	local tpc_pgport_write="${PGPORT_WRITE-}"
	local tpc_pgport_select="${PGPORT_SELECT-}"

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

	PGHOST="$tpc_pghost"
	PGPORT_WRITE="$tpc_pgport_write"
	PGPORT_SELECT="$tpc_pgport_select"
	PGPORT="$tpc_pgport"
	# After admin profile. Must run before get_version/psql.
	apply_tpc_pgport

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

# Active skip list for the current TPC_MODE (internal alias used by 05/07).
resolve_tpc_skip_queries_list()
{
	case "${TPC_MODE:-TPC-DS}" in
		TPC-H) SKIP_QUERIES_LIST="${SKIP_TPCH_QUERIES_LIST:-}" ;;
		*) SKIP_QUERIES_LIST="${SKIP_TPCDS_QUERIES_LIST:-}" ;;
	esac
	export SKIP_QUERIES_LIST
}

_tpc_skip_list_var_name()
{
	case "${TPC_MODE:-TPC-DS}" in
		TPC-H) echo "SKIP_TPCH_QUERIES_LIST" ;;
		*) echo "SKIP_TPCDS_QUERIES_LIST" ;;
	esac
}

# Validate the active skip list: empty or comma-separated integers in 1..TPC_QUERY_ID_MAX.
validate_skip_queries_list()
{
	local list="${1:-}"
	local item n
	local max="${TPC_QUERY_ID_MAX:-99}"
	local vname
	vname=$(_tpc_skip_list_var_name)
	list=$(echo "$list" | tr -d '[:space:]')
	if [ -z "$list" ]; then
		return 0
	fi
	IFS=',' read -ra _skip_items <<< "$list"
	for item in "${_skip_items[@]}"; do
		if [ -z "$item" ]; then
			echo "ERROR: ${vname} has an empty entry (got: ${1})"
			echo "Expected comma-separated query numbers in 1..${max}."
			exit 1
		fi
		if ! [[ "$item" =~ ^[0-9]+$ ]]; then
			echo "ERROR: ${vname} invalid entry \"$item\" (must be an integer 1..${max})."
			exit 1
		fi
		# Force decimal (avoid octal for 08/09); strip leading zeros.
		n=$((10#$item))
		if [ "$n" -lt 1 ] || [ "$n" -gt "$max" ]; then
			echo "ERROR: ${vname} query $n is out of range (must be 1..${max} for ${TPC_MODE:-TPC-DS})."
			exit 1
		fi
	done
}

# Return 0 if query number $1 is listed in the active skip list ($2 optional override).
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
	apply_tpc_pgport
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

	# Optional 6th/7th fields for SQL reports (query_status, backend_host).
	if [ -n "${QUERY_STATUS:-}" ]; then
		qs=$(printf '%s' "$QUERY_STATUS" | tr '|\n\r\t' '    ' | sed 's/  */ /g' | head -c 500)
		bh=$(printf '%s' "${QUERY_BACKEND_HOST:-unknown}" | tr '|\n\r\t' '    ' | sed 's/  */ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 200)
		[ -z "$bh" ] && bh="unknown"
		printf "$timing|$id|$schema_name.$table_name|$tuples|%02d:%02d:%02d.%03d|%s|%s\n" "$((S/3600%24))" "$((S/60%60))" "$((S%60))" "${M}" "$qs" "$bh" | tee -a "$out_file"
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

# DuckDB instance-level GUCs (memory_limit, threads, …) cannot be SET after
# DuckDB has been initialized in this backend. PgBouncer/HAProxy reuse backends
# from earlier queries, so recycle first. force_execution is last (not init-locked).
append_duckdb_session_sets()
{
	PSQL_SESSION_SETS="${PSQL_SESSION_SETS} SET duckdb.force_execution TO true;"
}

# Run a TPC query file in one psql session and record the backend hostname.
# A second connection (HAProxy/PgBouncer round-robin) would hit another node,
# so the probe must share the session with the workload. Hostname is read from
# the server OS because PgBouncer often uses a unix socket (inet_server_addr
# is then NULL). Must not CREATE TEMP TABLE: standbys are read-only.
# DuckDB SET must come after the probe (PSQL_SESSION_SETS). Only force_execution
# is per-session; memory/threads are ALTER DATABASE in 02_init.
#
# $1 SQL file  $2 stdout  $3 stderr  $4 host file  $5 EXPLAIN_ANALYZE value
# Uses: DBNAME, PSQL_SESSION_SETS, ON_ERROR_STOP, RUN_SQL_FROM_ROLE (optional).
# Sets QUERY_BACKEND_HOST. Returns psql exit code.
psql_run_sql_capturing_host()
{
	local sql_file=$1
	local stdout_file=$2
	local stderr_file=$3
	local host_file=$4
	local explain_val=$5
	local wrapper rc
	local role_opts=()

	: > "$host_file"
	wrapper=$(mktemp)
	# Standbys reject CREATE TEMP TABLE. Session GUCs via set_config are allowed.
	cat > "$wrapper" <<EOSQL
DO \$\$
DECLARE
	h text;
BEGIN
	BEGIN
		h := NULLIF(btrim(pg_catalog.pg_read_file('/etc/hostname', 0, 256), E'\n\r '), '');
	EXCEPTION WHEN OTHERS THEN
		h := NULL;
	END;
	IF h IS NULL OR h = '' THEN
		BEGIN
			h := NULLIF(btrim(pg_catalog.pg_read_file('/proc/sys/kernel/hostname', 0, 256), E'\n\r '), '');
		EXCEPTION WHEN OTHERS THEN
			h := NULL;
		END;
	END IF;
	IF h IS NULL OR h = '' THEN
		BEGIN
			h := host(inet_server_addr());
		EXCEPTION WHEN OTHERS THEN
			h := NULL;
		END;
	END IF;
	-- FQDN → short name (luka-adp-2.ru-central1.internal → luka-adp-2); keep IPs.
	IF h IS NOT NULL AND h <> '' AND h !~ '^[0-9.]+$' AND position(':' in h) = 0 THEN
		h := split_part(h, '.', 1);
	END IF;
	PERFORM set_config('tpc.backend_host', COALESCE(NULLIF(h, ''), 'unknown'), false);
END
\$\$;
\\o $host_file
SELECT current_setting('tpc.backend_host', true);
\\o
$PSQL_SESSION_SETS
\\i $sql_file
EOSQL

	if [ -n "${RUN_SQL_FROM_ROLE:-}" ]; then
		role_opts=(-U "$RUN_SQL_FROM_ROLE")
	fi

	psql -d "$DBNAME" "${role_opts[@]}" -v ON_ERROR_STOP="$ON_ERROR_STOP" -A -q -t -P pager=off -v EXPLAIN_ANALYZE="$explain_val" -f "$wrapper" >"$stdout_file" 2>"$stderr_file"
	rc=$?
	rm -f "$wrapper"

	QUERY_BACKEND_HOST="unknown"
	if [ -s "$host_file" ]; then
		QUERY_BACKEND_HOST=$(tr -d '\r' < "$host_file" | head -n 1 | tr '|\t' '  ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	fi
	[ -z "$QUERY_BACKEND_HOST" ] && QUERY_BACKEND_HOST="unknown"
	# FQDN → short name; do not chop IPv4/IPv6.
	if [ "$QUERY_BACKEND_HOST" != "unknown" ] && [[ ! "$QUERY_BACKEND_HOST" =~ ^[0-9.]+$ ]] && [[ "$QUERY_BACKEND_HOST" != *:* ]]; then
		QUERY_BACKEND_HOST="${QUERY_BACKEND_HOST%%.*}"
	fi
	return "$rc"
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
# Missing/empty file means 00_compile did not finish (create_hosts_file).
require_segment_hosts_file()
{
	local hosts_file="${1:-$LOCAL_PWD/segment_hosts.txt}"

	if [ ! -f "$hosts_file" ] || ! grep -q '[^[:space:]]' "$hosts_file" 2>/dev/null; then
		echo "ERROR: segment_hosts.txt is missing or empty ($hosts_file)."
		echo "Compile (00_compile_tpcds / 00_compile_tpch) must finish first so dsdgen/dbgen and this hosts file exist."
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

# 02_init: ADMIN_USER must be able to compile, load, and ssh from this clone.
require_admin_access_to_clone()
{
	local repo="$LOCAL_PWD"
	local user="${ADMIN_USER:-$(whoami)}"
	local me
	local probe compile_ds compile_h
	local f d

	me=$(id -un)

	echo "############################################################################"
	echo "02_init: checking ADMIN_USER=$user can run compile/load/ssh from $repo"
	echo "############################################################################"

	if [ "$me" != "$user" ]; then
		echo "ERROR: 02_init is running as $me, but ADMIN_USER=$user."
		echo "$user must run compile/load/ssh from the clone directory $repo."
		exit 1
	fi

	if [ ! -d "$repo" ]; then
		echo "ERROR: clone directory $repo does not exist."
		exit 1
	fi

	if ! { test -r "$repo/tpc.sh" && test -x "$repo/rollout.sh" && test -r "$repo/functions.sh"; }; then
		echo "ERROR: ADMIN_USER=$user cannot read/execute TPC scripts in $repo"
		exit 1
	fi

	mkdir -p "$repo/log" || {
		echo "ERROR: ADMIN_USER=$user cannot create $repo/log"
		exit 1
	}
	probe="$repo/log/.admin_write_probe_$$"
	if ! touch "$probe" 2>/dev/null; then
		echo "ERROR: ADMIN_USER=$user cannot write to clone $repo (needed for compile, log/, load)."
		echo "Grant $user write access to $repo (compile dirs, log/, scripts)."
		exit 1
	fi
	rm -f "$probe"

	compile_ds="$repo/tpcds/00_compile_tpcds/tools"
	compile_h="$repo/tpch/00_compile_tpch"
	for d in "$compile_ds" "$compile_h"; do
		if [ -d "$d" ] && [ ! -w "$d" ]; then
			echo "ERROR: ADMIN_USER=$user cannot write $d (compile step)."
			exit 1
		fi
	done

	for f in \
		"$repo/tpcds/04_load/rollout.sh" \
		"$repo/tpcds/04_load/start_gpfdist.sh" \
		"$repo/tpch/04_load/rollout.sh" \
		"$repo/tpch/04_load/start_gpfdist.sh"
	do
		if [ -f "$f" ] && [ ! -r "$f" ]; then
			echo "ERROR: ADMIN_USER=$user cannot read $f (load step)."
			exit 1
		fi
	done

	get_version
	if [[ "$VERSION" == *"gpdb"* ]]; then
		if [ ! -f "$repo/segment_hosts.txt" ] || ! grep -q '[^[:space:]]' "$repo/segment_hosts.txt" 2>/dev/null; then
			echo "segment_hosts.txt missing; listing hosts from gp_segment_configuration"
			create_hosts_file
		fi
		require_ssh_to_segment_hosts "$repo/segment_hosts.txt"
	else
		echo "PostgreSQL: SSH to segment hosts is not required"
	fi

	echo "ADMIN_USER=$user has access to compile/load/ssh from $repo"
	echo ""
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

# SQL logs gained a 7th field (backend_host). Pad legacy 6-field lines so COPY still works.
pad_sql_log_backend_host()
{
	local logfile="$1"
	local tmp
	[ -f "$logfile" ] && [ -s "$logfile" ] || return 0
	tmp=$(mktemp)
	awk -F'|' 'NF==6 { print $0 "|unknown"; next } { print }' "$logfile" > "$tmp" && mv "$tmp" "$logfile"
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

# Detect HDD vs SSD for PGConfig (rotational=0 → SSD). Falls back to HDD.
pgconfig_detect_drive_type()
{
	local path="${1:-/}"
	local src kname rotational

	if [ ! -e "$path" ]; then
		path="/"
	fi

	src=$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $1}')
	if [ -z "$src" ]; then
		echo "HDD"
		return 0
	fi

	case "$src" in
		*nvme*)
			echo "SSD"
			return 0
			;;
	esac

	if command -v lsblk >/dev/null 2>&1; then
		kname=$(lsblk -no PKNAME "$src" 2>/dev/null | awk 'NF { print; exit }')
		if [ -z "$kname" ]; then
			kname=$(lsblk -no KNAME "$src" 2>/dev/null | awk 'NF { print; exit }')
		fi
	fi

	if [ -z "$kname" ]; then
		kname=$(basename "$src")
		if echo "$kname" | grep -q '^nvme'; then
			kname=$(echo "$kname" | sed 's/p[0-9][0-9]*$//')
		else
			kname=$(echo "$kname" | sed 's/[0-9][0-9]*$//')
		fi
	fi

	if [ -n "$kname" ] && [ -f "/sys/block/$kname/queue/rotational" ]; then
		rotational=$(cat "/sys/block/$kname/queue/rotational")
		if [ "$rotational" = "0" ]; then
			echo "SSD"
			return 0
		fi
		echo "HDD"
		return 0
	fi

	echo "HDD"
}

# shared_buffers / max_connections / wal_buffers and similar only apply after restart.
# ALTER SYSTEM writes postgresql.auto.conf; pg_reload_conf() is not enough.
# Use stop+start with an absolute -D. `pg_ctl restart` reuses postmaster.opts, which
# may contain a relative -D (e.g. "lukavega") resolved against the TPC cwd.
pgconfig_restart_postgres()
{
	local pgdata pg_ctl_bin postgres_bin

	pgdata=$(psql -d postgres -v ON_ERROR_STOP=1 -tA -c "SHOW data_directory")
	if [ -z "$pgdata" ]; then
		echo "ERROR: could not determine data_directory for PostgreSQL restart"
		return 1
	fi
	if command -v readlink >/dev/null 2>&1; then
		pgdata=$(readlink -f "$pgdata")
	fi

	pg_ctl_bin=$(command -v pg_ctl 2>/dev/null || true)
	if [ -z "$pg_ctl_bin" ]; then
		postgres_bin=$(command -v postgres 2>/dev/null || true)
		if [ -n "$postgres_bin" ] && [ -x "$(dirname "$postgres_bin")/pg_ctl" ]; then
			pg_ctl_bin="$(dirname "$postgres_bin")/pg_ctl"
		fi
	fi
	if [ -z "$pg_ctl_bin" ]; then
		echo "ERROR: pg_ctl not found; cannot restart PostgreSQL to apply ALTER SYSTEM settings"
		return 1
	fi

	echo "APPLY_PGCONFIG_PARAMETERS: $pg_ctl_bin -D $pgdata stop -w -t 120 -m fast"
	"$pg_ctl_bin" -D "$pgdata" stop -w -t 120 -m fast
	echo "APPLY_PGCONFIG_PARAMETERS: $pg_ctl_bin -D $pgdata -l $pgdata/logfile start -w -t 120"
	"$pg_ctl_bin" -D "$pgdata" -l "$pgdata/logfile" start -w -t 120
	psql -d postgres -v ON_ERROR_STOP=1 -tA -c "SELECT 1" >/dev/null
}

# Instance-level pg_duckdb GUCs (memory/threads). Set once on DBNAME so every
# new session (primary and replicas) inherits them before DuckDB starts.
# ALTER DATABASE replicates via WAL; ALTER SYSTEM would stay on the primary.
apply_duckdb_database_gucs()
{
	local db guc val line

	if [ "${RUN_SQL_WITH_DUCKDB:-false}" != "true" ]; then
		return 0
	fi
	db="${DBNAME:-}"
	if [ -z "$db" ]; then
		echo "APPLY_DUCKDB_GUC: skip (DBNAME is empty)"
		return 0
	fi

	echo "############################################################################"
	echo "APPLY_DUCKDB_GUC: ALTER DATABASE $db SET duckdb.* from tpc_variables.sh"
	echo "############################################################################"
	while IFS='|' read -r guc val; do
		[ -z "$guc" ] && continue
		line="ALTER DATABASE $db SET $guc TO '$val'"
		echo "APPLY_DUCKDB_GUC: $line"
		if ! psql -d "$db" -v ON_ERROR_STOP=1 -c "$line"; then
			echo "ERROR: failed to $line (is pg_duckdb installed in $db?)"
			return 1
		fi
	done <<EOF
duckdb.memory_limit|${DUCKDB_MEMORY_LIMIT:-4GB}
duckdb.threads|${DUCKDB_THREADS:--1}
duckdb.max_workers_per_postgres_scan|${DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN:-2}
duckdb.threads_for_postgres_scan|${DUCKDB_THREADS_FOR_POSTGRES_SCAN:-2}
EOF
	return 0
}

# When APPLY_PGCONFIG_PARAMETERS=true, fetch recommended GUCs from
# https://api.pgconfig.org for this host's CPU/RAM/disk and apply them
# with ALTER SYSTEM + PostgreSQL restart. PostgreSQL only.
# DuckDB instance GUCs are applied here as well (ALTER DATABASE, no extra restart).
# When false, leave postgresql.conf unchanged but still apply DuckDB database GUCs.
apply_pgconfig_parameters()
{
	local need_restart=0

	get_version
	if [[ "$VERSION" == *"gpdb"* ]]; then
		echo "APPLY_PGCONFIG_PARAMETERS: skipped (Greenplum is not supported by pgconfig)"
		return 0
	fi

	if [ "${APPLY_PGCONFIG_PARAMETERS:-false}" != "true" ]; then
		echo "APPLY_PGCONFIG_PARAMETERS=false: leaving current PostgreSQL parameters unchanged"
	else

	if ! psql -d postgres -v ON_ERROR_STOP=1 -tA -c "SELECT 1" >/dev/null 2>&1; then
		echo "ERROR: APPLY_PGCONFIG_PARAMETERS=true requires a running PostgreSQL instance"
		return 1
	fi

	if ! command -v curl >/dev/null 2>&1; then
		echo "ERROR: APPLY_PGCONFIG_PARAMETERS=true requires curl to call https://api.pgconfig.org"
		return 1
	fi

	local cpus ram_gb total_ram pg_major arch os_type drive_type pgdata
	local url sql_file line name exists applied skipped
	local mem_kb

	cpus=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
	if ! [[ "$cpus" =~ ^[0-9]+$ ]] || [ "$cpus" -lt 1 ]; then
		cpus=1
	fi

	if [ -f /proc/meminfo ]; then
		mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
		if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
			ram_gb=$(( (mem_kb + 1048576 - 1) / 1048576 ))
		else
			ram_gb=2
		fi
	else
		ram_gb=2
	fi
	if [ "$ram_gb" -lt 1 ]; then
		ram_gb=1
	fi
	total_ram="${ram_gb}GB"

	pg_major=$(psql -d postgres -v ON_ERROR_STOP=1 -tA -c "SHOW server_version" | sed 's/^\([0-9][0-9]*\).*/\1/')
	if [ -z "$pg_major" ]; then
		echo "ERROR: could not detect PostgreSQL major version for pgconfig"
		return 1
	fi

	case "$(uname -m)" in
		x86_64|amd64) arch="x86-64" ;;
		i386|i686) arch="i686" ;;
		*) arch="x86-64" ;;
	esac

	os_type=$(uname -s)
	case "$os_type" in
		Linux) os_type="Linux" ;;
		Darwin) os_type="Unix" ;;
		MINGW*|MSYS*|CYGWIN*|Windows*) os_type="Windows" ;;
		*) os_type="Linux" ;;
	esac

	pgdata=$(psql -d postgres -v ON_ERROR_STOP=1 -tA -c "SHOW data_directory")
	drive_type=$(pgconfig_detect_drive_type "$pgdata")

	mkdir -p "$LOCAL_PWD/log"
	sql_file="$LOCAL_PWD/log/pgconfig_alter_system.sql"

	url="https://api.pgconfig.org/v1/tuning/get-config?environment_name=DW&format=alter_system&pg_version=${pg_major}&total_ram=${total_ram}&cpus=${cpus}&drive_type=${drive_type}&os_type=${os_type}&arch=${arch}"

	echo "############################################################################"
	echo "APPLY_PGCONFIG_PARAMETERS: fetching recommended postgresql.conf from pgconfig"
	echo "  cpus=$cpus total_ram=$total_ram drive_type=$drive_type pg_version=$pg_major os_type=$os_type arch=$arch"
	echo "  environment_name=DW (TPC)"
	echo "  $url"
	echo "############################################################################"

	if ! curl -fsSL "$url" -o "$sql_file"; then
		echo "ERROR: failed to download pgconfig recommendations from $url"
		return 1
	fi

	if ! grep -q 'ALTER SYSTEM SET' "$sql_file"; then
		echo "ERROR: pgconfig API did not return ALTER SYSTEM statements. Response:"
		cat "$sql_file"
		return 1
	fi

	applied=0
	skipped=0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			''|--*)
				continue
				;;
		esac
		echo "$line" | grep -qi '^ALTER SYSTEM SET ' || continue

		name=$(printf '%s\n' "$line" | awk '{ print $4 }')
		if [ -z "$name" ]; then
			continue
		fi

		# Do not widen listen_addresses on a test host.
		if [ "$name" = "listen_addresses" ]; then
			echo "APPLY_PGCONFIG_PARAMETERS: skip $name"
			skipped=$((skipped + 1))
			continue
		fi

		exists=$(psql -d postgres -v ON_ERROR_STOP=1 -tA -c "SELECT count(*) FROM pg_settings WHERE name = '$name'")
		if [ "$exists" != "1" ]; then
			echo "APPLY_PGCONFIG_PARAMETERS: skip unknown GUC $name"
			skipped=$((skipped + 1))
			continue
		fi

		echo "APPLY_PGCONFIG_PARAMETERS: $line"
		if ! psql -d postgres -v ON_ERROR_STOP=1 -c "$line"; then
			echo "APPLY_PGCONFIG_PARAMETERS: failed to apply $name, skipping"
			skipped=$((skipped + 1))
			continue
		fi
		applied=$((applied + 1))
	done < "$sql_file"

	echo "APPLY_PGCONFIG_PARAMETERS: applied=$applied skipped=$skipped"
		need_restart=1
	fi

	apply_duckdb_database_gucs || return 1

	if [ "$need_restart" -eq 1 ]; then
		pgconfig_restart_postgres
	fi

	return 0
}

# Dump ALTER SYSTEM overlay into log/postgres_test_parameters.txt (readable snapshot).
# Do not copy PGDATA/postgresql.auto.conf: it is mode 600 and unreadable to other users.
log_postgres_test_parameters()
{
	local db out pgdata auto_conf

	db="${DBNAME:-postgres}"
	mkdir -p "$LOCAL_PWD/log"
	out="$LOCAL_PWD/log/postgres_test_parameters.txt"
	rm -f "$LOCAL_PWD/log/postgresql.auto.conf" 2>/dev/null || true
	pgdata=$(psql -d "$db" -v ON_ERROR_STOP=1 -tA -c "SHOW data_directory")
	auto_conf=""
	if [ -n "$pgdata" ]; then
		auto_conf="$pgdata/postgresql.auto.conf"
	fi

	{
		echo "############################################################################"
		echo "PostgreSQL parameters for this test run"
		echo "APPLY_PGCONFIG_PARAMETERS=${APPLY_PGCONFIG_PARAMETERS:-false}"
		echo "RUN_SQL_WITH_DUCKDB=${RUN_SQL_WITH_DUCKDB:-false}"
		echo "PGPORT_WRITE=${PGPORT_WRITE:-5432} PGPORT_SELECT=${PGPORT_SELECT:-5432} PGPORT=${PGPORT:-5432} PGHOST=${PGHOST:-}"
		echo "############################################################################"
		if [ -n "$auto_conf" ] && [ -r "$auto_conf" ]; then
			cat "$auto_conf"
		else
			psql -d "$db" -v ON_ERROR_STOP=0 -c "SELECT sourcefile, name, setting FROM pg_file_settings WHERE sourcefile LIKE '%postgresql.auto.conf' ORDER BY name;"
		fi
		echo "############################################################################"
		if [ "${RUN_SQL_WITH_DUCKDB:-false}" = "true" ]; then
			echo "DuckDB database GUCs (SHOW):"
			psql -d "$db" -v ON_ERROR_STOP=0 -c "SELECT name, setting FROM pg_settings WHERE name LIKE 'duckdb.%' ORDER BY name;"
			echo "############################################################################"
		fi
	} | tee "$out"
	chmod a+r "$out" 2>/dev/null || true
}

# First-column-only templates.lst for dsqgen (column 2+ is query labels).
dsqgen_input_from_templates_lst()
{
	local src="$1"
	local dst="$2"
	if [ ! -f "$src" ]; then
		echo "ERROR: templates list not found: $src"
		return 1
	fi
	awk '
		/^[[:space:]]*--/ { next }
		/^[[:space:]]*$/ { next }
		{ print $1 }
	' "$src" > "$dst"
}

# SQL that creates TEMP TABLE tpc_query_labels from templates.lst (filename<TAB>labels).
emit_tpc_query_labels_sql()
{
	local lst="$1"
	if [ ! -f "$lst" ]; then
		echo "CREATE TEMP TABLE tpc_query_labels (id text PRIMARY KEY, template text, query_label text);"
		return 0
	fi
	awk -f - "$lst" <<'AWK'
BEGIN {
	print "CREATE TEMP TABLE tpc_query_labels (id text PRIMARY KEY, template text, query_label text);"
}
/^[[:space:]]*--/ { next }
NF < 1 { next }
{
	fn = $1
	labels = $0
	sub(/^[^ \t]+[ \t]*/, "", labels)
	if (labels == $0)
		labels = ""
	n = 0
	if (fn ~ /^query[0-9]+\.tpl$/)
		n = substr(fn, 6, length(fn) - 9) + 0
	else if (fn ~ /^[0-9]+\.sql$/)
		n = substr(fn, 1, length(fn) - 4) + 0
	else
		next
	gsub(/'/, "''", fn)
	gsub(/'/, "''", labels)
	if (!started) {
		print "INSERT INTO tpc_query_labels (id, template, query_label) VALUES"
		started = 1
	} else
		print ","
	printf "('%02d', '%s', '%s')", n, fn, labels
}
END {
	if (started)
		print ";"
}
AWK
}

# Run a report SQL file after loading query labels from templates.lst.
# Extra args are passed to psql (e.g. -P pager=off -P format=aligned -P border=1).
psql_report_with_query_labels()
{
	local lst="$1"
	local sqlfile="$2"
	shift 2
	local tmp
	tmp=$(mktemp)
	emit_tpc_query_labels_sql "$lst" > "$tmp"
	psql -d "$DBNAME" -v ON_ERROR_STOP=1 "$@" -f "$tmp" -f "$sqlfile"
	rm -f "$tmp"
}
