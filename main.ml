(* Uses communicator to discover other peers *)
(* Establishes a connection via communicator *)
(* If differences on either this machine or the other, transfer handles updates *)
(* GUI displays all stuff *)
(* Crypto encrpyts files and user info/ connection-establishing processes *)
open Communication
open Crypto
open State
open Async
open Async.Reader
open Async_extra
open Peer_discovery
open Config

let bcast_interval = 5.

(* Name, pubkey*)
type disc_peer = string*Communication.peer
type bcast_msg = string*Crypto.key


let compute_hash s =
  let hash = ref 0 in
  let update_hash c =
    let h = !hash in
    let h' = ((h lsl 5) - h) + (Char.code c) in
    hash := h' land h'
  in String.iter (update_hash) s; !hash


let bcastmsg_to_string (m:bcast_msg) : string =
  let data = Marshal.to_string m [] in
  let payload = (string_of_int (compute_hash data), data) in
  Marshal.to_string payload []


let string_bcast_msg s : bcast_msg option =
  let (hash, buf) : (string*string) = Marshal.from_string s 0 in
  let data : bcast_msg = Marshal.from_string buf 0 in
  if (string_of_int (compute_hash buf)) = hash then
    Some data
  else
    None


(* Empty function for converting deferred to unit *)
let to_unit d = upon d (fun _ -> ())

let rec peer_syncer peers (mypeer:Crypto.key) st =
  upon(after (Core.sec bcast_interval) >>= fun () ->
       print_string "In peer syncer";
  if Hashtbl.mem peers mypeer then
    let _ = print_endline "Attempting to sync" in
    let (name,pinfo) = Hashtbl.find peers mypeer in
    let _ = State.update_state !st >>= fun ns -> st := ns; Deferred.return () in
    let strs = State.to_string !st in
    let _ = Config.save_st_string strs (State.root_dir !st) in
    print_string "Send: "; print_int (compute_hash strs); print_endline "";
    Communication.send_state pinfo strs
  else Deferred.return (print_endline "No peer found")) (fun () -> peer_syncer peers mypeer st)


let peer_discovered (peers: ((Crypto.key, disc_peer) Hashtbl.t)) addr msg  =
  print_string "Peer discovered";
  match (string_bcast_msg msg) with
  | Some (name, key) ->
    Hashtbl.add peers key (name,{ip=addr; key=key});
    print_endline ("Found peer: "^name^" "^addr^": "^(Crypto.string_from_key key))
  | None -> print_string "Garbage!"


let proc_state_update pubpriv currstate rs pr :state_info Deferred.t  =
  let ups = State.files_to_request currstate rs in
  print_endline (string_of_int (List.length ups)^" files");
  let recf st f :state_info Deferred.t = (Communication.request_file pubpriv pr f ((State.root_dir currstate)^f)) >>= fun () -> st >>= fun st' ->
    print_endline ("Recvd file:"^f);
    (State.acknowledge_file_recpt st' f)
  in
  List.fold_left recf (Deferred.return currstate) ups


let comm_server pubpriv currstate rset mypeer = (* TODO make sure peer is who we think it is*)
  let notify_callback cstate pr msg =
    match msg with
    | State s ->
      print_string "Got: "; print_int (compute_hash s); print_endline "";
      begin
        print_string "Got state update!";
        let rst = State.from_string s in
        match !rset with
        | None -> rset := Some rst; proc_state_update pubpriv (!currstate) rst pr >>= fun ns ->
          let _  = Config.save_state ns (State.root_dir ns) in
          currstate := ns;
          Deferred.return (rset := None)
        | _ -> Deferred.return (print_endline "Pending update!") (* Ignore if already being processed*)
      end
    | Filerequest f ->
      print_string "Got request for file!";
      Communication.transfer_file mypeer ((State.root_dir !currstate)^f) cstate
  in
  print_string "Running Server\n";
  Communication.start_server notify_callback


let rec peer_broadcaster msg =
  upon(after (Core.sec bcast_interval) >>= fun () ->
                          Peer_discovery.broadcast msg )
    (fun () -> print_endline "sent bcast"; peer_broadcaster msg)



let load_keys rdir =
  print_endline "Looking for keys...";
  try
    Config.load_pubkey rdir >>= fun pub ->
    Config.load_privkey rdir >>= fun priv ->
    Deferred.return (Crypto.of_string pub, Crypto.of_string priv)
  with exn ->
    let _ = print_string "Creating new keys.\n" in
    let (pub, priv) = Crypto.generate_public_private () in
    let (pubs, privs) = (Crypto.string_from_key pub), (Crypto.string_from_key priv) in
    Config.write_file pubs Config.fname_PUBKEY rdir >>= fun () ->
    Config.write_file privs Config.fname_PRIVKEY rdir >>= fun () ->
    Async.return (pub,priv)


let load_peerkey rdir =
  print_endline "Looking for peer keys...";
  try
    Config.load_peerkey rdir >>= fun pk ->
    Deferred.return (Crypto.of_string pk)
  with exn ->
    let _ = failwith "Please update: "^(Config.fname_PEERS)^" to contain peer public key" in
    Deferred.return (Crypto.of_string "")


(* Initializes all servers and returns the ref of the current state. *)

let launch_synch rdir =
  load_keys rdir >>= fun (pub,priv) -> load_peerkey rdir >>= fun peerkey ->
  let _ = print_endline "Scanning directory..." in
  let st =
    print_endline "Looking for saved states...";
    try
      Config.load_state rdir
    with exn ->
      print_string "Could not find a saved state. Either no saved state or corrupt...\nEstablishing new state.\n";
      State.state_for_dir rdir
  in
  print_endline "State successfully loaded!";
  st >>= fun sinfo ->
  let _ = print_endline "Starting comm server" in
  let rstate = ref None in
  let currstate = ref sinfo in
  let discovered_peers : ((Crypto.key, disc_peer) Hashtbl.t) = Hashtbl.create 5 in
  comm_server (pub,priv) currstate rstate peerkey >>= fun _ ->
  print_endline "Starting discovery broadcaster";
  peer_broadcaster (bcastmsg_to_string ("Computer A", pub));
  print_endline "Starting discovery server";
  let _ = Peer_discovery.listen (peer_discovered discovered_peers) in
  let _ = peer_syncer discovered_peers peerkey currstate in
  Config.save_state sinfo rdir >>= fun _ -> Deferred.return (print_endline "Init complete!")


let exit_graceful = fun () -> upon (exit 0) (fun _ -> ())

(* Given an input string from the repl, handle the command *)
let process_input = function
| "about" -> print_endline "*****Version 1.0****"
| "quit" | "exit" -> print_endline "Exiting gracefully..."; exit_graceful ()
| "help" -> print_endline "Stuck? Type <quit> or <exit> at any point to exit gracefully."
|_ -> print_endline "Invalid Command!"

let rec loop () =
  print_string " >>> ";
  (Reader.stdin |> Lazy.force |> Reader.read_line |> upon)
    begin fun r ->
      match r with
      | `Ok s -> process_input s; loop ()
      | `Eof ->  print_endline "What happened"; exit_graceful ()
    end

let get_dir_path () =
  print_endline "Please type in the directory path you wish to sync.";
  (Reader.stdin |> Lazy.force |> Reader.read_line) >>= fun r ->
    match r with
    | `Ok s -> begin
      try let p = (Config.path_ok s) in Deferred.return p
      with exn -> print_endline "That is not a valid path!"; exit_graceful(); Deferred.return ("Oops")
    end
    | `Eof ->  exit_graceful(); Deferred.return("Oops")

(* Repl for filesyncing interface *)
let repl () =
  let _ = print_string "\n\nWelcome to Hump-Drive Version 1.0!\nMake sure you have configured everything correctly.\nConsult the report for configuration details if needed.\nType <start> to begin. Type <quit> or <exit> at any point to exit gracefully.\n\n";
  print_string " >>> " in
  (Reader.stdin |> Lazy.force |> Reader.read_line) >>= fun r ->
    match r with
    | `Ok s ->
      if s = "start" then
        (get_dir_path ()) >>= fun dpath ->
        (launch_synch dpath) >>= fun _ ->
        loop(); Deferred.return ()
      else Deferred.return (exit_graceful ())
    | `Eof -> Deferred.return (exit_graceful ())


let main () =
  let _ = repl () in
  Scheduler.go ()

let _ = main ()
