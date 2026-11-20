The fixture dune project lives in the fixture/ subdirectory; the test
driver and the compiled crapper.exe stay outside of it, so the
coverage command's own 'dune runtest' cannot recurse into this test.

  $ cd fixture
  $ dune build

By default the coverage command is not run; without coverage data
everything is N/A:

  $ ../../crapper.exe . | grep complex
  complex                        Foo                                    8     N/A      N/A

The user runs the coverage explicitly:

  $ ../../crapper.exe --coverage-command 'dune runtest --instrument-with bisect_ppx_ng --sandbox=none' .
  CRAP Report
  ===========
  Languages: OCaml
  
  Function                       Module                                CC    Cov%     CRAP
  ----------------------------------------------------------------------------------------
  complex                        Foo                                    8    0.0%     72.0
  g                              Foo                                    4    0.0%     20.0
  andor                          Foo                                    3    0.0%     12.0
  guarded                        Foo                                    3    0.0%     12.0
  visible                        Foo                                    2    0.0%      6.0
  loops                          Foo                                    3  100.0%      3.0
  odd                            Foo                                    2   66.7%      2.1
  even                           Foo                                    2  100.0%      2.0
  local                          Foo                                    1    0.0%      2.0
  mul                            Foo.Bar                                1    0.0%      2.0
  add                            Foo                                    1  100.0%      1.0
  twice                          Foo.Inner                              1  100.0%      1.0
  bump                           Foo.counter                            1  100.0%      1.0
  get                            Foo.counter                            1  100.0%      1.0
  

  $ ../../crapper.exe --threshold 71 . > /dev/null
  [2]
  $ ../../crapper.exe --threshold 72 . > /dev/null

Functions wrapped in [@coverage off] regions are omitted by default:

  $ ../../crapper.exe . | grep -c omitted || true
  0

  $ ../../crapper.exe --show-coverage-off . | grep omitted_by_marker
  omitted_by_marker              Foo                                    2    0.0%      6.0

Modules can be ignored from the output, submodules included:

  $ ../../crapper.exe --no-coverage --ignore-modules Foo.Inner,Foo.counter . | grep Foo.Bar
  mul                            Foo.Bar                                1     N/A      N/A

  $ ../../crapper.exe --no-coverage --ignore-modules Foo.Inner,Foo.counter . | grep -E "twice|bump|get" | wc -l
  0

  $ ../../crapper.exe --no-coverage --ignore-modules Foo . | grep -c "N/A" || true
  0

The coverage can also live in a directory of its own, next to other tools
that produce [.coverage] files:

  $ mkdir -p customcov && cp .metrics/coverage/run-1/*.coverage customcov/
  $ ../../crapper.exe --coverage-path customcov . | grep complex
  complex                        Foo                                    8    0.0%     72.0

A directory without any report is reported on stderr:

  $ mkdir -p emptydir
  $ ../../crapper.exe --coverage-path emptydir . > /dev/null
  crapper: no .coverage files in 'emptydir'
  $ rm -rf customcov emptydir

  $ ../../crapper.exe --no-coverage . | grep complex
  complex                        Foo                                    8     N/A      N/A
