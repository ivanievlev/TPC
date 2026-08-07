#!/bin/bash
# Shared helpers for USE_EXTERNAL_FORMAT=parquet (pg_duckdb / local parquet).

external_data_root()
{
	echo "/arenadata/tpcds_${GEN_DATA_SCALE}_${USE_EXTERNAL_FORMAT}"
}

external_table_dir()
{
	local table_name=$1
	echo "$(external_data_root)/${table_name}"
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
	if [ "$v" = "false" ] || [ -z "$v" ]; then
		return 1
	fi
	return 0
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
	local opts="FORMAT 'parquet', OVERWRITE_OR_IGNORE TRUE"
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
	local table_name=$1
	echo "${PGDATA}/arenadata_*/${table_name}_*.dat"
}

# Build SELECT list casting CSV columns to typed aliases.
# Uses DuckDB column names from columns={...} so we select by name.
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

create_parquet_views()
{
	local root hive_flag ddl_file table_name view_sql table_dir
	root=$(external_data_root)
	if external_hive_enabled; then
		hive_flag="true"
	else
		hive_flag="false"
	fi

	echo "Creating schema tpcds and parquet views under $root (hive_partitioning => $hive_flag)"
	psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -c "DROP SCHEMA IF EXISTS tpcds CASCADE; CREATE SCHEMA tpcds;"

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
			echo "FROM read_parquet('${table_dir}/*.parquet', hive_partitioning => ${hive_flag}) r;"
		} > "$view_sql"
		echo "Creating view tpcds.${table_name}"
		psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -f "$view_sql"
		rm -f "$view_sql"

		schema_name="tpcds"
		start_log
		log 0
	done
}

# Convert one table's .dat files to parquet via pg_duckdb (no heap table).
convert_table_dat_to_parquet()
{
	local table_name=$1
	local ddl_file=$2
	local table_dir dat_glob cols_map opts sql_file date_sk date_glob target_path
	local hive_mode="no"

	table_dir=$(external_table_dir "$table_name")
	dat_glob=$(external_dat_glob "$table_name")
	cols_map=$(external_build_csv_columns_map "$ddl_file")
	date_sk=$(external_hive_date_sk_column "$table_name")

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
			target_path="${table_dir}/data.parquet"
		fi
	fi

	sql_file=$(mktemp)
	{
		echo "SET duckdb.force_execution TO true;"
		if [ "$hive_mode" = "hive" ]; then
			date_glob=$(external_dat_glob "date_dim")
			echo "COPY ("
			echo "  SELECT t.*, d.d_year AS year, d.d_moy AS month"
			echo "  FROM ("
			echo "    SELECT"
			external_build_typed_select "$ddl_file"
			echo "    FROM read_csv('${dat_glob}', delim='|', header=false, auto_detect=false, nullstr='', columns=${cols_map}) "
			echo "  ) t"
			echo "  LEFT JOIN ("
			echo "    SELECT"
			echo "      d_date_sk::integer AS d_date_sk,"
			echo "      d_year::integer AS d_year,"
			echo "      d_moy::integer AS d_moy"
			echo "    FROM read_csv('${date_glob}', delim='|', header=false, auto_detect=false, nullstr='',"
			echo "      columns={'d_date_sk': 'INTEGER', 'd_date_id': 'VARCHAR', 'd_date': 'DATE', 'd_month_seq': 'INTEGER',"
			echo "               'd_week_seq': 'INTEGER', 'd_quarter_seq': 'INTEGER', 'd_year': 'INTEGER', 'd_dow': 'INTEGER',"
			echo "               'd_moy': 'INTEGER', 'd_dom': 'INTEGER', 'd_qoy': 'INTEGER', 'd_fy_year': 'INTEGER',"
			echo "               'd_fy_quarter_seq': 'INTEGER', 'd_fy_week_seq': 'INTEGER', 'd_day_name': 'VARCHAR',"
			echo "               'd_quarter_name': 'VARCHAR', 'd_holiday': 'VARCHAR', 'd_weekend': 'VARCHAR',"
			echo "               'd_following_holiday': 'VARCHAR', 'd_first_dom': 'INTEGER', 'd_last_dom': 'INTEGER',"
			echo "               'd_same_day_ly': 'INTEGER', 'd_same_day_lq': 'INTEGER', 'd_current_day': 'VARCHAR',"
			echo "               'd_current_week': 'VARCHAR', 'd_current_month': 'VARCHAR', 'd_current_quarter': 'VARCHAR',"
			echo "               'd_current_year': 'VARCHAR'})"
			echo "  ) d ON t.${date_sk} = d.d_date_sk"
			echo ") TO '${table_dir}'"
			echo "WITH (${opts});"
		else
			echo "COPY ("
			echo "  SELECT"
			external_build_typed_select "$ddl_file"
			echo "  FROM read_csv('${dat_glob}', delim='|', header=false, auto_detect=false, nullstr='', columns=${cols_map})"
			echo ") TO '${target_path}'"
			echo "WITH (${opts});"
		fi
	} > "$sql_file"

	psql -d "$DBNAME" -v ON_ERROR_STOP=1 -f "$sql_file"
	rm -f "$sql_file"
}

load_parquet_from_dat()
{
	local ddl_dir="$LOCAL_PWD/03_ddl"
	local ddl_file table_name
	local fail=0

	echo "Converting .dat files to parquet under $(external_data_root)"
	mkdir -p "$(external_data_root)"

	# Convert tables sequentially: large SF may OOM if all run in parallel via DuckDB.
	# Order date_dim early (harmless for non-hive; useful for clarity).
	for ddl_file in $(ls "$ddl_dir"/*.postgresql.*.sql | sort); do
		table_name=$(basename "$ddl_file" | awk -F '.' '{print $3}')
		case "$table_name" in
			tpcds|foreignkeys|indexes) continue ;;
		esac
		if ! grep -qiE 'create[[:space:]]+table' "$ddl_file"; then
			continue
		fi

		# Skip if no source .dat files
		if ! compgen -G "$(external_dat_glob "$table_name")" > /dev/null; then
			echo "WARNING: no .dat files for $table_name, skipping"
			continue
		fi

		schema_name="tpcds"
		start_log
		echo "Parquet convert: $table_name"
		if convert_table_dat_to_parquet "$table_name" "$ddl_file"; then
			log 0
		else
			fail=1
			log 0
			echo "ERROR: parquet conversion failed for $table_name"
			break
		fi
	done

	if [ "$fail" -ne 0 ]; then
		echo "ERROR: one or more parquet conversions failed"
		exit 1
	fi
	echo "All parquet conversions finished successfully."
}
