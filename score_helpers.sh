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
	[ -n "$start_u" ] && [ -n "$end_u" ] && echo "$start_u $end_u"
}

# Bytes of generated flat files (.dat / .tbl*) under PGDATA (and remote hosts if listed).
score_dat_bytes()
{
	local total=0 chunk hosts_file host

	_sum_under() {
		local root="$1"
		[ -n "$root" ] && [ -d "$root" ] || { echo 0; return; }
		find "$root" -type f \( -name '*.dat' -o -name '*.dat.gz' -o -name '*.tbl' -o -name '*.tbl.*' \) -printf '%s\n' 2>/dev/null \
			| awk '{s+=$1} END{print s+0}'
	}

	if [ -n "${PGDATA:-}" ] && [ -d "$PGDATA" ]; then
		total=$(_sum_under "$PGDATA")
	fi

	hosts_file="${LOCAL_PWD:-}/segment_hosts.txt"
	[ -f "$hosts_file" ] || hosts_file="$PWD/../../segment_hosts.txt"
	if [ -f "$hosts_file" ]; then
		while read -r host; do
			[ -z "$host" ] && continue
			[ "$host" = "$(hostname -s)" ] && continue
			chunk=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$host" \
				'if [ -n "${PGDATA:-}" ] && [ -d "$PGDATA" ]; then find "$PGDATA" -type f \( -name "*.dat" -o -name "*.dat.gz" -o -name "*.tbl" -o -name "*.tbl.*" \) -printf "%s\n" 2>/dev/null | awk "{s+=\$1} END{print s+0}"; else echo 0; fi' \
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
	pct05=$(score_query_success_pct "$report_schema" sql)
	pct07=$(score_query_success_pct "$testing_schema" sql)
	[ -z "$pct05" ] && pct05=0
	[ -z "$pct07" ] && pct07=0

	case "${USE_EXTERNAL_FORMAT:-false}" in
		parquet|csv|json) stor_label="Storage (${USE_EXTERNAL_FORMAT}) GB" ;;
		*) stor_label="Database size GB" ;;
	esac

	printf "%-36s %14.3f\n" "DAT/TBL flat files GB" "$dat_gb"
	printf "%-36s %14.3f\n" "$stor_label" "$stor_gb"
	printf "%-36s %14s\n" "05_sql success %" "$pct05"
	printf "%-36s %14s\n" "07_multi_user success %" "$pct07"

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

# Brief Validate Answer Sets block for 09_score when VALIDATE_ANSWER_SETS=true.
# Runs validate_answer_sets.sh (full diff vs toolkit .ans) and prints a short summary.
# Returns 0 on pass/skip, 1 on FAIL/ERROR.
print_answer_set_validation_section()
{
	if [ "${VALIDATE_ANSWER_SETS:-false}" != "true" ]; then
		return 0
	fi

	local root="${LOCAL_PWD:-}"
	if [ -z "$root" ]; then
		if [ -d "$PWD/log" ]; then
			root="$PWD"
		else
			root="$PWD/../.."
		fi
	fi
	local validator="$root/validate_answer_sets.sh"
	local out_dir="$root/log/answer_set_validation"
	local report="$out_dir/report.txt"
	local run_log="$out_dir/run.log"
	local rc=0
	local scale_norm summary fails

	echo ""
	echo "********************************************************************************"
	echo "Validate Answer Sets"
	echo "********************************************************************************"

	if [ "${TPC_MODE:-TPC-DS}" != "TPC-DS" ]; then
		echo "Step VALIDATE_ANSWER_SETS skipped because TPC_MODE=$TPC_MODE (supported for TPC-DS only)"
		return 0
	fi

	scale_norm=$(echo "${GEN_DATA_SCALE:-}" | tr -d '[:space:]')
	if [ "$scale_norm" != "1" ] && [ "$scale_norm" != "1.0" ]; then
		echo "Step VALIDATE_ANSWER_SETS skipped because GEN_DATA_SCALE > 1 (GEN_DATA_SCALE=$GEN_DATA_SCALE; requires 1)"
		return 0
	fi

	if [ ! -f "$validator" ]; then
		echo "ERROR: $validator not found"
		return 1
	fi

	mkdir -p "$out_dir"
	export VALIDATE_ANSWER_SETS GEN_DATA_SCALE DBNAME STATEMENT_TIMEOUT RUN_SQL_FROM_ROLE TPC_MODE
	set +e
	"$validator" >"$run_log" 2>&1
	rc=$?
	set -e

	if [ -f "$report" ]; then
		summary=$(grep -E '^SUMMARY:' "$report" | tail -1 || true)
		if [ -n "$summary" ]; then
			echo "$summary"
		else
			echo "SUMMARY: (missing in report)"
		fi
		fails=$(grep -E '^Q[0-9]+: (FAIL|ERROR)' "$report" || true)
		if [ -n "$fails" ]; then
			echo "Failed / errored queries:"
			echo "$fails" | sed 's/^/  /'
		fi
		echo "Full report: $report"
	else
		echo "WARNING: validation report not found; see $run_log"
		tail -20 "$run_log" 2>/dev/null | sed 's/^/  /' || true
	fi

	if [ "$rc" -ne 0 ]; then
		echo "Validate Answer Sets: FAILED (exit $rc)"
		return 1
	fi
	echo "Validate Answer Sets: OK"
	return 0
}
