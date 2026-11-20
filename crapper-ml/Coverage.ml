(** Coverage from bisect_ppx.

    The [.coverage] files written by the bisect runtime are parsed directly:
    the [BISECT-COVERAGE-4] format is a length-prefixed, space-separated dump
    of every instrumented source file with the byte offsets of its points and
    their visit counts.

    Every invocation writes into its own run directory; within a run the
    counts of concurrent test processes are summed, across runs a source
    file is taken from the newest run that mentions it (see {!load}). *)

type point =
  { offset : int
  ; count : int
  }

(* Per source file: filename -> points *)
type data = (string * point list) list

let identifier = "BISECT-COVERAGE-4"
let identifier_len = String.length identifier

(* every integer and string is preceded by a space, and so is the length of
   every array *)
let parse_file content =
  let fail () = invalid_arg "Bisect coverage file" in
  let len = String.length content in
  let pos = ref 0 in
  let skip_space () =
    if !pos >= len || content.[!pos] <> ' ' then fail () else incr pos
  in
  let read_int () =
    skip_space ();
    let start = !pos in
    while !pos < len && content.[!pos] >= '0' && content.[!pos] <= '9' do
      incr pos
    done;
    if !pos = start then fail ();
    int_of_string (String.sub content start (!pos - start))
  in
  let read_string () =
    let n = read_int () in
    skip_space ();
    if !pos + n > len then fail ();
    let s = String.sub content !pos n in
    pos := !pos + n;
    s
  in
  let read_array read_element () =
    let n = read_int () in
    List.init n (fun _ -> read_element ())
  in
  if len < identifier_len || String.sub content 0 identifier_len <> identifier
  then fail ();
  pos := identifier_len;
  let n_files = read_int () in
  List.init n_files (fun _ ->
    let filename = read_string () in
    let points = read_array read_int () in
    let counts = read_array read_int () in
    if List.length points <> List.length counts then fail ();
    filename, List.map2 (fun offset count -> { offset; count }) points counts)
;;

(* Several test runs write their own [.coverage] file; sum the counts. *)
let merge (datas : data list) : data =
  let per_file = Hashtbl.create 17 in
  List.iter
    (List.iter (fun (filename, points) ->
       let per_offset =
         match Hashtbl.find_opt per_file filename with
         | Some tbl -> tbl
         | None ->
           let tbl = Hashtbl.create 17 in
           Hashtbl.add per_file filename tbl;
           tbl
       in
       List.iter
         (fun { offset; count } ->
           let old =
             match Hashtbl.find_opt per_offset offset with
             | Some old -> old
             | None -> 0
           in
           Hashtbl.replace per_offset offset (old + count))
         points))
    datas;
  Hashtbl.fold
    (fun filename per_offset acc ->
      ( (filename : string)
      , Hashtbl.fold (fun offset count acc -> { offset; count } :: acc) per_offset [] )
      :: acc)
    per_file
    []
;;

let collect dir =
  if Sys.file_exists dir && Sys.is_directory dir
  then
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".coverage")
    |> List.sort String.compare
    |> List.map (Filename.concat dir)
  else []
;;

(* [BISECT-COVERAGE-4] files placed by other tools, like [make coverage]
   writing into /tmp: every [.coverage] file below [dir] is a data point *)
let rec collect_under path acc =
  if not (Sys.file_exists path)
  then acc
  else if Sys.is_directory path
  then
    Sys.readdir path
    |> Array.fold_left (fun acc name -> collect_under (Filename.concat path name) acc) acc
  else if Filename.check_suffix (Filename.basename path) ".coverage"
  then path :: acc
  else acc
;;

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let content = really_input_string ic n in
  close_in ic;
  content
;;

(* [BISECT-COVERAGE-4] recorded the source path as the compiler saw it; look
   it up by that name first, then by the longest matching path suffix. *)
let lookup (f : Model.function_) (data : data) =
  match List.assoc_opt f.Model.path data with
  | Some _ as exact -> exact
  | None ->
    let suffix_length (name, _) =
      if
        Filename.check_suffix name f.Model.path || Filename.check_suffix f.Model.path name
      then min (String.length name) (String.length f.Model.path)
      else 0
    in
    let best =
      List.fold_left
        (fun (best, best_len) entry ->
          let n = suffix_length entry in
          if n > best_len then Some (snd entry), n else best, best_len)
        (None, 0)
        data
    in
    fst best
;;

(* The function is covered if its byte span in the source file contains
   instrumented points; a function the report does not mention scores 0%. *)
let coverage_of (f : Model.function_) (data : data) =
  match lookup f data with
  | None -> Some 0.0
  | Some points ->
    (match
       List.filter
         (fun { offset; _ } -> f.Model.start_byte <= offset && offset <= f.Model.end_byte)
         points
     with
     | [] -> Some 0.0
     | in_range ->
       let hits = List.length (List.filter (fun { count; _ } -> count > 0) in_range) in
       Some (100.0 *. float_of_int hits /. float_of_int (List.length in_range)))
;;

(* Directory where every crapper invocation gets its own run directory, so a
   rerun of unchanged tests keeps the previous report valid: dune reruns a
   test only when its sources changed, and a fresh run directory marks which
   data is current. *)
let coverage_dir = ".metrics/coverage"
let default_coverage_command = "dune runtest --instrument-with bisect_ppx"

(* Number of run directories kept on disk *)
let keep_runs = 3

let ensure_dir dir =
  let parent = Filename.dirname dir in
  if parent <> "." && not (Sys.file_exists parent) then Sys.mkdir parent 0o755;
  if not (Sys.file_exists dir) then Sys.mkdir dir 0o755
;;

let run_num dir =
  let name = Filename.basename dir in
  match String.index_opt name '-' with
  | Some i ->
    (try Some (int_of_string (String.sub name (i + 1) (String.length name - i - 1))) with
     | _ -> None)
  | None -> None
;;

(* newest run first *)
let run_dirs root =
  if Sys.file_exists root && Sys.is_directory root
  then
    Sys.readdir root
    |> Array.to_list
    |> List.filter (fun name ->
      Filename.check_suffix name ".coverage" |> not
      && String.starts_with ~prefix:"run-" name
      && run_num (Filename.concat root name) <> None)
    |> List.sort (fun a b ->
      compare
        (Option.get (run_num (Filename.concat root b)))
        (Option.get (run_num (Filename.concat root a))))
    |> List.map (Filename.concat root)
  else []
;;

let rec remove_dir dir =
  if Sys.is_directory dir
  then (
    Sys.readdir dir |> Array.iter (fun name -> remove_dir (Filename.concat dir name));
    Unix.rmdir dir)
  else Sys.remove dir
;;

(* Data of a single run: the [.coverage] files of concurrent test processes
   describe the same point table and are summed. *)
let parse_run dir =
  collect dir |> List.map (fun path -> parse_file (read_file path)) |> merge
;;

(* Across runs the data of a source file is taken from the newest run that
   mentions it: a changed source always gets a fresh run (dune reruns its
   tests), an unchanged source keeps its valid older data. *)
let merge_newest (runs : data list) : data =
  let per_file = Hashtbl.create 17 in
  List.iter
    (List.iter (fun (filename, points) ->
       if not (Hashtbl.mem per_file filename) then Hashtbl.add per_file filename points))
    runs;
  Hashtbl.fold (fun filename points acc -> (filename, points) :: acc) per_file []
;;

(* Runs the coverage command with BISECT_FILE pointing into [dir], so the
   bisect runtime writes where the caller expects it. Commands that set
   BISECT_FILE themselves (like the Makefile's [make coverage]) simply
   override the inherited value. *)
let execute_into dir = function
  | None -> ()
  | Some command ->
    ensure_dir dir;
    (* absolute: test processes run inside dune's sandbox directories *)
    let bisect_prefix = Filename.concat (Sys.getcwd ()) dir in
    let cmd =
      Printf.sprintf "BISECT_FILE=%s/bisect %s" (Filename.quote bisect_prefix) command
    in
    if Sys.command cmd <> 0
    then prerr_endline "crapper: coverage command failed; functions are scored at 0%"
;;

(* [run] executes the coverage command; without it the existing reports are
   used as they are. [path] replaces the [.metrics/coverage] run directory
   scheme entirely: a single directory owned by another tool (the Makefile's
   [make coverage] writes [/tmp/zanudacov]), read as one summed dataset. *)
let load ~run ~command ~path =
  match path with
  | Some dir ->
    if run then execute_into dir command;
    let files = collect_under dir [] in
    if files = [] then Printf.eprintf "crapper: no .coverage files in '%s'\n%!" dir;
    files |> List.map (fun p -> parse_file (read_file p)) |> merge
  | None ->
    let dirs = run_dirs coverage_dir in
    let dirs =
      match run, command with
      | true, Some command ->
        ensure_dir coverage_dir;
        let n =
          match dirs with
          | dir :: _ ->
            (match run_num dir with
             | Some n -> n + 1
             | None -> 1)
          | [] -> 1
        in
        let new_dir = Printf.sprintf "%s/run-%d" coverage_dir n in
        ensure_dir new_dir;
        execute_into new_dir (Some command);
        new_dir :: dirs
      | _ -> dirs
    in
    (* [.coverage] files left directly in the coverage directory by older
       versions are the oldest data *)
    let legacy =
      collect coverage_dir |> List.map (fun path -> parse_file (read_file path)) |> merge
    in
    let runs = dirs |> List.map parse_run in
    let data =
      match runs with
      | [] -> legacy
      | newest :: older -> merge_newest (newest :: (older @ [ legacy ]))
    in
    (* keep the newest runs only *)
    List.iteri (fun i dir -> if i >= keep_runs then remove_dir dir) dirs;
    data
;;
