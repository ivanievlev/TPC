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
	local log_dir="${LOCAL_PWD:-$PWD/../..}/log/end_testing_log"
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

# Bytes of generated flat files (.dat / .tbl*) under EXTERNAL_FILE_DIRECTORY_PATH (and remote hosts if listed).
score_dat_bytes()
{
	local total=0 chunk hosts_file host
	local root="${EXTERNAL_FILE_DIRECTORY_PATH}"

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

# Print the main SCORE table. 05_sql (1 User Queries / TPT / Score) is one block per iteration.
print_tpc_score()
{
	local load_time constraints_time analyze_time concurrent_queries_time
	local q tld num_score iter qtime tpt
	local sql_iters

	load_time=$(_score_trim_num "$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select coalesce(sum(extract('epoch' from duration)),0) from ${TPC_REPORT_SCHEMA}.load where tuples > 0")")
	constraints_time=$(_score_trim_num "$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "
select coalesce(sum(extract('epoch' from duration)),0)
from ${TPC_REPORT_SCHEMA}.load
where tuples = 0
  and (
       split_part(description, '.', 2) like 'idx\_%' escape chr(92)
       or split_part(description, '.', 2) like '%\_pkey' escape chr(92)
       or split_part(description, '.', 2) like 'constraint\_%' escape chr(92)
      )")")
	analyze_time=$(_score_trim_num "$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "
select coalesce(sum(extract('epoch' from duration)),0)
from ${TPC_REPORT_SCHEMA}.load
where tuples = 0
  and split_part(description, '.', 2) not like 'idx\_%' escape chr(92)
  and split_part(description, '.', 2) not like '%\_pkey' escape chr(92)
  and split_part(description, '.', 2) not like 'constraint\_%' escape chr(92)")")

	if [ "${RUN_MULTI_USER:-false}" = "true" ]; then
		concurrent_queries_time=$(_score_trim_num "$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select coalesce(sum(extract('epoch' from duration)),0) from ${TPC_TESTING_SCHEMA}.sql")")
	else
		echo "Skipping multi-user time (RUN_MULTI_USER=${RUN_MULTI_USER:-false})"
		concurrent_queries_time=0
	fi

	sql_iters=$(score_sql_iteration_times "$TPC_REPORT_SCHEMA")

	q=$((3*MULTI_USER_COUNT*TPC_QUERY_ID_MAX))
	tld=$(echo "0.01*$MULTI_USER_COUNT*$load_time" | bc)
	num_score=$(echo "$GEN_DATA_SCALE*$q" | bc)

	printf "%-36s %14s\n" "Metric" "Value"
	printf "%-36s %14s\n" "------------------------------------" "--------------"
	printf "%-36s %14s\n" "TPC mode" "$TPC_MODE"
	printf "%-36s %14s\n" "Scale Factor" "$GEN_DATA_SCALE"
	printf "%-36s %14.3f\n" "Load" "$load_time"
	printf "%-36s %14.3f\n" "Constraints after load" "$constraints_time"
	printf "%-36s %14.3f\n" "Analyze" "$analyze_time"

	while IFS='|' read -r iter qtime; do
		[ -z "$iter" ] && continue
		qtime=$(_score_trim_num "$qtime")
		printf "%-36s %14.3f\n" "1 User Queries (iter $iter)" "$qtime"
	done <<< "$sql_iters"

	if [ "${RUN_MULTI_USER:-false}" = "true" ]; then
		printf "%-36s %14.3f\n" "${MULTI_USER_COUNT} User Queries" "$concurrent_queries_time"
	else
		printf "%-36s %14s\n" "${MULTI_USER_COUNT} User Queries" "skipped"
	fi
	printf "%-36s %14s\n" "Q" "$q"

	while IFS='|' read -r iter qtime; do
		[ -z "$iter" ] && continue
		qtime=$(_score_trim_num "$qtime")
		tpt=$(echo "$qtime*$MULTI_USER_COUNT" | bc)
		printf "%-36s %14.3f\n" "TPT (iter $iter)" "$tpt"
	done <<< "$sql_iters"

	if [ "${RUN_MULTI_USER:-false}" = "true" ]; then
		printf "%-36s %14.3f\n" "TTT" "$concurrent_queries_time"
	else
		printf "%-36s %14s\n" "TTT" "skipped"
	fi
	printf "%-36s %14.3f\n" "TLD" "$tld"

	while IFS='|' read -r iter qtime; do
		[ -z "$iter" ] && continue
		qtime=$(_score_trim_num "$qtime")
		tpt=$(echo "$qtime*$MULTI_USER_COUNT" | bc)
		printf "%-36s %14.3f\n" "Score (iter $iter)" "$(_score_from_tpt "$tpt" "$concurrent_queries_time" "$tld" "$num_score")"
	done <<< "$sql_iters"
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

os_metrics_log_path()
{
	local root="${LOCAL_PWD:-}"
	if [ -z "$root" ]; then
		if [ -d "$PWD/log" ]; then
			root="$PWD"
		else
			root="$PWD/../.."
		fi
	fi
	echo "$root/log/os_metrics.csv"
}

os_metrics_pid_path()
{
	local root="${LOCAL_PWD:-}"
	if [ -z "$root" ]; then
		if [ -d "$PWD/log" ]; then
			root="$PWD"
		else
			root="$PWD/../.."
		fi
	fi
	echo "$root/log/os_metrics_collector.pid"
}

stop_os_metrics_collector()
{
	local pidfile pid
	pidfile=$(os_metrics_pid_path)
	if [ -f "$pidfile" ]; then
		pid=$(tr -d '[:space:]' < "$pidfile")
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
			# Give it a moment; then force
			sleep 0.2 2>/dev/null || true
			kill -9 "$pid" 2>/dev/null || true
		fi
		rm -f "$pidfile"
	fi
	# Best-effort: any leftover collector writing our outfile
	pkill -f "os_metrics_collector.sh $(os_metrics_log_path)" 2>/dev/null || true
}

start_os_metrics_collector()
{
	local period_raw="${COLLECT_DATA_PERIOD:-5s}"
	local period_sec outfile pidfile script_dir collector
	period_sec=$(parse_duration_to_seconds "$period_raw") || true
	if [ -z "$period_sec" ]; then
		echo "ERROR: COLLECT_OS_DATA=true but COLLECT_DATA_PERIOD='$period_raw' is not a valid duration (e.g. 5s, 1min, 1m, 2h)."
		return 1
	fi
	outfile=$(os_metrics_log_path)
	pidfile=$(os_metrics_pid_path)
	mkdir -p "$(dirname "$outfile")"

	stop_os_metrics_collector

	script_dir="${LOCAL_PWD:-$PWD}"
	collector="$script_dir/os_metrics_collector.sh"
	if [ ! -x "$collector" ] && [ -f "$collector" ]; then
		chmod +x "$collector" 2>/dev/null || true
	fi
	if [ ! -f "$collector" ]; then
		echo "ERROR: os_metrics_collector.sh not found at $collector"
		return 1
	fi

	echo "Starting OS metrics collector (period=${period_raw} → ${period_sec}s) → $outfile"
	nohup "$collector" "$outfile" "$period_sec" >/dev/null 2>&1 &
	echo $! > "$pidfile"
	# Confirm it stayed up
	sleep 0.3 2>/dev/null || sleep 1
	if ! kill -0 "$(tr -d '[:space:]' < "$pidfile")" 2>/dev/null; then
		echo "ERROR: OS metrics collector failed to start."
		rm -f "$pidfile"
		return 1
	fi
	echo "OS metrics collector PID $(tr -d '[:space:]' < "$pidfile")"
	return 0
}

# Average OS samples in [start_u, end_u] from os_metrics.csv.
# Prints four lines: cpu_pct ram_gb net_mbs disk_gb (or n/a)
os_metrics_avg_over_window()
{
	local start_u="$1"
	local end_u="$2"
	local outfile
	outfile=$(os_metrics_log_path)
	if [ ! -f "$outfile" ] || [ -z "$start_u" ] || [ -z "$end_u" ]; then
		echo "n/a n/a n/a n/a"
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
        except ValueError:
            continue
        if start_s <= ts <= end_s:
            rows.append((ts, idle, total, mem, rx, tx, disk))
if len(rows) < 1:
    print("n/a n/a n/a n/a")
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

print(fmt(cpu), fmt(ram_gb), fmt(net), fmt(disk_gb))
PY
}

score_os_metrics_for_window()
{
	local label="$1"
	local start_u="$2"
	local end_u="$3"
	local cpu ram net disk

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
		printf "%-36s %14s\n" "$label Disk used avg GB" "n/a"
		return 0
	fi

	read -r cpu ram net disk < <(os_metrics_avg_over_window "$start_u" "$end_u")

	printf "%-36s %14s\n" "$label CPU avg %" "$(_fmt "$cpu")"
	printf "%-36s %14s\n" "$label RAM used avg GB" "$(_fmt "$ram")"
	printf "%-36s %14s\n" "$label Network avg MB/s" "$(_fmt "$net")"
	printf "%-36s %14s\n" "$label Disk used avg GB" "$(_fmt "$disk")"
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

	dat_b=$(score_dat_bytes)
	stor_b=$(score_storage_bytes)
	dat_gb=$(bytes_to_gb "$dat_b")
	stor_gb=$(bytes_to_gb "$stor_b")
	pct07=$(score_query_success_pct "$testing_schema" sql)
	[ -z "$pct07" ] && pct07=0

	case "${USE_EXTERNAL_FORMAT:-false}" in
		parquet|csv|json) stor_label="Storage (${USE_EXTERNAL_FORMAT}) GB" ;;
		*) stor_label="Database size GB" ;;
	esac

	printf "%-36s %14.3f\n" "DAT/TBL flat files GB" "$dat_gb"
	printf "%-36s %14.3f\n" "$stor_label" "$stor_gb"
	while IFS='|' read -r iter pct05; do
		[ -z "$iter" ] && continue
		pct05=$(echo "$pct05" | tr -d '[:space:]')
		[ -z "$pct05" ] && pct05=0
		printf "%-36s %14s\n" "05_sql success % (iter $iter)" "$pct05"
	done < <(score_sql_iteration_success_pct "$report_schema")
	printf "%-36s %14s\n" "07_multi_user success %" "$pct07"

	print_score_queries_per_host "---- Statistics queries per host (05_sql) ----" "$report_schema" sql
	if [ "${RUN_MULTI_USER:-false}" = "true" ]; then
		print_score_queries_per_host "---- Statistics queries per host (07_sql) ----" "$testing_schema" sql
	fi

	if [ "${COLLECT_OS_DATA:-true}" = "true" ]; then
		echo ""
		printf "%-36s %14s\n" "---- OS metrics (05_sql) ----" ""
		pair05=$(score_read_end_log_range "${LOCAL_PWD:-$PWD/../..}/log/end_sql.log")
		[ -z "$pair05" ] && pair05=$(score_read_end_log_range "$PWD/../../log/end_sql.log")
		s05=$(echo "$pair05" | awk '{print $1}')
		e05=$(echo "$pair05" | awk '{print $2}')
		score_os_metrics_for_window "05" "$s05" "$e05"

		echo ""
		printf "%-36s %14s\n" "---- OS metrics (07_multi) ----" ""
		pair07=$(score_multi_user_time_range)
		s07=$(echo "$pair07" | awk '{print $1}')
		e07=$(echo "$pair07" | awk '{print $2}')
		score_os_metrics_for_window "07" "$s07" "$e07"
	fi
}
