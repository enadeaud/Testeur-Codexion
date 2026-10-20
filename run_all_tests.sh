#!/usr/bin/env bash
# ============================================================================
#  run_all_tests_en.sh - Unified tester for the Codexion project (42)
#
#  Usage: ./run_all_tests_en.sh [project_dir] [--quick] [--no-valgrind]
#
#     --quick        skip the heavy tests (100/200 coders, stability, long cases)
#     --no-valgrind  disable memcheck / helgrind / drd
#
#  Useful environment variables:
#     BURN_MAX=10   max gap (ms) tolerated between real burnout deadline and log
#     TOL=3         tolerance (ms) on durations / cooldown / log ordering
#     VG_MULT=4     timeout multiplier for helgrind / drd
#
#  Requirements (Ubuntu): sudo apt install build-essential valgrind
#  Optional             : norminette (pip install norminette)
#
#  Every simulation writes a log file in ./test_logs/ containing the exact
#  command that was run, its return code, stdout, stderr and the verdict.
#  ALWAYS READ THE LOGS: see README_TESTER.md.
# ============================================================================
set -u

PROJECT_DIR="."
USE_VALGRIND=1
QUICK=0
BURN_MAX=${BURN_MAX:-10}
TOL=${TOL:-3}
VG_MULT=${VG_MULT:-4}

usage() {
	cat <<'EOF'
Usage: ./run_all_tests_en.sh [project_dir] [--quick] [--no-valgrind]

  --quick        skip the heavy tests (100/200 coders, stability, long cases)
  --no-valgrind  disable memcheck / helgrind / drd
  -h, --help     show this help

Environment variables: BURN_MAX (default 10), TOL (default 3), VG_MULT (default 4)
Logs are written to ./test_logs/ (see SUMMARY.txt). Always read them.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--no-valgrind) USE_VALGRIND=0 ;;
		--quick)       QUICK=1 ;;
		-h|--help)     usage; exit 0 ;;
		*)             PROJECT_DIR="$1" ;;
	esac
	shift
done

cd "$PROJECT_DIR" || { echo "Directory not found: $PROJECT_DIR"; exit 2; }

BIN=./codexion
TMP=$(mktemp -d)
OUT="$TMP/out.txt"
ERR="$TMP/err.txt"
AWK="$TMP/check.awk"
LOGDIR="$PWD/test_logs"
trap 'rm -rf "$TMP"' EXIT
rm -rf "$LOGDIR"; mkdir -p "$LOGDIR"
SUMMARY="$LOGDIR/SUMMARY.txt"
: > "$SUMMARY"

HAVE_VG=0
if [ "$USE_VALGRIND" -eq 1 ] && command -v valgrind >/dev/null 2>&1; then HAVE_VG=1; fi

if [ -t 1 ]; then
	GREEN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'
	BOLD=$'\033[1m'; RST=$'\033[0m'
else
	GREEN=""; RED=""; YEL=""; BOLD=""; RST=""
fi

TOTAL=0; PASS=0; FAIL=0; WARN=0
FAILED_LIST=()
RC=0
LOGSEQ=0
CUR_LOG=""        # log file of the test currently running
LAST_LOG=""       # log file name of the last finished test
LAST_CMD=""       # exact command of the last run (shell-quoted)
LAST_TO=0         # timeout used for the last run

# ----------------------------------------------------------------------------
#  Log checker (awk): format, states, durations, cooldown, dongle mutual
#  exclusion, burnout precision, number of compiles.
#  Modes: success (no burnout, N compiles), burnout (burnout required),
#         either (non-empty output, success OR burnout accepted),
#         free   (anything goes, empty output accepted - e.g. N=0)
# ----------------------------------------------------------------------------
cat > "$AWK" <<'AWKEOF'
function fail(msg) { if (nerr < 5) print msg; nerr++ }

function chk(i, j,    a, b, pe, s, e, gap) {
	a = 1; b = 1; pe = -1000000000
	while (a <= cnt[i] || b <= cnt[j]) {
		if (b > cnt[j] || (a <= cnt[i] && S[i,a] <= S[j,b])) {
			s = S[i,a]; e = E[i,a]; a++
		} else {
			s = S[j,b]; e = E[j,b]; b++
		}
		if (pe > -1000000000) {
			gap = s - pe
			if (gap < cd - tol) {
				fail("shared dongle between " i " and " j ": reused too early (gap " gap " ms < cooldown " cd " ms) at t=" s)
				return
			}
		}
		pe = e
	}
}

BEGIN {
	nerr = 0; burned = 0; prev = 0
	for (i = 1; i <= n; i++) { state[i] = 0; taken[i] = 0; cnt[i] = 0 }
}

{
	line = $0
	if (line !~ /^[0-9]+ [0-9]+ (has taken a dongle|is compiling|is debugging|is refactoring|burned out)$/) {
		fail("line " NR ": invalid format [" line "]")
		next
	}
	t = $1 + 0; id = $2 + 0
	act = line; sub(/^[0-9]+ [0-9]+ /, "", act)

	if (burned) fail("line " NR ": output after 'burned out' [" line "]")
	if (t < prev - tol) fail("line " NR ": non-monotonic timestamp (" t " after " prev ")")
	if (t > prev) prev = t
	if (id < 1 || id > n) { fail("line " NR ": invalid coder id " id); next }

	if (act == "has taken a dongle") {
		if (state[id] != 0 && state[id] != 3)
			fail("line " NR ": coder " id " takes a dongle during compile/debug/refactor")
		if (state[id] == 3 && t - rs[id] < tr - tol)
			fail("line " NR ": coder " id " refactor too short (" t - rs[id] " ms < " tr ")")
		state[id] = 0; taken[id]++
	} else if (act == "is compiling") {
		if (state[id] != 0) fail("line " NR ": coder " id " compiles in a wrong state")
		if (taken[id] != 2) fail("line " NR ": coder " id " compiles with " taken[id] " dongle(s) taken (expected 2)")
		taken[id] = 0; state[id] = 1
		cnt[id]++; S[id, cnt[id]] = t; cs[id] = t
	} else if (act == "is debugging") {
		if (state[id] != 1) fail("line " NR ": coder " id " debugs without compiling")
		if (t - cs[id] < tc - tol) fail("line " NR ": coder " id " compile too short (" t - cs[id] " ms < " tc ")")
		E[id, cnt[id]] = t; state[id] = 2; ds[id] = t
	} else if (act == "is refactoring") {
		if (state[id] != 2) fail("line " NR ": coder " id " refactors without debugging")
		if (t - ds[id] < td - tol) fail("line " NR ": coder " id " debug too short (" t - ds[id] " ms < " td ")")
		state[id] = 3; rs[id] = t
	} else if (act == "burned out") {
		burned++
		dl = (cnt[id] > 0 ? cs[id] : 0) + tb
		d = t - dl
		if (d > burnmax) fail("coder " id ": burnout logged " d " ms after the deadline (max " burnmax " ms)")
		if (d < -tol)    fail("coder " id ": burnout logged " (-d) " ms BEFORE the deadline")
	}
}

END {
	if (NR == 0 && mode != "free") fail("no output")
	for (i = 1; i <= n; i++)
		if (state[i] == 1) E[i, cnt[i]] = S[i, cnt[i]] + tc
	if (n >= 2)
		for (i = 1; i <= n; i++) {
			j = (i % n) + 1
			if (n == 2 && i == 2) continue
			chk(i, j)
		}
	if (mode == "success") {
		if (burned) fail("unexpected burnout")
		for (i = 1; i <= n; i++)
			if (cnt[i] < N) fail("coder " i " only compiled " cnt[i] " times (< " N ")")
	}
	if (mode == "burnout") {
		if (!burned) fail("burnout expected but missing")
	}
	exit (nerr > 0)
}
AWKEOF

# ----------------------------------------------------------------------------
#  Logging helpers
#  One log file per test in ./test_logs/NNN_<name>.log containing:
#  the exact command, timeout, return code, stdout, stderr and the verdict.
# ----------------------------------------------------------------------------
fmt_cmd() { printf '%q ' "$@"; }

# log_begin <test name> : creates the log file and writes the current run
log_begin() {
	local safe="${1//[^A-Za-z0-9_.-]/_}"
	LOGSEQ=$((LOGSEQ+1))
	CUR_LOG="$LOGDIR/$(printf '%03d' "$LOGSEQ")_${safe:0:80}.log"
	{
		echo "=== TEST: $1 ==="
		echo "Date    : $(date '+%Y-%m-%d %H:%M:%S')"
		echo "Dir     : $PWD"
	} > "$CUR_LOG"
	log_section "RUN"
}

# log_section [title] : appends the last run (command, rc, stdout, stderr)
log_section() {
	[ -z "$CUR_LOG" ] && return
	{
		echo
		echo "--- ${1:-RUN} ---"
		echo "Command     : $LAST_CMD"
		echo "Timeout     : ${LAST_TO}s"
		echo "Return code : $RC"
		echo "--- stdout (first 5000 lines) ---"
		head -n 5000 "$OUT"
		echo "--- stderr (first 200 lines) ---"
		head -n 200 "$ERR"
	} >> "$CUR_LOG"
}

# record <STATUS> <name> <detail> : writes the verdict in the log and SUMMARY.txt
record() {
	LAST_LOG=""
	if [ -n "$CUR_LOG" ]; then
		{
			echo
			echo "=== VERDICT: $1 ==="
			[ -n "${3:-}" ] && echo "$3"
		} >> "$CUR_LOG"
		LAST_LOG=$(basename "$CUR_LOG")
		CUR_LOG=""
	fi
	printf '[%-4s] %s%s\n' "$1" "$2" "${LAST_LOG:+  ->  $LAST_LOG}" >> "$SUMMARY"
}

section() {
	printf "\n%s== %s ==%s\n" "$BOLD" "$1" "$RST"
	printf '\n== %s ==\n' "$1" >> "$SUMMARY"
}

pass() {
	TOTAL=$((TOTAL+1)); PASS=$((PASS+1))
	record "OK" "$1" ""
	printf "  %s[ OK ]%s %s\n" "$GREEN" "$RST" "$1"
}
fail() {
	TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILED_LIST+=("$1")
	record "FAIL" "$1" "${2:-}"
	printf "  %s[FAIL]%s %s\n" "$RED" "$RST" "$1"
	[ -n "${2:-}" ] && printf "         -> %s\n" "$(echo "$2" | head -n 3 | sed '2,$s/^/            /')"
	[ -n "$LAST_LOG" ] && printf "         log: test_logs/%s\n" "$LAST_LOG"
}
warn() {
	TOTAL=$((TOTAL+1)); WARN=$((WARN+1))
	record "WARN" "$1" "${2:-}"
	printf "  %s[WARN]%s %s\n" "$YEL" "$RST" "$1"
	[ -n "${2:-}" ] && printf "         -> %s\n" "$2"
	[ -n "$LAST_LOG" ] && printf "         log: test_logs/%s\n" "$LAST_LOG"
}

# ----------------------------------------------------------------------------
#  Running a simulation: run_sim <timeout_s> <args...>
# ----------------------------------------------------------------------------
run_sim() {
	local to=$1; shift
	LAST_CMD=$(fmt_cmd "$BIN" "$@")
	LAST_TO=$to
	timeout -k 2 "$to" "$BIN" "$@" >"$OUT" 2>"$ERR" </dev/null
	RC=$?
}

is_timeout() { [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; }
is_crash()   { [ "$RC" -gt 128 ]; }

# Invalid arguments: the program must refuse without starting a simulation.
# If valgrind is available, a second memcheck pass checks the error path
# (double free, leak, invalid free...).
t_invalid() {
	local name="invalid: $1"; shift
	run_sim 5 "$@"
	log_begin "$name"
	if is_timeout; then fail "$name" "timeout: input was not rejected"; return; fi
	if is_crash;   then fail "$name" "crash (signal $((RC-128)))"; return; fi
	if grep -qE '^[0-9]+ [0-9]+ (has taken a dongle|is compiling|is debugging|is refactoring|burned out)$' "$OUT"; then
		fail "$name" "a simulation was started"; return
	fi
	local rc_plain=$RC
	if [ "$HAVE_VG" -eq 1 ]; then
		LAST_CMD=$(fmt_cmd valgrind -q --error-exitcode=42 --leak-check=full \
			--show-leak-kinds=all --track-origins=yes "$BIN" "$@")
		LAST_TO=30
		timeout -k 2 30 valgrind -q --error-exitcode=42 --leak-check=full \
			--show-leak-kinds=all --track-origins=yes "$BIN" "$@" \
			>"$OUT" 2>"$ERR" </dev/null
		RC=$?
		log_section "MEMCHECK PASS"
		if [ "$RC" -eq 42 ]; then fail "$name (memcheck)" "$(grep -m3 -E '==[0-9]+==' "$ERR")"; return; fi
		if is_timeout; then fail "$name (memcheck)" "timeout under valgrind"; return; fi
	fi
	if [ "$rc_plain" -eq 0 ]; then
		warn "$name" "rejected but exit code is 0 (non-zero preferred)"
	else
		pass "$name"
	fi
}

# Valid simulation: t_sim <success|burnout|either|free> <timeout> <label> n tb tc td tr N cd sched
t_sim() {
	local mode=$1 to=$2 label=$3; shift 3
	local name="$label [$*]"
	run_sim "$to" "$@"
	log_begin "$name"
	if is_timeout; then fail "$name" "timeout after ${to}s"; return; fi
	if is_crash;   then fail "$name" "crash (signal $((RC-128)))"; return; fi
	local msg rc
	msg=$(awk -f "$AWK" -v mode="$mode" -v n="$1" -v tb="$2" -v tc="$3" -v td="$4" \
		-v tr="$5" -v N="$6" -v cd="$7" -v burnmax="$BURN_MAX" -v tol="$TOL" "$OUT" 2>&1)
	rc=$?
	if [ $rc -eq 0 ]; then pass "$name"; else fail "$name" "$msg"; fi
}

# Valgrind: t_vg <memcheck|helgrind|drd> <label> <timeout> args...
t_vg() {
	local tool=$1 label=$2 to=$3; shift 3
	local name="valgrind/$tool $label [$*]"
	local opts=()
	case "$tool" in
		memcheck) opts=(--leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=all --track-origins=yes) ;;
		helgrind) opts=(--tool=helgrind) ;;
		drd)      opts=(--tool=drd) ;;
	esac
	LAST_CMD=$(fmt_cmd valgrind -q --error-exitcode=42 "${opts[@]}" "$BIN" "$@")
	LAST_TO=$to
	timeout -k 5 "$to" valgrind -q --error-exitcode=42 "${opts[@]}" "$BIN" "$@" \
		>"$OUT" 2>"$ERR" </dev/null
	RC=$?
	log_begin "$name"
	if is_timeout; then fail "$name" "timeout after ${to}s (hang or tool too slow)"; return; fi
	if [ "$RC" -eq 42 ]; then fail "$name" "$(grep -m3 -E '==[0-9]+==' "$ERR")"; return; fi
	if is_crash; then fail "$name" "crash (signal $((RC-128)))"; return; fi
	pass "$name"
}

# The 3 valgrind tools on one scenario: t_vg_all <label> <memcheck_timeout> args...
# helgrind/drd are much slower: timeout multiplied by VG_MULT.
t_vg_all() {
	local label=$1 to=$2; shift 2
	t_vg memcheck "$label" "$to" "$@"
	t_vg helgrind "$label" $((to * VG_MULT)) "$@"
	t_vg drd      "$label" $((to * VG_MULT)) "$@"
}

# Mutate one base argument: t_mut <label> <index> <value>
t_mut() {
	local a=("${BASE[@]}")
	a[$2]="$3"
	t_invalid "$1" "${a[@]}"
}

# ============================================================================
#  1. Makefile & build
# ============================================================================
section "Makefile & build"

if [ -f Makefile ]; then pass "Makefile present"; else fail "Makefile present" "Makefile not found"; fi

for flag in -Wall -Wextra -Werror -pthread; do
	if grep -q -- "$flag" Makefile 2>/dev/null; then pass "Makefile contains $flag"
	else fail "Makefile contains $flag" "flag missing from Makefile"; fi
done

for r in all clean fclean re codexion; do
	if make -n "$r" >/dev/null 2>&1; then pass "rule '$r' exists"
	else fail "rule '$r' exists" "make -n $r failed"; fi
done

make fclean >/dev/null 2>&1
BUILD_OUT=$(make 2>&1); BUILD_RC=$?
{
	echo "=== BUILD LOG ==="
	echo "Command     : make fclean && make"
	echo "Return code : $BUILD_RC"
	echo "--- output ---"
	echo "$BUILD_OUT"
} > "$LOGDIR/000_build.log"
if [ $BUILD_RC -eq 0 ] && [ -x "$BIN" ]; then pass "make builds ./codexion"
else
	fail "make builds ./codexion" "$(echo "$BUILD_OUT" | tail -n 3)"
	echo; echo "Binary not found: cannot continue (see test_logs/000_build.log)."; exit 1
fi
if echo "$BUILD_OUT" | grep -qiE 'warning:'; then fail "no compilation warning" "$(echo "$BUILD_OUT" | grep -i -m2 'warning:')"
else pass "no compilation warning"; fi

REBUILD_OUT=$(make 2>&1)
if echo "$REBUILD_OUT" | grep -qE '(^|[ /])(cc|gcc|clang) '; then fail "no needless relink" "2nd make recompiles"
else pass "no needless relink"; fi

make clean >/dev/null 2>&1
if [ -x "$BIN" ]; then pass "make clean keeps the binary"; else fail "make clean keeps the binary" "binary removed"; fi
make fclean >/dev/null 2>&1
if [ ! -e "$BIN" ]; then pass "make fclean removes the binary"; else fail "make fclean removes the binary" "binary still present"; fi
make re >/dev/null 2>&1
if [ -x "$BIN" ]; then pass "make re rebuilds the binary"; else fail "make re rebuilds the binary" "make re failed"; fi

# ============================================================================
#  2. Static analysis / README
# ============================================================================
section "Static analysis & README"

if command -v norminette >/dev/null 2>&1; then
	NORM_OUT=$(norminette $(find . -type f \( -name '*.c' -o -name '*.h' \) -not -path './test_logs/*') 2>&1 \
		| grep -vE '^Setting locale to |: OK!$')
	if [ -z "$NORM_OUT" ]; then pass "norminette"; else fail "norminette" "$NORM_OUT"; fi
else
	warn "norminette" "not installed (pip install norminette)"
fi

if command -v nm >/dev/null 2>&1; then
	ALLOWED='^(pthread_[a-z_]+|gettimeofday|clock_gettime|usleep|write|malloc|free|printf|fprintf|strcmp|strlen|atoi|memset|puts|putchar|fputs|fwrite|memcpy|stdout|stderr|__.*|_ITM_.*|_.*)$'
	BAD=$(nm -u "$BIN" 2>/dev/null | awk '{print $NF}' | sed 's/@.*//' | grep -vE "$ALLOWED" | sort -u | tr '\n' ' ')
	if [ -z "$BAD" ]; then pass "only allowed external functions"
	else warn "only allowed external functions" "suspicious symbols: $BAD"; fi
fi

if grep -rliE 'heap' --include='*.c' --include='*.h' . 2>/dev/null | grep -qv test_logs; then
	pass "priority queue (heap) found in sources"
else
	warn "priority queue (heap) found in sources" "no file mentions 'heap'"
fi

if [ -f README.md ]; then pass "README.md present"; else fail "README.md present" "README.md not found"; fi
FIRST=$(head -n 1 README.md 2>/dev/null)
if echo "$FIRST" | grep -qE '^[*_]This project has been created as part of the 42 curriculum by .+[*_]$'; then
	pass "README: first line in italics"
else
	fail "README: first line in italics" "line 1 = [$FIRST]"
fi
for sec in "Description" "Instructions" "Resources" "Blocking cases handled" "Thread synchronization mechanisms"; do
	if grep -qiE "^#+[[:space:]]*$sec" README.md 2>/dev/null; then pass "README: section '$sec'"
	else fail "README: section '$sec'" "heading not found"; fi
done

# ============================================================================
#  3. Invalid arguments
# ============================================================================
BASE=(5 800 200 100 100 3 50 fifo)
NAMES=(number_of_coders time_to_burnout time_to_compile time_to_debug time_to_refactor number_of_compiles_required dongle_cooldown scheduler)

section "Invalid arguments: argument count"

t_invalid "no arguments"
t_invalid "single argument" 5
t_invalid "5 arguments out of 8" 20 5000 200 200 200
t_invalid "7 arguments (scheduler missing)" "${BASE[@]:0:7}"
t_invalid "9 arguments (one too many)" "${BASE[@]}" 42
t_invalid "wrong order (scheduler first)" fifo 20 5000 200 200 200 10 0

section "Invalid arguments: numeric format"

for i in 0 1 2 3 4 5 6; do t_mut "${NAMES[$i]} = -1" "$i" "-1"; done
for i in 0 1 2 3 4 5 6; do t_mut "${NAMES[$i]} = abc" "$i" "abc"; done
for i in 0 1 2 3 4 5 6; do t_mut "${NAMES[$i]} = 1.5" "$i" "1.5"; done
t_mut "number_of_coders = 0" 0 "0"
t_mut "number_of_coders = -20" 0 "-20"
t_mut "time_to_burnout = -5000" 1 "-5000"
t_mut "dongle_cooldown = -50" 6 "-50"
t_mut "scientific notation (5e3)" 1 "5e3"
t_mut "hexadecimal (0x1388)" 1 "0x1388"
t_mut "leading space (' 20')" 0 " 20"
t_mut "trailing space ('20 ')" 0 "20 "
t_mut "explicit plus sign (+20)" 0 "+20"
t_mut "thousands separator (5,000)" 1 "5,000"
t_mut "INT_MAX + 1 (2147483648)" 0 "2147483648"
t_mut "integer overflow (20 digits) on time_to_burnout" 1 "99999999999999999999"
t_mut "integer overflow (20 digits) on number_of_coders" 0 "99999999999999999999"
t_mut "empty string for number_of_coders" 0 ""
t_mut "time_to_compile = empty string" 2 ""

section "Invalid arguments: tricky cases"

t_mut "number followed by text (20abc)" 0 "20abc"
t_mut "time_to_burnout = 12abc" 1 "12abc"
t_mut "text followed by number (abc20)" 0 "abc20"
t_mut "number with unit (20ms)" 0 "20ms"
t_mut "scheduler = FIFO (case)" 7 "FIFO"
t_mut "scheduler = EDF (case)" 7 "EDF"
t_mut "scheduler = ' fifo' (space)" 7 " fifo"
t_mut "scheduler = 'edf ' (space)" 7 "edf "
t_mut "scheduler = fifoo" 7 "fifoo"
t_mut "scheduler = fifo2" 7 "fifo2"
t_mut "scheduler = rr" 7 "rr"
t_mut "scheduler = lifo (not allowed)" 7 "lifo"
t_mut "scheduler = empty string" 7 ""

# ============================================================================
#  4. Valid edge cases
# ============================================================================
section "Valid edge cases"

# N=0: behaviour not specified -> only require no crash/hang and consistent logs
t_sim free   15 "number_of_compiles_required = 0 (immediate stop)" 5 5000 200 200 200 0 0 fifo
t_sim either 20 "dongle_cooldown = 0"                              5 5000 200 200 200 5 0 fifo
t_sim either 15 "2 coders (smallest ring with 2 dongles)"          2 5000 200 200 200 5 0 fifo

# ============================================================================
#  5. Simulations that must end normally
# ============================================================================
section "Simulations without burnout (fifo & edf)"

SIZES=(2 3 4 5 7 10 20 50)
[ "$QUICK" -eq 0 ] && SIZES+=(100 200)
for s in fifo edf; do
	for n in "${SIZES[@]}"; do
		t_sim success 40 "n=$n $s" "$n" 1000 100 100 100 3 10 "$s"
	done
done

section "Cooldown, N=1, tiny timings, tight edf"
for s in fifo edf; do
	t_sim success 40 "cooldown 0 $s"   4 1000 100 100 100 3 0   "$s"
	t_sim success 40 "cooldown 200 $s" 4 2000 100 100 100 3 200 "$s"
	t_sim success 60 "cooldown 500 $s" 4 4000 100 100 100 3 500 "$s"
	t_sim success 20 "N=1 $s"          4 1000 100 100 100 1 10  "$s"
	t_sim success 40 "N=20 tiny timings $s" 5 500 10 10 10 20 2 "$s"
done
t_sim success 40 "tight edf, 5 coders" 5 500 100 50 50 5 10 edf
t_sim success 40 "tight edf, 3 coders" 3 400 100 100 100 5 5 edf
t_sim success 40 "tight edf, 7 coders" 7 600 100 100 100 5 10 edf

section "Subject reference cases (easy)"
t_sim success 15 "[Easy] 5 coders, wide margin, fifo, 10 compiles" 5 2000 200 200 200 10 0 fifo
t_sim success 15 "[Easy] 5 coders, wide margin, edf, 7 compiles"   5 2000 200 200 200 7  0 edf

# ============================================================================
#  6. Simulations that must end with a burnout
# ============================================================================
section "Expected burnout (precision <= ${BURN_MAX} ms)"

t_sim burnout 15 "[Easy] 1 coder -> burnout around t=800" 1 800 200 200 200 10 0 fifo
t_sim burnout 15 "[Less easy] infeasible -> burnout around t=500" 5 500 200 200 200 10 0 fifo

for s in fifo edf; do
	for tb in 100 200 500 800; do
		t_sim burnout 15 "1 coder, burnout $tb ms $s" 1 "$tb" 100 100 100 3 0 "$s"
	done
	t_sim burnout 15 "impossible 2 coders $s"   2   100 200 100 100 5 0 "$s"
	t_sim burnout 15 "impossible 3 coders $s"   3   150 100 100 100 5 0 "$s"
	t_sim burnout 15 "impossible 5 coders $s"   5   100 200 100 100 5 0 "$s"
	t_sim burnout 15 "impossible 4 coders $s"   4    50 300 300 300 5 0 "$s"
	t_sim burnout 15 "impossible 10 coders $s" 10   200 300 100 100 5 0 "$s"
	t_sim burnout 15 "impossible 50 coders $s" 50   100 500 100 100 5 0 "$s"
	[ "$QUICK" -eq 0 ] && \
	t_sim burnout 20 "impossible 200 coders $s" 200  50 100 100 100 5 0 "$s"
	t_sim burnout 15 "cooldown too long $s"     2   300 100 100 100 5 1000 "$s"
done

# ============================================================================
#  7. Subject reference cases: high cooldown (fifo vs edf)
#     Structural check only (format, dongles, cooldown, durations); the
#     outcome (success or burnout) is accepted. Compare the logs by hand.
# ============================================================================
if [ "$QUICK" -eq 0 ]; then
	section "Subject reference cases (high cooldown)"
	t_sim success 150 "[Medium] cooldown 400, wide margin, fifo" 5 3000 200 200 200 10 400 fifo
	t_sim either   60 "[Medium] cooldown 800 fifo"               5 3000 200 200 200 10 800 fifo
	t_sim either   60 "[Medium] cooldown 800 edf"                5 3000 200 200 200 10 800 edf
fi

# ============================================================================
#  8. Stability (same parameters, several runs)
# ============================================================================
if [ "$QUICK" -eq 0 ]; then
	section "Stability (5 runs per scheduler)"
	for s in fifo edf; do
		for i in 1 2 3 4 5; do
			t_sim success 40 "run $i/5 $s" 5 800 100 100 100 5 10 "$s"
		done
	done
fi

# ============================================================================
#  9. Valgrind: memcheck + helgrind + drd on each scenario
# ============================================================================
if [ "$USE_VALGRIND" -eq 1 ]; then
	section "Valgrind (memcheck + helgrind + drd)"
	if [ "$HAVE_VG" -eq 1 ]; then
		t_vg_all "ends after N compiles fifo"  60 4 4000 50 50 50 2 5 fifo
		t_vg_all "ends after N compiles edf"   60 4 4000 50 50 50 2 5 edf
		t_vg_all "1 coder -> burnout"          30 1 800 200 200 200 10 0 fifo
		t_vg_all "impossible burnout fifo"     30 5 500 200 200 200 10 0 fifo
		t_vg_all "impossible burnout edf"      30 3 150 100 100 100 5 0 edf
		t_vg_all "2 coders"                    30 2 5000 200 200 200 5 0 fifo
		t_vg_all "N = 0"                       30 5 5000 200 200 200 0 0 fifo
		t_vg_all "cooldown 0"                  60 5 5000 200 200 200 5 0 fifo
		if [ "$QUICK" -eq 0 ]; then
			t_vg_all "[Easy] 5 coders fifo"        60 5 2000 200 200 200 10 0 fifo
			t_vg_all "[Easy] 5 coders edf"         60 5 2000 200 200 200 7  0 edf
			t_vg_all "[Medium] cooldown 400 fifo" 150 5 3000 200 200 200 10 400 fifo
			t_vg_all "[Medium] cooldown 800 fifo"  60 5 3000 200 200 200 10 800 fifo
			t_vg_all "[Medium] cooldown 800 edf"   60 5 3000 200 200 200 10 800 edf
		fi
	else
		warn "valgrind" "not installed (sudo apt install valgrind)"
	fi
fi

# ============================================================================
#  Summary
# ============================================================================
{
	echo
	echo "================ SUMMARY ================"
	echo "Total    : $TOTAL"
	echo "Passed   : $PASS"
	echo "Warnings : $WARN"
	echo "Failed   : $FAIL"
} >> "$SUMMARY"

printf "\n%s================ SUMMARY ================%s\n" "$BOLD" "$RST"
printf " Total    : %d\n" "$TOTAL"
printf " %sPassed%s   : %d\n" "$GREEN" "$RST" "$PASS"
printf " %sWarnings%s : %d\n" "$YEL" "$RST" "$WARN"
printf " %sFailed%s   : %d\n" "$RED" "$RST" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf "\nFailed tests:\n"
	for f in "${FAILED_LIST[@]}"; do printf "  - %s\n" "$f"; done
fi
printf "\n%sLogs:%s %s\n" "$BOLD" "$RST" "$LOGDIR"
printf "  Index of every test and its log file : test_logs/SUMMARY.txt\n"
printf "  Each log contains the exact command, return code, stdout, stderr and verdict.\n"
printf "\n%sREMINDER:%s a green run is NOT a proof of correctness. Read the logs of the\n" "$BOLD" "$RST"
printf "reference cases (burnout timestamp, fifo vs edf order, cooldown, N=0 behaviour)\n"
printf "and every WARN. See README_TESTER.md.\n"
[ "$FAIL" -eq 0 ]
