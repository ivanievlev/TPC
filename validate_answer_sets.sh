#!/bin/bash
# Validate TPC-DS SF=1 query results against toolkit answer_sets (full normalized diff).
# Invoked from 09_score (via score_helpers.print_answer_set_validation_section)
# when VALIDATE_ANSWER_SETS=true.
#
# Expected answer files live under:
#   tpcds/00_compile_tpcds/answer_sets/
# Prefer N_NULLS_LAST.ans when present (PostgreSQL NULL ordering), else N.ans.

set -euo pipefail

PWD_ROOT=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
# shellcheck source=mode.sh
source "$PWD_ROOT/mode.sh"
init_tpc_mode

VALIDATE_ANSWER_SETS="${VALIDATE_ANSWER_SETS:-false}"
GEN_DATA_SCALE="${GEN_DATA_SCALE:-}"
DBNAME="${DBNAME:-}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-1h}"
RUN_SQL_FROM_ROLE="${RUN_SQL_FROM_ROLE:-}"

if [ "$VALIDATE_ANSWER_SETS" != "true" ]; then
	exit 0
fi

if [ "$TPC_MODE" != "TPC-DS" ]; then
	echo "Step VALIDATE_ANSWER_SETS skipped because TPC_MODE=$TPC_MODE (supported for TPC-DS only)"
	exit 0
fi

# Accept 1 / 1.0
scale_norm=$(echo "$GEN_DATA_SCALE" | tr -d '[:space:]')
if [ "$scale_norm" != "1" ] && [ "$scale_norm" != "1.0" ]; then
	echo "Step VALIDATE_ANSWER_SETS skipped because GEN_DATA_SCALE > 1 (GEN_DATA_SCALE=$GEN_DATA_SCALE; requires 1)"
	exit 0
fi

if [ -z "$DBNAME" ]; then
	echo "ERROR: VALIDATE_ANSWER_SETS=true but DBNAME is empty"
	exit 1
fi

ANS_DIR="$PWD_ROOT/tpcds/00_compile_tpcds/answer_sets"
TOOLS_DIR="$PWD_ROOT/tpcds/00_compile_tpcds/tools"
TPL_DIR="$PWD_ROOT/tpcds/01_gen_data/query_templates"
[ -d "$TPL_DIR" ] || TPL_DIR="$PWD_ROOT/tpcds/00_compile_tpcds/query_templates"
DSQGEN="$PWD_ROOT/tpcds/01_gen_data/dsqgen"
[ -x "$DSQGEN" ] || DSQGEN="$TOOLS_DIR/dsqgen"

if [ ! -x "$DSQGEN" ]; then
	echo "ERROR: dsqgen not found/executable at $DSQGEN (run compile step first)"
	exit 1
fi
if [ ! -d "$ANS_DIR" ]; then
	echo "ERROR: answer_sets directory missing: $ANS_DIR"
	exit 1
fi
if [ ! -f "$TOOLS_DIR/tpcds.idx" ]; then
	echo "ERROR: tpcds.idx missing under $TOOLS_DIR"
	exit 1
fi

OUT_ROOT="$PWD_ROOT/log/answer_set_validation"
rm -rf "$OUT_ROOT"
mkdir -p "$OUT_ROOT/sql" "$OUT_ROOT/actual" "$OUT_ROOT/expected" "$OUT_ROOT/diff"

echo "############################################################################"
echo "VALIDATE_ANSWER_SETS: generating qualification queries (dsqgen -QUALIFY Y, SF=1)"
echo "############################################################################"

QUAL_DIR=$(mktemp -d /tmp/tpcds_qualify.XXXXXX)
trap 'rm -rf "$QUAL_DIR"' EXIT

# dsqgen resolves tpcds.idx relative to CWD
(
	cd "$TOOLS_DIR"
	"$DSQGEN" -QUALIFY Y \
		-input "$TPL_DIR/templates.lst" \
		-directory "$TPL_DIR" \
		-dialect pivotal \
		-scale 1 \
		-verbose y \
		-output "$QUAL_DIR"
)

QUAL_SQL="$QUAL_DIR/query_0.sql"
if [ ! -f "$QUAL_SQL" ]; then
	echo "ERROR: dsqgen did not produce $QUAL_SQL"
	exit 1
fi

# Split query_0.sql into per-query files q01.sql … q99.sql
python3 - "$QUAL_SQL" "$OUT_ROOT/sql" <<'PY'
import re, sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])
pat = re.compile(
    r"-- start query (\d+) in stream 0 using template .*?\n(.*?)-- end query \1 ",
    re.S,
)
found = {}
for m in pat.finditer(src):
    qid = int(m.group(1))
    body = m.group(2).strip() + "\n"
    found[qid] = body
    (out / f"q{qid:02d}.sql").write_text(body)
missing = [i for i in range(1, 100) if i not in found]
if missing:
    print(f"WARNING: missing qualification queries in dsqgen output: {missing[:20]}{'...' if len(missing)>20 else ''}")
print(f"Split {len(found)} qualification queries into {out}")
PY

resolve_answer_file()
{
	local qid="$1"  # 1..99 without leading zeros required
	local base="$ANS_DIR/${qid}"
	if [ -f "${base}_NULLS_LAST.ans" ]; then
		echo "${base}_NULLS_LAST.ans"
	elif [ -f "${base}.ans" ]; then
		echo "${base}.ans"
	else
		echo ""
	fi
}

echo "Running qualification queries against DBNAME=$DBNAME (statement_timeout=$STATEMENT_TIMEOUT)"
echo "Answer sets: $ANS_DIR (prefer *_NULLS_LAST.ans)"

PASS=0
FAIL=0
SKIP=0
ERROR=0
REPORT="$OUT_ROOT/report.txt"
{
	echo "TPC-DS answer-set validation report"
	echo "GEN_DATA_SCALE=$GEN_DATA_SCALE DBNAME=$DBNAME"
	echo "Answer dir: $ANS_DIR"
	echo "Started: $(date '+%Y-%m-%d_%H:%M:%S')"
	echo "------------------------------------"
} > "$REPORT"

PSQL_BIN="${PSQL_BIN:-psql}"
PSQL_USER_ARGS=()
if [ -n "$RUN_SQL_FROM_ROLE" ]; then
	PSQL_USER_ARGS=(-U "$RUN_SQL_FROM_ROLE")
fi

for qid in $(seq 1 99); do
	qpad=$(printf '%02d' "$qid")
	sql_file="$OUT_ROOT/sql/q${qpad}.sql"
	ans_file=$(resolve_answer_file "$qid")
	actual_raw="$OUT_ROOT/actual/q${qpad}.raw"
	actual_norm="$OUT_ROOT/actual/q${qpad}.norm"
	expect_norm="$OUT_ROOT/expected/q${qpad}.norm"
	diff_file="$OUT_ROOT/diff/q${qpad}.diff"

	if [ ! -f "$sql_file" ]; then
		echo "Q${qpad}: SKIP (no generated SQL)"
		echo "Q${qpad}: SKIP (no generated SQL)" >> "$REPORT"
		SKIP=$((SKIP + 1))
		continue
	fi
	if [ -z "$ans_file" ]; then
		echo "Q${qpad}: SKIP (no answer set file)"
		echo "Q${qpad}: SKIP (no answer set file)" >> "$REPORT"
		SKIP=$((SKIP + 1))
		continue
	fi

	set +e
	"$PSQL_BIN" -d "$DBNAME" "${PSQL_USER_ARGS[@]}" \
		-v ON_ERROR_STOP=1 \
		-c "SET statement_timeout TO '$STATEMENT_TIMEOUT'; SET search_path TO tpcds, public;" \
		-f "$sql_file" \
		> "$actual_raw" 2>"$OUT_ROOT/actual/q${qpad}.err"
	psql_rc=$?
	set -e

	if [ "$psql_rc" -ne 0 ]; then
		echo "Q${qpad}: ERROR (psql rc=$psql_rc) ans=$(basename "$ans_file")"
		echo "Q${qpad}: ERROR (psql rc=$psql_rc) ans=$(basename "$ans_file")" >> "$REPORT"
		if [ -s "$OUT_ROOT/actual/q${qpad}.err" ]; then
			tail -5 "$OUT_ROOT/actual/q${qpad}.err" | sed 's/^/  /'
		fi
		ERROR=$((ERROR + 1))
		continue
	fi

	# Normalize expected + actual to comparable TSV (drop separators / blank lines;
	# collapse whitespace; uppercase tokens so PG vs Oracle header case matches).
	python3 - "$ans_file" "$actual_raw" "$expect_norm" "$actual_norm" <<'PY'
import re, sys
from pathlib import Path

def normalize(text: str) -> str:
    out = []
    for line in text.splitlines():
        s = line.rstrip("\n").rstrip()
        if not s.strip():
            continue
        # Oracle/psql underline separators
        if re.fullmatch(r"[\s\-|+=]+", s):
            continue
        # Drop psql timing / status noise if present
        if s.startswith("(") and "row" in s and s.endswith(")"):
            continue
        if s.startswith("SET ") or s.startswith("Time:"):
            continue
        fields = s.split()
        if not fields:
            continue
        out.append("\t".join(tok.upper() for tok in fields))
    return "\n".join(out) + ("\n" if out else "")

ans_path, act_path, exp_out, act_out = sys.argv[1:5]
Path(exp_out).write_text(normalize(Path(ans_path).read_text(errors="replace")))
Path(act_out).write_text(normalize(Path(act_path).read_text(errors="replace")))
PY

	if cmp -s "$expect_norm" "$actual_norm"; then
		echo "Q${qpad}: PASS  ($(basename "$ans_file"))"
		echo "Q${qpad}: PASS  ($(basename "$ans_file"))" >> "$REPORT"
		PASS=$((PASS + 1))
	else
		diff -u "$expect_norm" "$actual_norm" > "$diff_file" || true
		echo "Q${qpad}: FAIL  ($(basename "$ans_file"))  diff=$diff_file"
		echo "Q${qpad}: FAIL  ($(basename "$ans_file"))  diff=$diff_file" >> "$REPORT"
		# short preview
		head -20 "$diff_file" | sed 's/^/  /'
		FAIL=$((FAIL + 1))
	fi
done

{
	echo "------------------------------------"
	echo "SUMMARY: PASS=$PASS FAIL=$FAIL ERROR=$ERROR SKIP=$SKIP"
	echo "Finished: $(date '+%Y-%m-%d_%H:%M:%S')"
	echo "Details under: $OUT_ROOT"
} | tee -a "$REPORT"

echo "VALIDATE_ANSWER_SETS report: $REPORT"

if [ "$FAIL" -gt 0 ] || [ "$ERROR" -gt 0 ]; then
	exit 1
fi
exit 0
