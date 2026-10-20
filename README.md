# Codexion tester

A single Bash script (`run_all_tests_en.sh`) that stress-tests a 42 **Codexion** project: build, norm, README, argument parsing, simulations (fifo / edf), burnout precision, and Valgrind (memcheck, helgrind, drd).

> ⚠️ **A green run is not a proof that your project is correct.**
> The script checks what a program can check automatically. **You must read the logs** (see [Always check the logs](#-always-check-the-logs)).

---

## Requirements

- Linux / Ubuntu with `bash`, `make`, `gcc`, `awk`, `timeout` (coreutils)
- `valgrind` (optional but recommended): `sudo apt install build-essential valgrind`
- `norminette` (optional): `pip install norminette`

## Installation

Copy the script next to your `Makefile`:

```
my_project/
├── Makefile
├── README.md
├── run_all_tests_en.sh   <-- here
└── src/ ...
```

```bash
chmod +x run_all_tests_en.sh
```

## Usage

```bash
./run_all_tests_en.sh                 # full run in the current directory
./run_all_tests_en.sh ../codexion     # run on another project directory
./run_all_tests_en.sh --quick         # skip the heavy tests
./run_all_tests_en.sh --no-valgrind   # skip memcheck / helgrind / drd
./run_all_tests_en.sh --help
```

| Option | Effect |
|---|---|
| `--quick` | Skips 100/200 coders, stability runs, high-cooldown reference cases and the longest Valgrind scenarios |
| `--no-valgrind` | Disables all Valgrind passes (also the memcheck pass on invalid arguments) |

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `BURN_MAX` | `10` | Max delay (ms) allowed between the real burnout deadline and the `burned out` log |
| `TOL` | `3` | Tolerance (ms) on durations, cooldown and timestamp ordering |
| `VG_MULT` | `4` | Timeout multiplier for helgrind / drd (they are much slower than memcheck) |

```bash
BURN_MAX=15 TOL=5 ./run_all_tests_en.sh --quick
```

Don't raise `BURN_MAX` / `TOL` just to make a failing test pass: the subject requires a burnout to be reported within about 10 ms.

> The script runs `make fclean`, `make`, `make clean`, `make re`: make sure you have no uncommitted build artifacts you care about.

---

## What is tested

1. **Makefile & build**: flags `-Wall -Wextra -Werror -pthread`, rules `all clean fclean re codexion`, no warnings, no needless relink.
2. **Static analysis & README**: norminette, forbidden external functions (`nm`), presence of a heap, required README first line and sections.
3. **Invalid arguments**: wrong count, negatives, letters, floats, hex, `5e3`, `+20`, spaces, overflow, empty strings, bad scheduler (`FIFO`, `lifo`, `" fifo"`…). Each one must be rejected **without starting a simulation**, and (with Valgrind) without leak/double free.
4. **Valid edge cases**: `number_of_compiles_required = 0`, `dongle_cooldown = 0`, 2 coders.
5. **Normal simulations** (fifo & edf, 2 to 200 coders, cooldowns, N=1, tiny timings, tight edf).
6. **Expected burnouts** (1 coder, infeasible setups), with timing precision.
7. **Subject reference cases** (easy / less easy / medium).
8. **Stability**: same parameters run several times.
9. **Valgrind**: memcheck + helgrind + drd on each scenario.

For every simulation the log checker verifies: line format, monotonic timestamps, state machine (2 dongles → compile → debug → refactor), minimum durations, dongle cooldown between two neighbours, no output after `burned out`, burnout timing, and number of compiles.

## Reading the console output

```
  [ OK ] n=5 fifo [5 1000 100 100 100 3 10 fifo]
  [WARN] invalid: scheduler = FIFO (case)
         -> rejected but exit code is 0 (non-zero preferred)
         log: test_logs/087_invalid__scheduler___FIFO__case_.log
  [FAIL] impossible 5 coders edf [5 100 200 100 100 5 0 edf]
         -> coder 3: burnout logged 27 ms after the deadline (max 10 ms)
         log: test_logs/142_impossible_5_coders_edf__5_100_200_100_100_5_0_edf_.log
```

- `[ OK ]` – automatic checks passed
- `[WARN]` – not necessarily a bug, but **look at it**
- `[FAIL]` – a check failed; the log path is printed right under it

The script exits with code `0` only if there is no `FAIL` (warnings don't count).

---

## 📁 Always check the logs

Everything goes to `./test_logs/` (recreated at each run):

```
test_logs/
├── SUMMARY.txt                 <- index: every test, its verdict, its log file
├── 000_build.log               <- output of make
├── 001_invalid__no_arguments.log
├── 087_...log
└── ...
```

Each test log contains:

```
=== TEST: [Easy] 1 coder -> burnout around t=800 [1 800 200 200 200 10 0 fifo] ===
Date    : 2025-01-01 12:00:00
Dir     : /home/me/codexion

--- RUN ---
Command     : ./codexion 1 800 200 200 200 10 0 fifo
Timeout     : 15s
Return code : 0
--- stdout (first 5000 lines) ---
0 1 has taken a dongle
800 1 burned out
--- stderr (first 200 lines) ---

=== VERDICT: OK ===
```

- `Command` is **copy-pasteable**: re-run it by hand (or under `valgrind` / `gdb`) to reproduce a failure.
- Valgrind tests show the full `valgrind ... ./codexion ...` command and the Valgrind report in `stderr`.
- For invalid arguments with Valgrind, the log has two sections: the plain run and the `MEMCHECK PASS`.
- Arguments are shell-quoted, so `''` is an empty argument and `\ fifo` is `" fifo"`.

### What you must verify manually

The script cannot judge everything. Open the logs and check:

1. **Reference cases (`[Easy]`, `[Less easy]`, `[Medium]`)**
   - `burned out` appears at the right timestamp (e.g. ≈ 800 for 1 coder / 800 ms) and is the **last line**.
   - In the *Less easy* case, the burnout really is unavoidable.
2. **fifo vs edf**: for the same parameters (`cooldown 800`), compare the logs. The order in which dongles are granted should differ in a way that matches each policy (arrival order for fifo, earliest burnout deadline for edf). The script accepts either outcome (success or burnout) for these cases, so a "green" result says nothing about the policy itself.
3. **Cooldown**: after a coder releases a dongle, nobody takes it for at least `dongle_cooldown` ms.
4. **`number_of_compiles_required = 0`**: the script only checks that nothing crashes or hangs. Make sure the behaviour matches what you intended / what your subject says.
5. **Every `[WARN]`** (e.g. an invalid input rejected with exit code `0`, suspicious symbols, missing heap).
6. **Valgrind logs even when OK**: skim `stderr` for anything unexpected.
7. **Flaky tests**: if a timing test fails once and passes on re-run, your implementation is likely racy or imprecise — it's not a "tester glitch". Run the same command several times by hand.

### Tips

- Run on a quiet machine (close browsers, VMs…). Heavy load makes timing tests fail for the wrong reasons.
- Valgrind (helgrind/drd) makes everything very slow; timing is **not** checked under Valgrind, only errors and hangs.
- A `timeout` FAIL means either a deadlock/hang or a simulation that never stops: run the logged `Command` manually to see.
- Add `test_logs/` to your `.gitignore` (and don't commit the script if your school forbids extra files).

## Troubleshooting

| Problem | Fix |
|---|---|
| `Permission denied` | `chmod +x run_all_tests_en.sh` |
| `Directory not found` | Check the path passed as first argument |
| `Binary not found: cannot continue` | Read `test_logs/000_build.log` |
| `valgrind: not installed` | `sudo apt install valgrind` or use `--no-valgrind` |
| Many timing FAILs | Machine too loaded, or your `usleep`/wake-up logic is too coarse |
