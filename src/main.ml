(* Entry point of the crapper: CRAP metrics for OCaml functions. *)

open Crapper_ml

let no_coverage = ref false
let show_coverage_off = ref false
let run_coverage = ref false
let no_match_cases = ref false
let threshold = ref None
let min_crap = ref None
let ignore_modules = ref []
let coverage_command = ref None
let coverage_path = ref None
let roots = ref []
let usage = "usage: crapper [options] [files-or-dirs]"

(* A module pattern ignores the module itself and everything inside it:
   [Foo] covers [Foo.Bar.baz], but not [Foobar] *)
let rec first_n n = function
  | [] -> []
  | x :: tl -> if n <= 0 then [] else x :: first_n (n - 1) tl
;;

let ignores_module ignored (e : Model.entry) =
  let components s = String.split_on_char '.' s in
  List.exists
    (fun pattern ->
      let pattern = components (String.trim pattern) in
      let namespace = components e.Model.namespace in
      List.length pattern <= List.length namespace
      && List.for_all2 String.equal pattern (first_n (List.length pattern) namespace))
    ignored
;;

let () =
  let anon arg = roots := arg :: !roots in
  Arg.parse
    (Arg.align
       [ ( "--no-coverage"
         , Arg.Set no_coverage
         , " complexity only; coverage and CRAP are N/A" )
       ; ( "--run-coverage"
         , Arg.Set run_coverage
         , " run the default coverage command before analyzing" )
       ; ( "--coverage-command"
         , Arg.String
             (fun s ->
               coverage_command := Some s;
               run_coverage := true)
         , "CMD run this coverage command before analyzing" )
       ; ( "--show-coverage-off"
         , Arg.Set show_coverage_off
         , " print functions marked [@coverage off] as well" )
       ; ( "--min-crap"
         , Arg.Float (fun f -> min_crap := Some f)
         , "N omit functions with a CRAP score lower than N; N/A rows\n\
           \        are dropped as well" )
       ; ( "--ignore-modules"
         , Arg.String
             (fun s ->
               ignore_modules
               := String.split_on_char ',' s
                  |> List.map String.trim
                  |> List.filter (fun s -> s <> ""))
         , "M1,M2 omit the functions of these modules and\n        their submodules" )
       ; ( "--coverage-path"
         , Arg.String (fun s -> coverage_path := Some s)
         , "DIR read .coverage files from this directory instead of\n\
           \        .metrics/coverage" )
       ; ( "--no-match-cases"
         , Arg.Set no_match_cases
         , " match/function/try cases are not counted as decisions" )
       ; ( "--threshold"
         , Arg.Int (fun i -> threshold := Some i)
         , "N exit 2 when the worst score is higher" )
       ])
    anon
    usage
;;

let () =
  let roots =
    match List.rev !roots with
    | [] -> Discover.default_roots
    | roots -> roots
  in
  (* The coverage command runs first: it may rebuild the project and with it
     the .cmt files the extraction is about to read *)
  let coverage =
    if !no_coverage
    then None
    else (
      let data =
        Coverage.load
          ~run:!run_coverage
          ~command:
            (match !coverage_command with
             | Some cmd -> Some cmd
             | None ->
               if !run_coverage then Some Coverage.default_coverage_command else None)
          ~path:!coverage_path
      in
      match data with
      | [] -> None
      | _ -> Some data)
  in
  let coverage_of f =
    match coverage with
    | None -> None
    | Some data -> Coverage.coverage_of f data
  in
  let cmts = Discover.discover_cmt roots in
  if cmts = []
  then print_endline "No .cmt files found. Is the project compiled?"
  else (
    let functions =
      let count_cases = not !no_match_cases in
      List.concat_map
        (fun cmt_path ->
          try
            Crapper_ml.Extract.functions_of_cmt
              ~count_cases
              ~omit_off:(not !show_coverage_off)
              cmt_path
          with
          | exn ->
            Crapper_ml.Extract.warn_broken_cmt cmt_path exn;
            [])
        cmts
    in
    let entries =
      functions
      |> List.map (fun f -> Crap.make_entry ~coverage:(coverage_of f) f)
      |> Crap.sort_entries
    in
    (* Rows below the requested score are omitted; N/A rows cannot be
       compared and follow them out of the report *)
    let entries =
      match !min_crap with
      | None -> entries
      | Some min ->
        List.filter
          (fun e ->
            match e.Model.crap with
            | Some c when c >= min -> true
            | _ -> false)
          entries
    in
    let entries =
      if !ignore_modules = []
      then entries
      else List.filter (fun e -> not (ignores_module !ignore_modules e)) entries
    in
    print_endline (Crapper_ml.Report.format_report entries);
    (* exit 2 when the worst score is higher than the threshold *)
    match !threshold with
    | Some limit ->
      (match List.find_opt (fun e -> Option.is_some e.Model.crap) entries with
       | Some { Model.crap = Some worst; _ } when worst > float_of_int limit -> exit 2
       | _ -> ())
    | None -> ())
;;
