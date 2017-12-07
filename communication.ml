open Async
open Async_extra.Tcp
open Async_extra.Import.Reader
open Async_extra.Import.Writer
open Crypto


let pu = Crypto.key_from_string "371231380513840174425645412377223429621325167085653107566134660546088480210237155858539524043527005322034361505765820564154683030558303344226815372571949747793522185924674417872780071492929729165727870590934771223134363607914632879286523420851703728462705568934768942031062709035994744032500160448359337994020732662070606000346629729130536739490941894427609496909410526964662159120133362021593735851"
let pr = Crypto.key_from_string "9499797956224051813010422366384444205472597967599260452101133929924446975107426183598141074532212097605489756758113451373599490276191190211067292650467286484856886681775881130162455448352098352597201"



type message = State of string | Filerequest of string

(* ip, key *)
type peer = { ip:string; key:Crypto.key;} (* Todo make crypto key *)

type server = (Socket.Address.Inet.t, int) Async_extra.Tcp.Server.t

type conn_state = Socket.Address.Inet.t*Reader.t*Writer.t


let port = 13347


let cmp_sub s cmd =
  try (
    let ss = String.sub s 0 (String.length cmd) in
    ss = cmd
  ) with
  _ -> false


let msg_to_string = function
  | State s -> "state:"^s^"\n"
  | Filerequest s -> "freq:"^s^"\n"

(*)
let transfer_file fname (addr,read,write) =
  Reader.open_file fname >>= fun fd ->
  Writer.transfer write (Reader.pipe fd)
    (fun s -> Writer.write write s) >>= fun () ->
  Writer.flushed write >>= fun () ->
  print_string "Finished Transferring!";
  Reader.close fd   *)


let transfer_file fname (addr,read,write) =
  Reader.open_file fname >>= fun r ->
    let buf = Core.String.create Crypto.chunk_size in
    let rec rp () = Reader.really_read r ~pos:(0) ~len:(Crypto.chunk_size) buf >>= fun res -> (*TODO crypto input chunk size*)
      print_endline buf;
    match res with
    | `Ok -> Writer.write write (Crypto.encrypt_and_chunk buf pu); rp ()
    | `Eof 0-> Writer.flushed write
    | `Eof n -> Writer.write write (Crypto.encrypt_and_chunk (String.sub buf 0 (n-1)) pu); Writer.flushed write
    in
    rp () >>= fun () -> print_endline "Finished Transferring!"; Reader.close r


(*
let recv_file fdest (addr,read,write) =
  Writer.open_file fdest >>= fun fd ->
  Reader.transfer read (Writer.pipe fd) >>= fun () ->
  print_string "Finished receiving!";
  Writer.close fd *)


let recv_file fdest (addr,read,write) =
  Writer.open_file fdest >>= fun fw ->
  let buf = Core.String.create Crypto.output_chunk_size in
  let rec rp () =  Reader.really_read read ~pos:(0) ~len:(Crypto.output_chunk_size) buf >>= fun res -> (*TODO crypto output chunk size*)
    print_endline buf;
  match res with
  | `Ok -> Writer.write fw (Crypto.decrypt_chunked buf pu pr); rp ()
  | `Eof 0-> Writer.flushed fw
  | `Eof n -> failwith ("Wrong length read: "^(string_of_int n))
  in
  rp () >>= fun () -> print_endline "Finished receiving!"; Writer.close fw


let process_cmd s cstate pr (hookup : (conn_state -> peer -> message -> unit Async.Deferred.t)) =
  let scmp = cmp_sub s in
  let slen = String.length s in
  if (scmp "state:") then
    let ssl = String.length "state:" in
    let cmd = String.sub s ssl (slen-ssl) in
    hookup cstate pr (State cmd)
  else if (scmp "freq:") then
    let ssl = String.length "freq:" in
    let cmd = String.sub s ssl (slen-ssl) in
    hookup cstate pr (Filerequest cmd)
  else
    Deferred.return ()


let start_server hookup =
  let server_callback addr read write =
    let (cs:conn_state) = (addr,read,write) in
    print_string "Got Client!";
    let saddr = Socket.Address.Inet.addr addr |> Unix.Inet_addr.to_string in
    saddr |> print_string;
    read_until read (`Char '\n') ~keep_delim:(false) >>= fun r ->
    match (r) with
    | `Ok s ->
      let pr = {ip=saddr; key=(Crypto.key_from_string s)} in
      process_cmd s cs pr hookup >>= fun () ->
      Writer.close write
    | `Eof_without_delim s ->
      print_endline ("Invalid command: "^s);
      Writer.close write
    | `Eof ->
      print_string "Closed connection!";
      Writer.close write
  in
  Server.create (on_port port) server_callback



let stop_server (s:server) =
  failwith "TODO"



let send_message peer msg =
  let thp : Async_extra.Import.Socket.Address.Inet.t where_to_connect = to_host_and_port peer.ip port in
  Tcp.connect thp >>= fun (sock, read, write) ->
  let cstate : conn_state = (Async_extra.Import.Socket.getpeername sock, read, write) in
  print_endline "Connected to server to send notification!";
  let smesg = msg_to_string msg in
  Writer.write write smesg;
  Writer.flushed write >>= fun () ->
  Deferred.return cstate



let request_file peer fname fdest =
  send_message peer (Filerequest fname) >>= fun cstate ->
  recv_file fdest cstate >>= fun () ->
  let (_, _, write) = cstate in
  Writer.close write



let send_state peer state =
  print_string ("send_state: "^peer.ip);
  send_message peer (State state) >>= fun (addr, read, write) ->
  Writer.close write
