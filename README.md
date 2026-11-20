# crapper

CRAP scores for OCaml.
One run discovers the compiled modules of a dune
project, applies the language's complexity and coverage rules, and prints the
report.

The formula is the one from
[crap4clj](https://github.com/unclebob/crap4clj),
[crap4java](https://github.com/unclebob/crap4java), and
[crap4go](https://github.com/unclebob/crap4go):

```text
CRAP = CC² × (1 − coverage)³ + CC
```

`CC` is cyclomatic complexity. `coverage` is the fraction of the function
exercised by tests.

The tools mostly is LLM-generated.

## Run

```bash
dune build crapper-ml/
_build/default/crapper-ml/main.exe [options] [files-or-dirs]
```

The tool expects a compiled dune repository with all `.cmt` files in place.
With no arguments it walks `_build`, skipping test code (`test_*`, `*_test`,
dune's `*_tests` libraries and sandboxes) and build artifacts; a source path
argument is rewritten into `_build/default` when that exists.

## What each source counts

`.cmt` files are used only as an index: they tell which modules were compiled,
where their sources live and how dune wrapped them. The source is parsed into
the compiler parsetree and translated into the parsetree of the current
version of ppxlib, so future OCaml migrations only touch the translation.

Scored units are top-level function bindings (`let f x = ...`) and concrete
class methods; local bindings stay inside their enclosing function. The
namespace is the dune module path (`Some_lib.Module` for wrapped libraries),
so nested modules extend it (`Foo.Inner.twice`).

Decision points are `if`, `while`, `for`, each `match` / `function` / `try`
case, each `when` guard and the short-circuit operators `&&` / `||`. A
function without decisions has complexity 1. Or-patterns collapse into one
case (`A | B -> e` is a single decision). With `--no-match-cases` the cases
are not counted; guards, `if`/loops and short-circuit operators still are.

## Coverage

Coverage comes from
[bisect_ppx](https://github.com/aantron/bisect_ppx). The `.coverage` files it
writes (`BISECT-COVERAGE-4`) are parsed directly: they are a length-prefixed
dump of every instrumented point (byte offset in the source) with its visit
count. A function is covered through its byte span in the source file; a
function a present report does not mention scores 0%. With no coverage data
at all everything is N/A.

By default the tool never runs your tests: it reads the reports already on
disk. Coverage runs are opt-in:

```bash
crapper --run-coverage .                  # default command:
                                          # dune runtest --instrument-with bisect_ppx
crapper --coverage-command 'make coverage' .
crapper --coverage-path /tmp/zanudacov .  # read a directory owned by another tool
crapper --no-coverage .                   # complexity only; coverage is N/A
```

`--run-coverage` writes into a fresh `.metrics/coverage/run-N` directory;
within one run the counts of concurrent test processes are summed, across
runs a source file is taken from the newest run that mentions it (a changed
source always gets a fresh run, unchanged sources keep their valid older
data). Only the three newest run directories are kept. `--coverage-path DIR`
replaces this scheme entirely: every `.coverage` file below `DIR` is read as
one summed dataset, and the crapper sets `BISECT_FILE=<DIR>/bisect` before
running the command (commands that set `BISECT_FILE` inline, like the
Makefile's coverage target, simply override the inherited value).

## Snapshot

The report is printed on stdout, worst score first:

```text
Function                       Namespace                             CC    Cov%     CRAP
----------------------------------------------------------------------------------------
complex                        Foo                                    8    0.0%     72.0
loops                          Foo                                    3  100.0%      3.0
```

Rows without a score follow scored rows, ordered by descending complexity.
`--threshold N` exits with code 2 when the worst score is higher.

## Development

```bash
dune build
dune test
```

The cram tests in `crapper-ml/tests/` compile small fixture dune projects in
place, so every rule — extraction, complexity counting, coverage joining,
threshold exit codes — is pinned against real `.cmt` and `.coverage` files.
