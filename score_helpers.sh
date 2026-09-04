#!/bin/bash
# Shared helpers for 09_score (TPC-DS and TPC-H). Source after functions.sh / mode.sh / external_format.sh.

bytes_to_gb()
{
	local bytes="${1:-0}"
	bytes=$(echo "$bytes" | tr -d '[:space:]')
	[ -z "$bytes" ] && bytes=0
	echo "scale=3; $bytes / 1024 / 1024 / 1024" | bc
}

# Unix epoch from end_*.log timestamps like 2026-08-14_14:34:34
score_ts_to_unix()
{
	local ts="$1"
	ts=${ts//_/ }
	date -d "$ts" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s 2>/dev/null || echo ""
}

_score_repo_root()
{
	if [ -n "${LOCAL_PWD:-}" ] && [ -d "${LOCAL_PWD}/log" ]; then
		echo "$LOCAL_PWD"
	elif [ -d "$PWD/log" ]; then
		echo "$PWD"
	else
		echo "$PWD/../.."
	fi
}

# Step basename from log/tpc_stopped_on_error (05_sql or 07_multi_user), or empty.
score_stopped_on_error_step()
{
	local f
	f="$(_score_repo_root)/log/tpc_stopped_on_error"
	[ -f "$f" ] || return 0
	awk -F= '/^step=/{print $2; exit}' "$f" | tr -d '[:space:]'
}

score_end_log_exists()
{
	[ -f "$(_score_repo_root)/log/$1" ]
}

# 07 finished this run and 08 copied testing reports. Leftover end_testing_*.log
# from sessions killed by SQL_ON_ERROR_STOP are ignored.
score_has_07_results()
{
	local stopped
	stopped=$(score_stopped_on_error_step)
	[ "${RUN_MULTI_USER:-false}" = "true" ] || return 1
	[ "$stopped" != "05_sql" ] || return 1
	[ "$stopped" != "07_multi_user" ] || return 1
	score_end_log_exists end_multi_user_reports.log || return 1
	return 0
}

score_read_end_log_range()
{
	# $1 = path to end_*.log → prints "start_unix end_unix" or empty
	local f="$1"
	local start_s end_s start_u end_u
	[ -f "$f" ] || return 0
	start_s=$(awk -F= '/^start=/{print $2; exit}' "$f")
	end_s=$(awk -F= '/^end=/{print $2; exit}' "$f")
	[ -n "$start_s" ] && [ -n "$end_s" ] || return 0
	start_u=$(score_ts_to_unix "$start_s")
	end_u=$(score_ts_to_unix "$end_s")
	[ -n "$start_u" ] && [ -n "$end_u" ] || return 0
	echo "$start_u $end_u"
}

# Min start / max end across end_testing_*.log (multi-user window)
score_multi_user_time_range()
{
	local start_u="" end_u="" s e pair
	local log_dir

	if ! score_has_07_results; then
		return 0
	fi

	log_dir="${LOCAL_PWD:-$PWD/../..}/log/end_testing_log"
	[ -d "$log_dir" ] || log_dir="$PWD/../../log/end_testing_log"
	for f in "$log_dir"/end_testing_*.log; do
		[ -f "$f" ] || continue
		pair=$(score_read_end_log_range "$f")
		[ -n "$pair" ] || continue
		s=$(echo "$pair" | awk '{print $1}')
		e=$(echo "$pair" | awk '{print $2}')
		if [ -z "$start_u" ] || [ "$s" -lt "$start_u" ]; then start_u=$s; fi
		if [ -z "$end_u" ] || [ "$e" -gt "$end_u" ]; then end_u=$e; fi
	done
	if [ -n "$start_u" ] && [ -n "$end_u" ]; then
		echo "$start_u $end_u"
	fi
	return 0
}

# Bytes of generated flat files (.dat / .tbl*) under DAT_FILE_DIRECTORY_PATH (and remote hosts if listed).
score_dat_bytes()
{
	local total=0 chunk hosts_file host
	local root="${DAT_FILE_DIRECTORY_PATH}"

	_sum_under() {
		local dir="$1"
		[ -n "$dir" ] && [ -d "$dir" ] || { echo 0; return; }
		find "$dir" -type f \( -name '*.dat' -o -name '*.dat.gz' -o -name '*.tbl' -o -name '*.tbl.*' \) -printf '%s\n' 2>/dev/null \
			| awk '{s+=$1} END{print s+0}'
	}

	total=$(_sum_under "$root")

	hosts_file="${LOCAL_PWD:-}/segment_hosts.txt"
	[ -f "$hosts_file" ] || hosts_file="$PWD/../../segment_hosts.txt"
	if [ -f "$hosts_file" ]; then
		while read -r host; do
			[ -z "$host" ] && continue
			[ "$host" = "$(hostname -s)" ] && continue
			chunk=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$host" \
				"if [ -d '$root' ]; then find '$root' -type f \\( -name '*.dat' -o -name '*.dat.gz' -o -name '*.tbl' -o -name '*.tbl.*' \\) -printf '%s\\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'; else echo 0; fi" \
				2>/dev/null || echo 0)
			chunk=$(echo "$chunk" | tr -d '[:space:]')
			[ -z "$chunk" ] && chunk=0
			total=$(echo "$total + $chunk" | bc)
		done < "$hosts_file"
	fi
	echo "${total:-0}"
}

# Bytes occupied by benchmark data in DB (heap) or external format tree.
score_storage_bytes()
{
	local bytes=0
	case "${USE_EXTERNAL_FORMAT:-false}" in
		parquet|csv|json)
			if type external_data_root >/dev/null 2>&1; then
				local root
				root=$(external_data_root)
				if [ -d "$root" ]; then
					bytes=$(du -sb "$root" 2>/dev/null | awk '{print $1}')
				fi
			fi
			;;
		*)
			bytes=$(psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -t -A -c "SELECT pg_database_size(current_database());" 2>/dev/null | tr -d '[:space:]')
			;;
	esac
	bytes=$(echo "${bytes:-0}" | tr -d '[:space:]')
	[ -z "$bytes" ] && bytes=0
	echo "$bytes"
}

# Success % from reports/testing .sql table. Successful = 'succesfull' (legacy spelling) or empty.
# Failures = ERROR:* or cancelled due to timeout.
score_query_success_pct()
{
	local schema="$1"
	local table="${2:-sql}"
	psql -d "$DBNAME" -v ON_ERROR_STOP=0 -q -t -A -c "
SELECT CASE WHEN count(*) = 0 THEN 0
       ELSE round(100.0 * count(*) FILTER (
              WHERE coalesce(query_status, '') = ''
                 OR query_status = 'succesfull'
                 OR query_status = 'successful'
            ) / count(*), 2)
       END
FROM ${schema}.${table};
" 2>/dev/null | tr -d '[:space:]'
}

# 05_sql log description is schema.query[.iteration]; missing iteration (legacy) → 1.
_score_sql_iter_sql()
{
	echo "coalesce(nullif(split_part(description, '.', 3), ''), '1')"
}

# Rows of "iter|seconds" for 05_sql, one line per SINGLE_USER_ITERATIONS pass.
# Legacy logs without schema.query.iteration: one row using min(duration) per query (old SCORE).
score_sql_iteration_times()
{
	local schema="$1"
	local out has_iter
	has_iter=$(psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -t -A -c "
SELECT EXISTS (
  SELECT 1 FROM ${schema}.sql
  WHERE split_part(description, '.', 3) <> ''
);
" | tr -d '[:space:]')
	if [ "$has_iter" = "t" ] || [ "$has_iter" = "true" ]; then
		out=$(psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -t -A -c "
SELECT iter, secs
FROM (
  SELECT $(_score_sql_iter_sql) AS iter,
         coalesce(sum(extract('epoch' from duration)), 0) AS secs
  FROM ${schema}.sql
  GROUP BY 1
) s
ORDER BY iter::int;
")
	else
		out=$(psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -t -A -c "
SELECT '1', coalesce(sum(extract('epoch' from duration)), 0)
FROM (
  SELECT split_part(description, '.', 2) AS id, min(duration) AS duration
  FROM ${schema}.sql
  GROUP BY split_part(description, '.', 2)
) sub;
")
	fi
	out=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d')
	if [ -z "$out" ]; then
		printf '%s\n' "1|0"
	else
		printf '%s\n' "$out"
	fi
}

# Rows of "iter|success_pct" for 05_sql.
score_sql_iteration_success_pct()
{
	local schema="$1"
	local out
	out=$(psql -d "$DBNAME" -v ON_ERROR_STOP=0 -q -t -A -c "
SELECT iter, pct
FROM (
  SELECT $(_score_sql_iter_sql) AS iter,
         CASE WHEN count(*) = 0 THEN 0
         ELSE round(100.0 * count(*) FILTER (
                WHERE coalesce(query_status, '') = ''
                   OR query_status = 'succesfull'
                   OR query_status = 'successful'
              ) / count(*), 2)
         END AS pct
  FROM ${schema}.sql
  GROUP BY 1
) s
ORDER BY iter::int;
" 2>/dev/null)
	out=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d')
	if [ -z "$out" ]; then
		printf '%s\n' "1|0"
	else
		printf '%s\n' "$out"
	fi
}

_score_trim_num()
{
	local val
	val=$(printf '%s' "${1:-}" | tr -d '[:space:]')
	if [ -z "$val" ]; then
		echo 0
	else
		echo "$val"
	fi
}

_score_from_tpt()
{
	local tpt="$1"
	local concurrent="$2"
	local tld="$3"
	local num_score="$4"
	local dem_score score
	dem_score=$(echo "$tpt+2*$concurrent+$tld" | bc)
	if [ "$(echo "$dem_score == 0" | bc)" -eq 1 ]; then
		echo 0
	else
		echo "scale=3; $num_score/$dem_score" | bc
	fi
}

_score_print_metric()
{
	local name="$1"
	local val="$2"
	case "$val" in
		""|n/a)
			printf "%-36s %14s\n" "$name" "n/a"
			;;
		"STOPPED ON ERROR"|skipped)
			printf "%-36s %14s\n" "$name" "$val"
			;;
		*)
			printf "%-36s %14.3f\n" "$name" "$val"
			;;
	esac
}

_score_psql_epoch()
{
	local sql="$1"
	local v
	v=$(psql -d "$DBNAME" -v ON_ERROR_STOP=0 -q -t -A -c "$sql" 2>/dev/null | tr -d '[:space:]')
	if [ -z "$v" ]; then
		echo ""
	else
		echo "$v"
	fi
}

# Print the main SCORE table. 05_sql (1 User Queries / TPT / Score) is one block per iteration.
print_tpc_score()
{
	local load_time constraints_time analyze_time concurrent_queries_time
	local q tld num_score iter qtime tpt
	local sql_iters
	local stopped seven_label

	stopped=$(score_stopped_on_error_step)
	seven_label="${MULTI_USER_COUNT} User Queries"

	load_time=$(_score_psql_epoch "select coalesce(sum(extract('epoch' from duration)),0) from ${TPC_REPORT_SCHEMA}.load where tuples > 0")
	constraints_time=$(_score_psql_epoch "
select coalesce(sum(extract('epoch' from duration)),0)
from ${TPC_REPORT_SCHEMA}.load
where tuples = 0
  and (
       split_part(description, '.', 2) like 'idx\_%' escape chr(92)
       or split_part(description, '.', 2) like '%\_pkey' escape chr(92)
       or split_part(description, '.', 2) like 'constraint\_%' escape chr(92)
      )")
	analyze_time=$(_score_psql_epoch "
select coalesce(sum(extract('epoch' from duration)),0)
from ${TPC_REPORT_SCHEMA}.load
where tuples = 0
  and split_part(description, '.', 2) not like 'idx\_%' escape chr(92)
  and split_part(description, '.', 2) not like '%\_pkey' escape chr(92)
  and split_part(description, '.', 2) not like 'constraint\_%' escape chr(92)")

	if [ "$stopped" = "05_sql" ]; then
		sql_iters=""
	else
		sql_iters=$(score_sql_iteration_times "$TPC_REPORT_SCHEMA")
	fi

	if score_has_07_results; then
		concurrent_queries_time=$(_score_trim_num "$(_score_psql_epoch "select coalesce(sum(extract('epoch' from duration)),0) from ${TPC_TESTING_SCHEMA}.sql")")
	else
		concurrent_queries_time=0
	fi

	q=$((3*MULTI_USER_COUNT*TPC_QUERY_ID_MAX))
	if [ -n "$load_time" ]; then
		tld=$(echo "0.01*$MULTI_USER_COUNT*$load_time" | bc)
	else
		tld=""
	fi
	num_score=$(echo "$GEN_DATA_SCALE*$q" | bc)

	printf "%-36s %14s\n" "Metric" "Value"
	printf "%-36s %14s\n" "------------------------------------" "--------------"
	printf "%-36s %14s\n" "TPC mode" "$TPC_MODE"
	printf "%-36s %14s\n" "Scale Factor" "$GEN_DATA_SCALE"
	if [ -n "$stopped" ]; then
		printf "%-36s %14s\n" "${stopped}" "STOPPED ON ERROR"
	fi
	_score_print_metric "Load" "$load_time"
	_score_print_metric "Constraints after load" "$constraints_time"
	_score_print_metric "Analyze" "$analyze_time"

	if [ "$stopped" = "05_sql" ]; then
		_score_print_metric "1 User Queries" "STOPPED ON ERROR"
	elif [ -n "$sql_iters" ]; then
		while IFS='|' read -r iter qtime; do
			[ -z "$iter" ] && continue
			qtime=$(_score_trim_num "$qtime")
			_score_print_metric "1 User Queries (iter $iter)" "$qtime"
		done <<< "$sql_iters"
	else
		_score_print_metric "1 User Queries" "n/a"
	fi

	if [ "$stopped" = "07_multi_user" ]; then
		_score_print_metric "$seven_label" "STOPPED ON ERROR"
	elif score_has_07_results; then
		_score_print_metric "$seven_label" "$concurrent_queries_time"
	else
		_score_print_metric "$seven_label" "skipped"
	fi
	printf "%-36s %14s\n" "Q" "$q"

	if [ "$stopped" = "05_sql" ]; then
		_score_print_metric "TPT" "STOPPED ON ERROR"
	elif [ -n "$sql_iters" ]; then
		while IFS='|' read -r iter qtime; do
			[ -z "$iter" ] && continue
			qtime=$(_score_trim_num "$qtime")
			tpt=$(echo "$qtime*$MULTI_USER_COUNT" | bc)
			_score_print_metric "TPT (iter $iter)" "$tpt"
		done <<< "$sql_iters"
	else
		_score_print_metric "TPT" "n/a"
	fi

	if [ "$stopped" = "07_multi_user" ]; then
		_score_print_metric "TTT" "STOPPED ON ERROR"
	elif score_has_07_results; then
		_score_print_metric "TTT" "$concurrent_queries_time"
	else
		_score_print_metric "TTT" "skipped"
	fi
	_score_print_metric "TLD" "$tld"

	if [ "$stopped" = "05_sql" ]; then
		_score_print_metric "Score" "STOPPED ON ERROR"
	elif [ -n "$sql_iters" ]; then
		while IFS='|' read -r iter qtime; do
			[ -z "$iter" ] && continue
			qtime=$(_score_trim_num "$qtime")
			tpt=$(echo "$qtime*$MULTI_USER_COUNT" | bc)
			_score_print_metric "Score (iter $iter)" "$(_score_from_tpt "$tpt" "$concurrent_queries_time" "${tld:-0}" "$num_score")"
		done <<< "$sql_iters"
	else
		_score_print_metric "Score" "n/a"
	fi
}

# Single-user query list with planner cost from log/single_explain_analyze_log.
print_score_single_user_queries()
{
	local root lst sql

	if [ "${RUN_SINGLE_USER:-false}" != "true" ]; then
		return 0
	fi
	root="${LOCAL_PWD}"
	if [ "$TPC_MODE" = "TPC-H" ]; then
		lst="$root/tpch/00_compile_tpch/dbgen/queries/templates.lst"
		sql="$root/tpch/06_single_user_reports/queries_report.sql"
	else
		lst="$root/tpcds/00_compile_tpcds/query_templates/templates.lst"
		sql="$root/tpcds/06_single_user_reports/queries_report.sql"
	fi
	if [ ! -f "$sql" ]; then
		return 0
	fi
	echo ""
	printf "%-36s %14s\n" "---- 05_sql queries ----" ""
	psql_report_with_query_labels "$lst" "$sql" -P pager=off -P format=aligned -P border=1
}

# Parse duration like STATEMENT_TIMEOUT: 5s, 1min, 1m, 2h, 500ms → integer seconds (>=1).
parse_duration_to_seconds()
{
	local raw unit num secs
	raw=$(echo "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	if [ -z "$raw" ]; then
		echo ""
		return 1
	fi
	if [[ "$raw" =~ ^([0-9]+)(us|µs|ms|s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)?$ ]]; then
		num="${BASH_REMATCH[1]}"
		unit="${BASH_REMATCH[2]:-s}"
	else
		echo ""
		return 1
	fi
	case "$unit" in
		us|µs) secs=1 ;; # sub-second → floor to 1s
		ms) if [ "$num" -lt 1000 ]; then secs=1; else secs=$((num / 1000)); fi ;;
		s|sec|secs|second|seconds) secs=$num ;;
		m|min|mins|minute|minutes) secs=$((num * 60)) ;;
		h|hr|hrs|hour|hours) secs=$((num * 3600)) ;;
		d|day|days) secs=$((num * 86400)) ;;
		*) echo ""; return 1 ;;
	esac
	[ "$secs" -lt 1 ] && secs=1
	echo "$secs"
	return 0
}

_os_metrics_repo_root()
{
	local root="${LOCAL_PWD:-}"
	if [ -z "$root" ]; then
		if [ -d "$PWD/log" ]; then
			root="$PWD"
		else
			root="$PWD/../.."
		fi
	fi
	printf '%s\n' "$root"
}

os_metrics_log_path()
{
	# Legacy single-file path (pre-per-host). SCORE prefers log/os_metrics/<host>.csv.
	echo "$(_os_metrics_repo_root)/log/os_metrics.csv"
}

os_metrics_dir()
{
	echo "$(_os_metrics_repo_root)/log/os_metrics"
}

os_metrics_pid_path()
{
	echo "$(_os_metrics_repo_root)/log/os_metrics_collector.pid"
}

os_metrics_ssh_user()
{
	if [ -n "${TPC_SSH_USER:-}" ]; then
		printf '%s\n' "$TPC_SSH_USER"
		return
	fi
	if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "$(id -un)" ]; then
		printf '%s\n' "$SUDO_USER"
		return
	fi
	id -un
}

# Run a command as the tpc.sh invoker (keys + SSH to Patroni replicas).
os_metrics_as_ssh_user()
{
	local u
	u=$(os_metrics_ssh_user)
	if [ "$(id -un)" = "$u" ]; then
		"$@"
	else
		sudo -n -u "$u" -H -- "$@"
	fi
}

_os_metrics_ssh_opts()
{
	printf '%s\n' "${SSH_BATCH_OPTS:--o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes}"
}

_os_metrics_patroni_yaml_path()
{
	if type _patroni_yaml_path >/dev/null 2>&1; then
		_patroni_yaml_path
		return $?
	fi
	local line token
	line=$(ps aux | grep patroni | grep -v grep | grep -v patronictl | awk '
		{ print; exit }
	')
	[ -n "$line" ] || return 1
	for token in $line; do
		case "$token" in
			*.yml|*.yaml)
				printf '%s\n' "$token"
				return 0
				;;
		esac
	done
	return 1
}

# Lines of "short|ssh_host" for Patroni members. Empty if not a Patroni cluster.
_os_metrics_patroni_members()
{
	local yaml ctl json user
	yaml=$(_os_metrics_patroni_yaml_path || true)
	[ -n "$yaml" ] || return 1
	if type _patroni_ctl_bin >/dev/null 2>&1; then
		ctl=$(_patroni_ctl_bin || true)
	else
		ctl=$(command -v patronictl 2>/dev/null || true)
	fi
	if [ -z "$ctl" ]; then
		return 1
	fi
	json=""
	if [ -r "$yaml" ]; then
		json=$("$ctl" -c "$yaml" list --format json 2>/dev/null || true)
	else
		user="${ADMIN_USER:-postgres}"
		json=$(sudo -n -u "$user" -H "$ctl" -c "$yaml" list --format json 2>/dev/null || true)
	fi
	[ -n "$json" ] || return 1
	python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(1)
data = json.loads(raw)
if isinstance(data, dict):
    data = data.get("members") or data.get("Members") or []
if not isinstance(data, list):
    sys.exit(1)
seen = set()
for m in data:
    if not isinstance(m, dict):
        continue
    member = str(m.get("Member") or m.get("member") or m.get("Name") or "").strip()
    host = str(m.get("Host") or m.get("host") or "").strip()
    ident = member or host
    if not ident:
        continue
    short = ident.split(".")[0]
    ssh = member if member else host
    if not ssh:
        ssh = host or ident
    if short in seen:
        continue
    seen.add(short)
    print("%s|%s" % (short, ssh))
' <<<"$json"
}

# short|ssh_host for every host we will sample (Patroni members, else this machine).
os_metrics_sample_targets()
{
	local members
	members=$(_os_metrics_patroni_members || true)
	if [ -n "$members" ]; then
		printf '%s\n' "$members"
		return 0
	fi
	printf '%s|%s\n' "$(hostname -s)" "$(hostname -f 2>/dev/null || hostname -s)"
}

_os_metrics_is_local()
{
	local host="$1"
	if type is_local_host >/dev/null 2>&1; then
		is_local_host "$host"
		return $?
	fi
	local short local_s
	short=$(printf '%s' "$host" | awk -F. '{print $1}')
	local_s=$(hostname -s 2>/dev/null || true)
	[ "$host" = "$local_s" ] || [ "$short" = "$local_s" ]
}

_os_metrics_kill_pid()
{
	local pid="$1"
	[ -n "$pid" ] || return 0
	if kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || true
		sleep 0.2 2>/dev/null || true
		kill -9 "$pid" 2>/dev/null || true
	fi
}

# Copy remote /tmp samples into log/os_metrics/<short>.csv (collectors may still be running).
os_metrics_fetch_remote_logs()
{
	local dir mapfile short ssh_host pid opts
	dir=$(os_metrics_dir)
	mapfile="$dir/remote.pids"
	[ -f "$mapfile" ] || return 0
	opts=$(_os_metrics_ssh_opts)
	while IFS='|' read -r short ssh_host pid; do
		[ -n "$short" ] && [ -n "$ssh_host" ] || continue
		os_metrics_as_ssh_user scp $opts "${ssh_host}:/tmp/tpc_os_metrics.csv" "$dir/${short}.csv" 2>/dev/null || true
	done < "$mapfile"
}

stop_os_metrics_collector()
{
	local dir pidfile pid mapfile short ssh_host rpid opts

	dir=$(os_metrics_dir)
	opts=$(_os_metrics_ssh_opts)
	mapfile="$dir/remote.pids"
	if [ -f "$mapfile" ]; then
		while IFS='|' read -r short ssh_host rpid; do
			[ -n "$ssh_host" ] || continue
			if [ -n "$rpid" ]; then
				os_metrics_as_ssh_user ssh -n $opts "$ssh_host" "kill $rpid 2>/dev/null; sleep 0.2; kill -9 $rpid 2>/dev/null; true" 2>/dev/null || true
			fi
			os_metrics_as_ssh_user ssh -n $opts "$ssh_host" "pkill -f /tmp/tpc_os_metrics_collector.sh 2>/dev/null; true" 2>/dev/null || true
			os_metrics_as_ssh_user scp $opts "${ssh_host}:/tmp/tpc_os_metrics.csv" "$dir/${short}.csv" 2>/dev/null || true
		done < "$mapfile"
		rm -f "$mapfile"
	fi

	pidfile=$(os_metrics_pid_path)
	if [ -f "$pidfile" ]; then
		pid=$(tr -d '[:space:]' < "$pidfile")
		_os_metrics_kill_pid "$pid"
		rm -f "$pidfile"
	fi
	if [ -d "$dir" ]; then
		for pidfile in "$dir"/*.pid; do
			[ -f "$pidfile" ] || continue
			pid=$(tr -d '[:space:]' < "$pidfile")
			_os_metrics_kill_pid "$pid"
			rm -f "$pidfile"
		done
	fi
	pkill -f "os_metrics_collector.sh $(_os_metrics_repo_root)/log/os_metrics" 2>/dev/null || true
	pkill -f "os_metrics_collector.sh $(os_metrics_log_path)" 2>/dev/null || true
}

_os_metrics_start_local()
{
	local short="$1"
	local collector="$2"
	local period_sec="$3"
	local dir outfile pidfile
	dir=$(os_metrics_dir)
	outfile="$dir/${short}.csv"
	pidfile="$dir/${short}.pid"
	nohup "$collector" "$outfile" "$period_sec" >/dev/null 2>&1 &
	echo $! > "$pidfile"
	sleep 0.3 2>/dev/null || sleep 1
	if ! kill -0 "$(tr -d '[:space:]' < "$pidfile")" 2>/dev/null; then
		echo "ERROR: OS metrics collector failed to start on local host $short."
		return 1
	fi
	echo "OS metrics collector on $short (local) PID $(tr -d '[:space:]' < "$pidfile")"
	return 0
}

_os_metrics_start_remote()
{
	local short="$1"
	local ssh_host="$2"
	local collector="$3"
	local period_sec="$4"
	local dir opts rpid
	dir=$(os_metrics_dir)
	opts=$(_os_metrics_ssh_opts)

	if ! os_metrics_as_ssh_user ssh -n $opts "$ssh_host" "true" >/dev/null 2>&1; then
		echo "ERROR: COLLECT_OS_DATA cannot SSH to Patroni member $ssh_host as $(os_metrics_ssh_user) (BatchMode)."
		return 1
	fi
	os_metrics_as_ssh_user scp $opts "$collector" "${ssh_host}:/tmp/tpc_os_metrics_collector.sh" || {
		echo "ERROR: COLLECT_OS_DATA cannot scp collector to $ssh_host."
		return 1
	}
	os_metrics_as_ssh_user ssh -n $opts "$ssh_host" "pkill -f /tmp/tpc_os_metrics_collector.sh 2>/dev/null || true; chmod +x /tmp/tpc_os_metrics_collector.sh" || true
	rpid=$(os_metrics_as_ssh_user ssh -n $opts "$ssh_host" "nohup /tmp/tpc_os_metrics_collector.sh /tmp/tpc_os_metrics.csv $period_sec >/dev/null 2>&1 & echo \$!")
	rpid=$(printf '%s' "$rpid" | tr -d '[:space:]')
	if [ -z "$rpid" ]; then
		echo "ERROR: OS metrics collector failed to start on $ssh_host ($short)."
		return 1
	fi
	echo "${short}|${ssh_host}|${rpid}" >> "$dir/remote.pids"
	echo "OS metrics collector on $short ($ssh_host) PID $rpid"
	return 0
}

start_os_metrics_collector()
{
	local period_raw="${COLLECT_DATA_PERIOD:-5s}"
	local period_sec script_dir collector dir hosts_file line short ssh_host
	period_sec=$(parse_duration_to_seconds "$period_raw") || true
	if [ -z "$period_sec" ]; then
		echo "ERROR: COLLECT_OS_DATA=true but COLLECT_DATA_PERIOD='$period_raw' is not a valid duration (e.g. 5s, 1min, 1m, 2h)."
		return 1
	fi

	script_dir="${LOCAL_PWD:-$PWD}"
	collector="$script_dir/os_metrics_collector.sh"
	if [ ! -x "$collector" ] && [ -f "$collector" ]; then
		chmod +x "$collector" 2>/dev/null || true
	fi
	if [ ! -f "$collector" ]; then
		echo "ERROR: os_metrics_collector.sh not found at $collector"
		return 1
	fi

	stop_os_metrics_collector

	dir=$(os_metrics_dir)
	mkdir -p "$dir"
	rm -f "$(os_metrics_pid_path)"
	rm -f "$dir"/*.csv "$dir"/*.pid
	: > "$dir/remote.pids"
	hosts_file="$dir/hosts"
	: > "$hosts_file"

	echo "Starting OS metrics collector (period=${period_raw} → ${period_sec}s)"
	while IFS='|' read -r short ssh_host; do
		[ -n "$short" ] || continue
		[ -n "$ssh_host" ] || ssh_host=$short
		printf '%s\n' "$short" >> "$hosts_file"
		if _os_metrics_is_local "$ssh_host" || _os_metrics_is_local "$short"; then
			_os_metrics_start_local "$short" "$collector" "$period_sec" || {
				stop_os_metrics_collector
				return 1
			}
		else
			_os_metrics_start_remote "$short" "$ssh_host" "$collector" "$period_sec" || {
				stop_os_metrics_collector
				return 1
			}
		fi
	done < <(os_metrics_sample_targets)

	if [ ! -s "$hosts_file" ]; then
		echo "ERROR: OS metrics collector has no hosts to sample."
		return 1
	fi
	echo "OS metrics hosts: $(tr '\n' ' ' < "$hosts_file")"
	return 0
}

# Average OS samples in [start_u, end_u] from a metrics csv (default: legacy os_metrics.csv).
# Prints five values: cpu_pct ram_gb net_mbs disk_used_gb disk_total_gb (or n/a)
os_metrics_avg_over_window()
{
	local start_u="$1"
	local end_u="$2"
	local outfile="${3:-}"
	if [ -z "$outfile" ]; then
		outfile=$(os_metrics_log_path)
	fi
	if [ ! -f "$outfile" ] || [ -z "$start_u" ] || [ -z "$end_u" ]; then
		echo "n/a n/a n/a n/a n/a"
		return 0
	fi
	python3 - "$outfile" "$start_u" "$end_u" <<'PY'
import sys
path, start_s, end_s = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rows = []
with open(path) as f:
    for line in f:
        parts = line.split()
        if len(parts) < 7:
            continue
        try:
            ts = int(parts[0])
            idle = float(parts[1]); total = float(parts[2])
            mem = float(parts[3]); rx = float(parts[4]); tx = float(parts[5])
            disk = float(parts[6])
            disk_total = float(parts[7]) if len(parts) >= 8 else None
        except ValueError:
            continue
        if start_s <= ts <= end_s:
            rows.append((ts, idle, total, mem, rx, tx, disk, disk_total))
if len(rows) < 1:
    print("n/a n/a n/a n/a n/a")
    sys.exit(0)

# CPU: mean of per-interval busy% between consecutive samples
cpu_vals = []
for i in range(1, len(rows)):
    di = rows[i][1] - rows[i-1][1]
    dt = rows[i][2] - rows[i-1][2]
    if dt > 0:
        busy = 100.0 * (1.0 - di / dt)
        if busy < 0: busy = 0.0
        if busy > 100: busy = 100.0
        cpu_vals.append(busy)
cpu = sum(cpu_vals) / len(cpu_vals) if cpu_vals else None

ram_gb = sum(r[3] for r in rows) / len(rows) / (1024**3)
disk_gb = sum(r[6] for r in rows) / len(rows) / (1024**3)
disk_total_vals = [r[7] for r in rows if r[7] is not None]
disk_total_gb = (sum(disk_total_vals) / len(disk_total_vals) / (1024**3)) if disk_total_vals else None

net = None
if len(rows) >= 2:
    dts = rows[-1][0] - rows[0][0]
    if dts > 0:
        dbytes = (rows[-1][4] + rows[-1][5]) - (rows[0][4] + rows[0][5])
        if dbytes < 0:
            dbytes = 0
        net = dbytes / dts / (1024 * 1024)

def fmt(v):
    return "n/a" if v is None else f"{v:.6f}"

print(fmt(cpu), fmt(ram_gb), fmt(net), fmt(disk_gb), fmt(disk_total_gb))
PY
}

_fmt_disk_used_all()
{
	local used="$1"
	local total="$2"
	local used_fmt total_fmt
	if [ "$used" = "n/a" ] || [ -z "$used" ]; then
		echo "n/a"
		return
	fi
	used_fmt=$(printf '%.3f' "$used" 2>/dev/null || echo "$used")
	if [ "$total" = "n/a" ] || [ -z "$total" ]; then
		echo "${used_fmt}/n/a"
		return
	fi
	total_fmt=$(printf '%.0f' "$total" 2>/dev/null || echo "$total")
	echo "${used_fmt}/${total_fmt}"
}

score_os_metrics_for_window()
{
	local label="$1"
	local start_u="$2"
	local end_u="$3"
	local outfile="${4:-}"
	local cpu ram net disk disk_total

	_fmt() {
		local v="$1"
		if [ "$v" = "n/a" ] || [ -z "$v" ]; then
			echo "n/a"
		else
			printf '%.3f' "$v" 2>/dev/null || echo "$v"
		fi
	}

	if [ -z "$start_u" ] || [ -z "$end_u" ]; then
		printf "%-36s %14s\n" "$label CPU avg %" "n/a"
		printf "%-36s %14s\n" "$label RAM used avg GB" "n/a"
		printf "%-36s %14s\n" "$label Network avg MB/s" "n/a"
		printf "%-36s %14s\n" "$label Disk used/all avg GB" "n/a"
		return 0
	fi

	read -r cpu ram net disk disk_total < <(os_metrics_avg_over_window "$start_u" "$end_u" "$outfile")

	printf "%-36s %14s\n" "$label CPU avg %" "$(_fmt "$cpu")"
	printf "%-36s %14s\n" "$label RAM used avg GB" "$(_fmt "$ram")"
	printf "%-36s %14s\n" "$label Network avg MB/s" "$(_fmt "$net")"
	printf "%-36s %14s\n" "$label Disk used/all avg GB" "$(_fmt_disk_used_all "$disk" "$disk_total")"
}

os_metrics_recorded_hosts()
{
	local dir f base
	dir=$(os_metrics_dir)
	if [ -f "$dir/hosts" ] && [ -s "$dir/hosts" ]; then
		sed '/^[[:space:]]*$/d' "$dir/hosts"
		return 0
	fi
	if [ -d "$dir" ]; then
		for f in "$dir"/*.csv; do
			[ -f "$f" ] || continue
			base=$(basename "$f" .csv)
			printf '%s\n' "$base"
		done
		return 0
	fi
	if [ -f "$(os_metrics_log_path)" ]; then
		hostname -s
	fi
}

os_metrics_csv_for_host()
{
	local host="$1"
	local dir csv
	dir=$(os_metrics_dir)
	csv="$dir/${host}.csv"
	if [ -f "$csv" ]; then
		printf '%s\n' "$csv"
		return
	fi
	if [ -f "$(os_metrics_log_path)" ]; then
		printf '%s\n' "$(os_metrics_log_path)"
	fi
}

print_os_metrics_per_host_table()
{
	local heading="$1"
	local label="$2"
	local start_u="$3"
	local end_u="$4"
	local -a hosts=()
	local -a cpu=() ram=() net=() disk=() disk_total=()
	local h csv c r n d dt colw i
	local host

	os_metrics_fetch_remote_logs

	while IFS= read -r host; do
		[ -n "$host" ] || continue
		hosts+=("$host")
	done < <(os_metrics_recorded_hosts)

	echo ""
	printf "%-36s\n" "$heading"
	if [ ${#hosts[@]} -eq 0 ]; then
		score_os_metrics_for_window "$label" "$start_u" "$end_u"
		return 0
	fi

	colw=22
	for h in "${hosts[@]}"; do
		if [ ${#h} -ge "$colw" ]; then
			colw=$(( ${#h} + 2 ))
		fi
	done

	printf "%-36s" "Host"
	for h in "${hosts[@]}"; do
		printf "%${colw}s" "$h"
	done
	printf "\n"

	i=0
	for h in "${hosts[@]}"; do
		csv=$(os_metrics_csv_for_host "$h")
		read -r c r n d dt < <(os_metrics_avg_over_window "$start_u" "$end_u" "$csv")
		cpu[$i]=$c
		ram[$i]=$r
		net[$i]=$n
		disk[$i]=$d
		disk_total[$i]=$dt
		i=$((i + 1))
	done

	_fmt_cell() {
		local v="$1"
		if [ "$v" = "n/a" ] || [ -z "$v" ]; then
			echo "n/a"
		else
			printf '%.3f' "$v" 2>/dev/null || echo "$v"
		fi
	}

	printf "%-36s" "$label CPU avg %"
	for i in "${!hosts[@]}"; do printf "%${colw}s" "$(_fmt_cell "${cpu[$i]}")"; done
	printf "\n"
	printf "%-36s" "$label RAM used avg GB"
	for i in "${!hosts[@]}"; do printf "%${colw}s" "$(_fmt_cell "${ram[$i]}")"; done
	printf "\n"
	printf "%-36s" "$label Network avg MB/s"
	for i in "${!hosts[@]}"; do printf "%${colw}s" "$(_fmt_cell "${net[$i]}")"; done
	printf "\n"
	printf "%-36s" "$label Disk used/all avg GB"
	for i in "${!hosts[@]}"; do printf "%${colw}s" "$(_fmt_disk_used_all "${disk[$i]}" "${disk_total[$i]}")"; done
	printf "\n"
}

# host|count|total|pct  — share of query executions on each backend host.
score_queries_per_host()
{
	local schema="$1"
	local table="${2:-sql}"
	local has_col

	has_col=$(psql -d "$DBNAME" -v ON_ERROR_STOP=0 -q -t -A -c "
SELECT EXISTS (
  SELECT 1 FROM information_schema.columns
  WHERE table_schema = '${schema}'
    AND table_name = '${table}'
    AND column_name = 'backend_host'
);
" 2>/dev/null | tr -d '[:space:]')
	if [ "$has_col" != "t" ] && [ "$has_col" != "true" ]; then
		return 0
	fi

	psql -d "$DBNAME" -v ON_ERROR_STOP=0 -q -t -A -c "
WITH tot AS (
  SELECT count(*)::bigint AS n FROM ${schema}.${table}
)
SELECT coalesce(nullif(btrim(s.backend_host), ''), 'unknown') AS host,
       count(*)::text,
       t.n::text,
       round(100.0 * count(*) / nullif(t.n, 0), 2)::text
FROM ${schema}.${table} s
CROSS JOIN tot t
GROUP BY 1, t.n
ORDER BY 1;
" 2>/dev/null
}

print_score_queries_per_host()
{
	local title="$1"
	local schema="$2"
	local table="${3:-sql}"
	local host n total pct
	local any=0

	echo ""
	printf "%-36s %14s\n" "$title" ""
	while IFS='|' read -r host n total pct; do
		[ -z "$host" ] && continue
		any=1
		printf "%-22s %12s %10s%%\n" "$host" "$n/$total" "$pct"
	done < <(score_queries_per_host "$schema" "$table")
	if [ "$any" -eq 0 ]; then
		printf "%-22s %12s %10s\n" "(none)" "-" "-"
	fi
}

print_extended_score_metrics()
{
	local report_schema="$1"
	local testing_schema="$2"
	local dat_b stor_b dat_gb stor_gb pct05 pct07
	local pair05 pair07 s05 e05 s07 e07
	local stor_label
	local stopped

	stopped=$(score_stopped_on_error_step)

	dat_b=$(score_dat_bytes)
	stor_b=$(score_storage_bytes)
	dat_gb=$(bytes_to_gb "$dat_b")
	stor_gb=$(bytes_to_gb "$stor_b")

	case "${USE_EXTERNAL_FORMAT:-false}" in
		parquet|csv|json) stor_label="Storage (${USE_EXTERNAL_FORMAT}) GB" ;;
		*) stor_label="Database size GB" ;;
	esac

	printf "%-36s %14.3f\n" "DAT/TBL flat files GB" "$dat_gb"
	printf "%-36s %14.3f\n" "$stor_label" "$stor_gb"
	if [ "$stopped" = "05_sql" ]; then
		printf "%-36s %14s\n" "05_sql success %" "STOPPED ON ERROR"
	else
		while IFS='|' read -r iter pct05; do
			[ -z "$iter" ] && continue
			pct05=$(echo "$pct05" | tr -d '[:space:]')
			[ -z "$pct05" ] && pct05=0
			printf "%-36s %14s\n" "05_sql success % (iter $iter)" "$pct05"
		done < <(score_sql_iteration_success_pct "$report_schema")
	fi
	if [ "$stopped" = "07_multi_user" ]; then
		printf "%-36s %14s\n" "07_multi_user success %" "STOPPED ON ERROR"
	elif score_has_07_results; then
		pct07=$(score_query_success_pct "$testing_schema" sql)
		[ -z "$pct07" ] && pct07=0
		printf "%-36s %14s\n" "07_multi_user success %" "$pct07"
	else
		printf "%-36s %14s\n" "07_multi_user success %" "skipped"
	fi

	if [ "$stopped" != "05_sql" ]; then
		print_score_queries_per_host "---- Statistics queries per host (05_sql) ----" "$report_schema" sql
	fi
	if score_has_07_results; then
		print_score_queries_per_host "---- Statistics queries per host (07_sql) ----" "$testing_schema" sql
	fi

	if [ "${COLLECT_OS_DATA:-true}" = "true" ]; then
		s05=""
		e05=""
		if [ "$stopped" != "05_sql" ]; then
			pair05=$(score_read_end_log_range "${LOCAL_PWD:-$PWD/../..}/log/end_sql.log")
			[ -z "$pair05" ] && pair05=$(score_read_end_log_range "$PWD/../../log/end_sql.log")
			s05=$(echo "$pair05" | awk '{print $1}')
			e05=$(echo "$pair05" | awk '{print $2}')
		fi
		print_os_metrics_per_host_table "---- OS metrics per host (05_sql) ----" "05" "$s05" "$e05"

		s07=""
		e07=""
		if score_has_07_results; then
			pair07=$(score_multi_user_time_range)
			s07=$(echo "$pair07" | awk '{print $1}')
			e07=$(echo "$pair07" | awk '{print $2}')
		fi
		print_os_metrics_per_host_table "---- OS metrics per host (07_multi) ----" "07" "$s07" "$e07"
	fi
}
