open Filetransfer
open Async


let run_server () =
  let s = create_server () in
    server_add_file "mp.txt"

let _ = run_server ()
let _ = Scheduler.go ()
(* let _ = run_server () *)