#!/bin/bash
# Shared helpers for USE_EXTERNAL_FORMAT=parquet|csv|json (pg_duckdb / local files).
# Uses TPC_* from mode.sh (TPC_SCHEMA, TPC_STEP_ROOT, TPC_DATA_PREFIX). Defaults = TPC-DS.

external_format_enabled()
{
	case "${USE_EXTERNAL_FORMAT}" in
		parquet|csv|json) return 0 ;;
		*) return 1 ;;
	esac
}

external_bench_defaults()
{
	: "${TPC_SCHEMA:=tpcds}"
	: "${TPC_STEP_ROOT:=tpcds}"
	: "${TPC_DATA_PREFIX:=tpcds}"
	: "${TPC_MODE:=TPC-DS}"
}

external_ddl_dir()
{
	external_bench_defaults
	echo "${LOCAL_PWD}/${TPC_STEP_ROOT}/03_ddl"
}

external_data_root()
{
	external_bench_defaults
	echo "/arenadata/${TPC_DATA_PREFIX}_${GEN_DATA_SCALE}_${USE_EXTERNAL_FORMAT}"
}

# Remove leftover /arenadata/{tpcds,tpch}_*_{parquet,csv,json} trees from previous runs.
purge_old_external_data()
{
	local d
	local found=0
	external_bench_defaults

	if [ "${PURGE_OLD_EXTERNAL_DATA:-true}" != "true" ]; then
		echo "PURGE_OLD_EXTERNAL_DATA=${PURGE_OLD_EXTERNAL_DATA:-false}: keeping existing /arenadata/{tpcds,tpch}_*_{parquet,csv,json}"
		return 0
	fi

	echo "PURGE_OLD_EXTERNAL_DATA=true: removing previous external data under /arenadata/{tpcds,tpch}_*_{parquet,csv,json}"
	shopt -s nullglob
	for d in \
		/arenadata/tpcds_*_parquet /arenadata/tpcds_*_csv /arenadata/tpcds_*_json \
		/arenadata/tpch_*_parquet /arenadata/tpch_*_csv /arenadata/tpch_*_json
	do
		if [ -d "$d" ] || [ -e "$d" ]; then
			found=1
			echo "  rm -rf $d"
			rm -rf "$d"
		fi
	done
	shopt -u nullglob
	if [ "$found" -eq 0 ]; then
		echo "  (nothing to remove)"
	fi
}

external_table_dir()
{
	local table_name=$1
	echo "$(external_data_root)/${table_name}"
}

external_file_ext()
{
	echo "${USE_EXTERNAL_FORMAT}"
}

external_read_function()
{
	case "${USE_EXTERNAL_FORMAT}" in
		parquet) echo "read_parquet" ;;
		csv) echo "read_csv" ;;
		json) echo "read_json" ;;
		*) echo "read_parquet" ;;
	esac
}

# Map PG type → cast target used in views / COPY SELECT aliases.
external_pg_cast_type()
{
	local t
	t=$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/not null//g;s/^[[:space:]]*//;s/[[:space:]]*$//')
	case "$t" in
		int|integer) echo "integer" ;;
		bigint) echo "bigint" ;;
		date) echo "date" ;;
		text) echo "text" ;;
		numeric*|decimal*) echo "$t" ;;
		character\ varying*|varchar*|character*|char*) echo "varchar" ;;
		*) echo "varchar" ;;
	esac
}

# Map PG type → DuckDB read_csv column type.
external_duckdb_csv_type()
{
	local t
	t=$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/not null//g;s/^[[:space:]]*//;s/[[:space:]]*$//')
	case "$t" in
		int|integer) echo "INTEGER" ;;
		bigint) echo "BIGINT" ;;
		date) echo "DATE" ;;
		numeric*|decimal*)
			echo "$t" | sed -E 's/numeric/DECIMAL/;s/decimal/DECIMAL/' | tr '[:lower:]' '[:upper:]'
			;;
		*) echo "VARCHAR" ;;
	esac
}

# Fact / date columns for hive year/month partitioning.
# TPC-DS: date_sk → join date_dim. TPC-H: native DATE columns → EXTRACT.
# Prints: "<column>|<kind>" where kind is datesk|date. Empty if not hive-eligible.
external_hive_partition_column()
{
	external_bench_defaults
	case "${TPC_MODE}" in
		TPC-H)
			case "$1" in
				orders) echo "o_orderdate|date" ;;
				lineitem) echo "l_shipdate|date" ;;
				*) echo "" ;;
			esac
			;;
		*)
			case "$1" in
				inventory) echo "inv_date_sk|datesk" ;;
				store_sales) echo "ss_sold_date_sk|datesk" ;;
				store_returns) echo "sr_returned_date_sk|datesk" ;;
				catalog_sales) echo "cs_sold_date_sk|datesk" ;;
				catalog_returns) echo "cr_returned_date_sk|datesk" ;;
				web_sales) echo "ws_sold_date_sk|datesk" ;;
				web_returns) echo "wr_returned_date_sk|datesk" ;;
				*) echo "" ;;
			esac
			;;
	esac
}

# Backward-compatible: returns only the column name (or empty).
external_hive_date_sk_column()
{
	local info col
	info=$(external_hive_partition_column "$1")
	[ -z "$info" ] && echo "" && return
	col=$(echo "$info" | awk -F '|' '{print $1}')
	echo "$col"
}

external_hive_enabled()
{
	local v
	v=$(echo "${EXTERNAL_HIVE_PARTITIONING}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
	[ "$v" = "true" ]
}

# True if column name should be omitted from views / COPY output (TPC-H pipe terminator).
external_is_dummy_column()
{
	local n
	n=$(echo "$1" | tr '[:upper:]' '[:lower:]')
	[ "$n" = "dummy" ]
}

# Parse CREATE TABLE columns from a 03_ddl/*.postgresql.<table>.sql file.
# Prints lines: name|pg_type
external_parse_columns()
{
	local ddl_file=$1
	awk '
		BEGIN { in_tbl=0 }
		/[Cc][Rr][Ee][Aa][Tt][Ee][[:space:]]+[Tt][Aa][Bb][Ll][Ee]/ { in_tbl=1; next }
		in_tbl && /\);/ {
			# last column may share the closing ");" line — still parse before exit
			line=$0
			sub(/\);.*/, "", line)
			gsub(/^[ \t]+|[ \t]+$/, "", line)
			gsub(/^[(]+/, "", line)
			gsub(/,$/, "", line)
			if (line != "" && line !~ /^--/) {
				n = split(line, parts, /[[:space:]]+/)
				if (n >= 2) {
					name = parts[1]
					typ = parts[2]
					for (i = 3; i <= n; i++) {
						if (tolower(parts[i]) == "not" && i+1 <= n && tolower(parts[i+1]) == "null") {
							i++
							continue
						}
						typ = typ " " parts[i]
					}
					gsub(/^[ \t]+|[ \t]+$/, "", typ)
					print name "|" typ
				}
			}
			exit
		}
		in_tbl {
			line=$0
			gsub(/^[ \t]+|[ \t]+$/, "", line)
			gsub(/^[(]+/, "", line)
			gsub(/,$/, "", line)
			if (line == "" || line ~ /^--/) next
			n = split(line, parts, /[[:space:]]+/)
			if (n < 2) next
			name = parts[1]
			typ = parts[2]
			for (i = 3; i <= n; i++) {
				if (tolower(parts[i]) == "not" && i+1 <= n && tolower(parts[i+1]) == "null") {
					i++
					continue
				}
				typ = typ " " parts[i]
			}
			gsub(/^[ \t]+|[ \t]+$/, "", typ)
			print name "|" typ
		}
	' "$ddl_file"
}

external_build_copy_options()
{
	local opts="FORMAT '${USE_EXTERNAL_FORMAT}', OVERWRITE_OR_IGNORE TRUE"
	if [ "${EXTERNAL_FILE_SIZE_BYTES}" != "-1" ] && [ -n "${EXTERNAL_FILE_SIZE_BYTES}" ]; then
		opts+=", FILE_SIZE_BYTES '${EXTERNAL_FILE_SIZE_BYTES}'"
	fi
	if [ "${EXTERNAL_COMPRESSION}" != "false" ] && [ -n "${EXTERNAL_COMPRESSION}" ]; then
		opts+=", COMPRESSION '${EXTERNAL_COMPRESSION}'"
	fi
	if [ "$1" = "hive" ]; then
		opts+=", PARTITION_BY (year, month)"
	fi
	echo "$opts"
}

external_dat_glob()
{
	# TPC-DS: <table>_<child>_<parallel>.dat
	# TPC-H:  <table>.tbl*
	local table_name=$1
	external_bench_defaults
	case "${TPC_MODE}" in
		TPC-H)
			echo "${PGDATA}/arenadata_*/${table_name}.tbl*"
			;;
		*)
			echo "${PGDATA}/arenadata_*/${table_name}_[0-9]*_[0-9]*.dat"
			;;
	esac
}

# Glob used by read_* in views.
external_view_glob()
{
	local table_dir=$1
	local ext
	ext=$(external_file_ext)
	if external_hive_enabled; then
		echo "${table_dir}/**/*.${ext}"
	else
		echo "${table_dir}/*.${ext}"
	fi
}

# Extra read_* args when COPY wrote compressed csv/json (parquet codec is inside the file).
# File names stay *.csv/*.json, so DuckDB cannot infer compression from the extension.
external_view_compression_arg()
{
	case "${USE_EXTERNAL_FORMAT}" in
		csv|json)
			if [ "${EXTERNAL_COMPRESSION}" != "false" ] && [ -n "${EXTERNAL_COMPRESSION}" ]; then
				echo ", compression => '${EXTERNAL_COMPRESSION}'"
			fi
			;;
	esac
}

# FROM clause for CREATE VIEW (pg_duckdb read_*).
external_build_view_from_clause()
{
	local table_dir=$1
	local hive_flag=$2
	local glob path_expr comp_arg
	glob=$(external_view_glob "$table_dir")
	path_expr="'${glob}'::text"
	comp_arg=$(external_view_compression_arg)

	case "${USE_EXTERNAL_FORMAT}" in
		parquet)
			echo "FROM read_parquet(${path_expr}, hive_partitioning => ${hive_flag}) r"
			;;
		csv)
			echo "FROM read_csv(${path_expr}, header => true, delim => ',', hive_partitioning => ${hive_flag}${comp_arg}) r"
			;;
		json)
			# read_json in pg_duckdb has no hive_partitioning arg; recursive glob covers hive dirs.
			echo "FROM read_json(${path_expr}, format => 'newline_delimited'${comp_arg}) r"
			;;
	esac
}

# Build SELECT list casting CSV columns to typed aliases (skips TPC-H dummy).
external_build_typed_select()
{
	local ddl_file=$1
	local first=1
	local name typ cast_t
	while IFS='|' read -r name typ; do
		[ -z "$name" ] && continue
		if external_is_dummy_column "$name"; then
			continue
		fi
		cast_t=$(external_pg_cast_type "$typ")
		if [ "$first" -eq 1 ]; then
			first=0
		else
			printf ",\n"
		fi
		printf "  %s::%s AS %s" "$name" "$cast_t" "$name"
	done < <(external_parse_columns "$ddl_file")
	printf "\n"
}

external_build_csv_columns_map()
{
	local ddl_file=$1
	local first=1
	local name typ ddb_t
	printf "{"
	while IFS='|' read -r name typ; do
		[ -z "$name" ] && continue
		ddb_t=$(external_duckdb_csv_type "$typ")
		if [ "$first" -eq 1 ]; then
			first=0
		else
			printf ", "
		fi
		printf "'%s': '%s'" "$name" "$ddb_t"
	done < <(external_parse_columns "$ddl_file")
	printf "}"
}

# pg_duckdb cannot parse DuckDB columns={...} in plain SQL; wrap in duckdb.query($duck$...$duck$).
# encoding latin-1: same as classic COPY for customer (and safe for other TPC-DS .dat files).
external_read_csv_duckdb_sql()
{
	local dat_glob=$1
	local cols_map=$2
	local ddl_file=$3
	echo "SELECT"
	external_build_typed_select "$ddl_file"
	echo "FROM read_csv('${dat_glob}', delim='|', header=false, auto_detect=false, nullstr='', encoding='latin-1', columns=${cols_map})"
}

external_date_dim_csv_duckdb_sql()
{
	local date_glob=$1
	cat <<EOF
SELECT
  d_date_sk::INTEGER AS d_date_sk,
  d_year::INTEGER AS d_year,
  d_moy::INTEGER AS d_moy
FROM read_csv('${date_glob}', delim='|', header=false, auto_detect=false, nullstr='', encoding='latin-1',
  columns={'d_date_sk': 'INTEGER', 'd_date_id': 'VARCHAR', 'd_date': 'DATE', 'd_month_seq': 'INTEGER',
           'd_week_seq': 'INTEGER', 'd_quarter_seq': 'INTEGER', 'd_year': 'INTEGER', 'd_dow': 'INTEGER',
           'd_moy': 'INTEGER', 'd_dom': 'INTEGER', 'd_qoy': 'INTEGER', 'd_fy_year': 'INTEGER',
           'd_fy_quarter_seq': 'INTEGER', 'd_fy_week_seq': 'INTEGER', 'd_day_name': 'VARCHAR',
           'd_quarter_name': 'VARCHAR', 'd_holiday': 'VARCHAR', 'd_weekend': 'VARCHAR',
           'd_following_holiday': 'VARCHAR', 'd_first_dom': 'INTEGER', 'd_last_dom': 'INTEGER',
           'd_same_day_ly': 'INTEGER', 'd_same_day_lq': 'INTEGER', 'd_current_day': 'VARCHAR',
           'd_current_week': 'VARCHAR', 'd_current_month': 'VARCHAR', 'd_current_quarter': 'VARCHAR',
           'd_current_year': 'VARCHAR'})
EOF
}

external_build_view_select()
{
	local ddl_file=$1
	local first=1
	local name typ cast_t
	while IFS='|' read -r name typ; do
		[ -z "$name" ] && continue
		if external_is_dummy_column "$name"; then
			continue
		fi
		cast_t=$(external_pg_cast_type "$typ")
		if [ "$first" -eq 1 ]; then
			first=0
		else
			printf ",\n"
		fi
		printf "  r['%s']::%s AS %s" "$name" "$cast_t" "$name"
	done < <(external_parse_columns "$ddl_file")
	printf "\n"
}

ensure_pg_duckdb_extension()
{
	# DROP SCHEMA … CASCADE can drop pg_duckdb when views depend on it.
	echo "Ensuring pg_duckdb extension is installed in $DBNAME"
	psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -c "CREATE EXTENSION IF NOT EXISTS pg_duckdb;"
}

create_external_views()
{
	local root hive_flag ddl_file table_name view_sql table_dir ddl_dir
	external_bench_defaults
	root=$(external_data_root)
	ddl_dir=$(external_ddl_dir)
	if external_hive_enabled; then
		hive_flag="true"
	else
		hive_flag="false"
	fi

	echo "Creating schema ${TPC_SCHEMA} and ${USE_EXTERNAL_FORMAT} views under $root (hive_partitioning => $hive_flag)"
	ensure_pg_duckdb_extension
	psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -c "DROP SCHEMA IF EXISTS ${TPC_SCHEMA} CASCADE; CREATE SCHEMA ${TPC_SCHEMA};"
	# Cascade above may have removed the extension via dependent views — reinstall.
	ensure_pg_duckdb_extension

	for ddl_file in $(ls "$ddl_dir"/*.postgresql.*.sql | sort); do
		table_name=$(basename "$ddl_file" | awk -F '.' '{print $3}')
		case "$table_name" in
			tpcds|tpch|foreignkeys|indexes) continue ;;
		esac
		if ! grep -qiE 'create[[:space:]]+table' "$ddl_file"; then
			continue
		fi
		table_dir=$(external_table_dir "$table_name")
		view_sql=$(mktemp)
		{
			echo "CREATE VIEW ${TPC_SCHEMA}.${table_name} AS SELECT"
			external_build_view_select "$ddl_file"
			external_build_view_from_clause "$table_dir" "$hive_flag"
			echo ";"
		} > "$view_sql"
		echo "Creating view ${TPC_SCHEMA}.${table_name}"
		psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -f "$view_sql"
		rm -f "$view_sql"

		# log() expects $i (sql path) to derive numeric id — same as 03_ddl/create_tables
		i=$ddl_file
		id=$(basename "$ddl_file" | awk -F '.' '{print $1}')
		schema_name="$TPC_SCHEMA"
		start_log
		log 0
	done
}

# Backward-compatible alias
create_parquet_views()
{
	create_external_views
}

# Convert one table's flat files to external format via pg_duckdb (no heap table).
convert_table_dat_to_external()
{
	local table_name=$1
	local ddl_file=$2
	local table_dir dat_glob cols_map opts sql_file hive_info hive_col hive_kind date_glob target_path ext
	local hive_mode="no"

	table_dir=$(external_table_dir "$table_name")
	dat_glob=$(external_dat_glob "$table_name")
	cols_map=$(external_build_csv_columns_map "$ddl_file")
	hive_info=$(external_hive_partition_column "$table_name")
	hive_col=$(echo "$hive_info" | awk -F '|' '{print $1}')
	hive_kind=$(echo "$hive_info" | awk -F '|' '{print $2}')
	ext=$(external_file_ext)

	mkdir -p "$(external_data_root)"
	rm -rf "$table_dir"
	mkdir -p "$table_dir"

	if external_hive_enabled && [ -n "$hive_col" ]; then
		hive_mode="hive"
	fi
	opts=$(external_build_copy_options "$hive_mode")

	target_path="${table_dir}"
	if [ "$hive_mode" != "hive" ]; then
		if [ "${EXTERNAL_FILE_SIZE_BYTES}" = "-1" ] || [ -z "${EXTERNAL_FILE_SIZE_BYTES}" ]; then
			target_path="${table_dir}/data.${ext}"
		fi
	fi

	sql_file=$(mktemp)
	{
		echo "SET duckdb.force_execution TO true;"
		if [ "$hive_mode" = "hive" ] && [ "$hive_kind" = "datesk" ]; then
			date_glob=$(external_dat_glob "date_dim")
			echo "COPY ("
			echo "  SELECT * FROM duckdb.query(\$duck\$"
			echo "    SELECT t.*, d.d_year AS year, d.d_moy AS month"
			echo "    FROM ("
			external_read_csv_duckdb_sql "$dat_glob" "$cols_map" "$ddl_file" | sed 's/^/      /'
			echo "    ) t"
			echo "    LEFT JOIN ("
			external_date_dim_csv_duckdb_sql "$date_glob" | sed 's/^/      /'
			echo "    ) d ON t.${hive_col} = d.d_date_sk"
			echo "  \$duck\$)"
			echo ") TO '${table_dir}'"
			echo "WITH (${opts});"
		elif [ "$hive_mode" = "hive" ] && [ "$hive_kind" = "date" ]; then
			# TPC-H: native DATE columns → EXTRACT year/month (no date_dim).
			echo "COPY ("
			echo "  SELECT * FROM duckdb.query(\$duck\$"
			echo "    SELECT t.*, CAST(EXTRACT(year FROM t.${hive_col}) AS INTEGER) AS year,"
			echo "           CAST(EXTRACT(month FROM t.${hive_col}) AS INTEGER) AS month"
			echo "    FROM ("
			external_read_csv_duckdb_sql "$dat_glob" "$cols_map" "$ddl_file" | sed 's/^/      /'
			echo "    ) t"
			echo "  \$duck\$)"
			echo ") TO '${table_dir}'"
			echo "WITH (${opts});"
		else
			echo "COPY ("
			echo "  SELECT * FROM duckdb.query(\$duck\$"
			external_read_csv_duckdb_sql "$dat_glob" "$cols_map" "$ddl_file" | sed 's/^/    /'
			echo "  \$duck\$)"
			echo ") TO '${target_path}'"
			echo "WITH (${opts});"
		fi
	} > "$sql_file"

	local psql_out convert_rc=0
	set +e
	psql_out=$(psql -d "$DBNAME" -v ON_ERROR_STOP=1 -f "$sql_file" 2>&1)
	convert_rc=$?
	set -e
	# Keep convert output visible in tpcds.log / step stdout.
	echo "$psql_out"
	rm -f "$sql_file"
	CONVERT_LAST_TUPLES=$(printf '%s\n' "$psql_out" | awk '/^COPY / {s+=$2} END{print s+0}')
	if [ "$convert_rc" -ne 0 ]; then
		echo "ERROR: psql convert failed for $table_name"
		CONVERT_LAST_TUPLES=0
		return 1
	fi

	# Reject empty leftovers from failed writes.
	local out_bytes
	out_bytes=$(find "$table_dir" -type f \( -name "*.${ext}" -o -name "*.parquet" -o -name "*.csv" -o -name "*.json" \) -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
	if [ "${out_bytes:-0}" -le 0 ]; then
		echo "ERROR: no output data written for $table_name under $table_dir"
		CONVERT_LAST_TUPLES=0
		return 1
	fi
	# Ensure Data Loads report sees the row even if COPY count was not printed.
	if [ "${CONVERT_LAST_TUPLES:-0}" -le 0 ]; then
		CONVERT_LAST_TUPLES=1
	fi
	return 0
}

convert_table_dat_to_parquet()
{
	convert_table_dat_to_external "$@"
}

load_external_from_dat()
{
	local ddl_dir
	local ddl_file table_name
	local fail=0

	external_bench_defaults
	ddl_dir=$(external_ddl_dir)

	echo "Converting data files to ${USE_EXTERNAL_FORMAT} under $(external_data_root)"
	mkdir -p "$(external_data_root)"
	ensure_pg_duckdb_extension

	# Convert tables sequentially: large SF may OOM if all run in parallel via DuckDB.
	for ddl_file in $(ls "$ddl_dir"/*.postgresql.*.sql | sort); do
		table_name=$(basename "$ddl_file" | awk -F '.' '{print $3}')
		case "$table_name" in
			tpcds|tpch|foreignkeys|indexes) continue ;;
		esac
		if ! grep -qiE 'create[[:space:]]+table' "$ddl_file"; then
			continue
		fi

		if ! compgen -G "$(external_dat_glob "$table_name")" > /dev/null; then
			echo "WARNING: no source files for $table_name, skipping"
			continue
		fi

		# description = <format>.<table> so loads_report / Data Loads shows each external COPY.
		schema_name="$USE_EXTERNAL_FORMAT"
		i=$ddl_file
		id=$(basename "$ddl_file" | awk -F '.' '{print $1}')
		start_log
		echo "${USE_EXTERNAL_FORMAT} convert: $table_name"
		echo "  source glob: $(external_dat_glob "$table_name")"
		CONVERT_LAST_TUPLES=0
		if convert_table_dat_to_external "$table_name" "$ddl_file"; then
			log "${CONVERT_LAST_TUPLES:-1}"
		else
			fail=1
			log 0
			echo "ERROR: ${USE_EXTERNAL_FORMAT} conversion failed for $table_name"
			break
		fi
	done

	if [ "$fail" -ne 0 ]; then
		echo "ERROR: one or more ${USE_EXTERNAL_FORMAT} conversions failed"
		exit 1
	fi
	echo "All ${USE_EXTERNAL_FORMAT} conversions finished successfully."
}

load_parquet_from_dat()
{
	load_external_from_dat
}
