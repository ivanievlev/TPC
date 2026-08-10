#!/bin/bash
# Shared helpers for USE_EXTERNAL_FORMAT=parquet|csv|json (pg_duckdb / local files).

external_format_enabled()
{
	case "${USE_EXTERNAL_FORMAT}" in
		parquet|csv|json) return 0 ;;
		*) return 1 ;;
	esac
}

external_data_root()
{
	echo "/arenadata/tpcds_${GEN_DATA_SCALE}_${USE_EXTERNAL_FORMAT}"
}

# Remove leftover /arenadata/tpcds_*_{parquet,csv,json} trees from previous runs.
# Called from 04_load when PURGE_OLD_EXTERNAL_DATA=true (any USE_EXTERNAL_FORMAT).
purge_old_external_data()
{
	local d
	local found=0

	if [ "${PURGE_OLD_EXTERNAL_DATA:-true}" != "true" ]; then
		echo "PURGE_OLD_EXTERNAL_DATA=${PURGE_OLD_EXTERNAL_DATA:-false}: keeping existing /arenadata/tpcds_*_{parquet,csv,json}"
		return 0
	fi

	echo "PURGE_OLD_EXTERNAL_DATA=true: removing previous external data under /arenadata/tpcds_*_{parquet,csv,json}"
	shopt -s nullglob
	for d in /arenadata/tpcds_*_parquet /arenadata/tpcds_*_csv /arenadata/tpcds_*_json; do
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

# Fact tables that can be hive-partitioned by year/month via date_dim.
external_hive_date_sk_column()
{
	case "$1" in
		inventory) echo "inv_date_sk" ;;
		store_sales) echo "ss_sold_date_sk" ;;
		store_returns) echo "sr_returned_date_sk" ;;
		catalog_sales) echo "cs_sold_date_sk" ;;
		catalog_returns) echo "cr_returned_date_sk" ;;
		web_sales) echo "ws_sold_date_sk" ;;
		web_returns) echo "wr_returned_date_sk" ;;
		*) echo "" ;;
	esac
}

external_hive_enabled()
{
	local v
	v=$(echo "${EXTERNAL_HIVE_PARTITIONING}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
	[ "$v" = "true" ]
}

# Parse CREATE TABLE columns from a 03_ddl/*.postgresql.<table>.sql file.
# Prints lines: name|pg_type
external_parse_columns()
{
	local ddl_file=$1
	awk '
		BEGIN { in_tbl=0 }
		/[Cc][Rr][Ee][Aa][Tt][Ee][[:space:]]+[Tt][Aa][Bb][Ll][Ee]/ { in_tbl=1; next }
		in_tbl && /\);/ { exit }
		in_tbl {
			line=$0
			gsub(/^[ \t]+|[ \t]+$/, "", line)
			gsub(/,$/, "", line)
			if (line == "" || line ~ /^\(/ || line ~ /^--/) next
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
	# Exact TPC-DS chunk name: <table>_<child>_<parallel>.dat
	# Must NOT use <table>_*.dat — that also matches store_returns / customer_address / etc.
	local table_name=$1
	echo "${PGDATA}/arenadata_*/${table_name}_[0-9]*_[0-9]*.dat"
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

# Build SELECT list casting CSV columns to typed aliases.
external_build_typed_select()
{
	local ddl_file=$1
	local first=1
	local name typ cast_t
	while IFS='|' read -r name typ; do
		[ -z "$name" ] && continue
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
	# DROP SCHEMA tpcds CASCADE can drop pg_duckdb when views depend on it.
	echo "Ensuring pg_duckdb extension is installed in $DBNAME"
	psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -c "CREATE EXTENSION IF NOT EXISTS pg_duckdb;"
}

create_external_views()
{
	local root hive_flag ddl_file table_name view_sql table_dir
	root=$(external_data_root)
	if external_hive_enabled; then
		hive_flag="true"
	else
		hive_flag="false"
	fi

	echo "Creating schema tpcds and ${USE_EXTERNAL_FORMAT} views under $root (hive_partitioning => $hive_flag)"
	ensure_pg_duckdb_extension
	psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -c "DROP SCHEMA IF EXISTS tpcds CASCADE; CREATE SCHEMA tpcds;"
	# Cascade above may have removed the extension via dependent views — reinstall.
	ensure_pg_duckdb_extension

	for ddl_file in $(ls "$LOCAL_PWD"/03_ddl/*.postgresql.*.sql | sort); do
		table_name=$(basename "$ddl_file" | awk -F '.' '{print $3}')
		case "$table_name" in
			tpcds|foreignkeys|indexes) continue ;;
		esac
		if ! grep -qiE 'create[[:space:]]+table' "$ddl_file"; then
			continue
		fi
		table_dir=$(external_table_dir "$table_name")
		view_sql=$(mktemp)
		{
			echo "CREATE VIEW tpcds.${table_name} AS SELECT"
			external_build_view_select "$ddl_file"
			external_build_view_from_clause "$table_dir" "$hive_flag"
			echo ";"
		} > "$view_sql"
		echo "Creating view tpcds.${table_name}"
		psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -f "$view_sql"
		rm -f "$view_sql"

		# log() expects $i (sql path) to derive numeric id — same as 03_ddl/create_tables
		i=$ddl_file
		id=$(basename "$ddl_file" | awk -F '.' '{print $1}')
		schema_name="tpcds"
		start_log
		log 0
	done
}

# Backward-compatible alias
create_parquet_views()
{
	create_external_views
}

# Convert one table's .dat files to external format via pg_duckdb (no heap table).
convert_table_dat_to_external()
{
	local table_name=$1
	local ddl_file=$2
	local table_dir dat_glob cols_map opts sql_file date_sk date_glob target_path ext
	local hive_mode="no"

	table_dir=$(external_table_dir "$table_name")
	dat_glob=$(external_dat_glob "$table_name")
	cols_map=$(external_build_csv_columns_map "$ddl_file")
	date_sk=$(external_hive_date_sk_column "$table_name")
	ext=$(external_file_ext)

	mkdir -p "$(external_data_root)"
	rm -rf "$table_dir"
	mkdir -p "$table_dir"

	if external_hive_enabled && [ -n "$date_sk" ]; then
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
		if [ "$hive_mode" = "hive" ]; then
			date_glob=$(external_dat_glob "date_dim")
			echo "COPY ("
			echo "  SELECT * FROM duckdb.query(\$duck\$"
			echo "    SELECT t.*, d.d_year AS year, d.d_moy AS month"
			echo "    FROM ("
			external_read_csv_duckdb_sql "$dat_glob" "$cols_map" "$ddl_file" | sed 's/^/      /'
			echo "    ) t"
			echo "    LEFT JOIN ("
			external_date_dim_csv_duckdb_sql "$date_glob" | sed 's/^/      /'
			echo "    ) d ON t.${date_sk} = d.d_date_sk"
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

	# Reject empty / non-parquet leftovers from failed writes.
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
	local ddl_dir="$LOCAL_PWD/03_ddl"
	local ddl_file table_name
	local fail=0

	echo "Converting .dat files to ${USE_EXTERNAL_FORMAT} under $(external_data_root)"
	mkdir -p "$(external_data_root)"
	ensure_pg_duckdb_extension

	# Convert tables sequentially: large SF may OOM if all run in parallel via DuckDB.
	for ddl_file in $(ls "$ddl_dir"/*.postgresql.*.sql | sort); do
		table_name=$(basename "$ddl_file" | awk -F '.' '{print $3}')
		case "$table_name" in
			tpcds|foreignkeys|indexes) continue ;;
		esac
		if ! grep -qiE 'create[[:space:]]+table' "$ddl_file"; then
			continue
		fi

		if ! compgen -G "$(external_dat_glob "$table_name")" > /dev/null; then
			echo "WARNING: no .dat files for $table_name, skipping"
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
