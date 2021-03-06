open Unix
module OUnix = Unix
open Async

(* Module used to maintain our files_to_info and update_queue structures *)
(* module StringSet = Set.Make(String) *)
module FileMap = Map.Make(String)

type dir_path = string
type file_hash = int
(* type update_queue = StringSet.t *)
type last_modified = float

(* Maps file names to file meta data of the files currently tracked *)
type files_to_info = (file_hash * last_modified) FileMap.t

(* [compute_hash s] is the hash calculated for a string [s] *)
let compute_hash s =
  let hash = ref 0 in
  let update_hash c =
    let h = !hash in
    let h' = ((h lsl 5) - h) + (Char.code c) in
    hash := h' land h'
  in String.iter (update_hash) s; !hash

(* Record representing internal state of the system *)
type state_info = {dir_path : dir_path;
                   files_to_info : files_to_info;
                   last_modified : last_modified;}


(* Directory that contains this file *)
let root_dir s =
  s.dir_path

(* [get_dir_contents acc h] returns a list of contents contained in
 * the directory specified by [h] *)
let rec get_dir_contents acc h =
  Async.Unix.readdir_opt h >>= (fun s ->
    match s with
    | Some s -> get_dir_contents (s::acc) h
    | None -> Async.Unix.closedir h >>= (fun () -> Deferred.return (acc))
  )

(* Opens the file denoted by [fpath] and hashes its contents *)
let hash_file fpath =
  Reader.open_file fpath >>= (fun rdr ->
    Reader.pipe rdr |> Async_unix.Import.Pipe.read >>=
    (fun x ->
      match x with
        | `Ok s -> Deferred.return (compute_hash s)
        | `Eof -> Deferred.return (compute_hash "")
    )
  )

(* Returns whether the file denoted by [fpath] is a regular file *)
let is_reg_file fpath =
  try
    let fdesc = OUnix.openfile fpath [O_RDONLY; O_NONBLOCK] 644 in
    let stats = OUnix.fstat fdesc in
    stats.st_kind = S_REG
  with _ -> false

(* Returns the last modified time of the file denoted by [path] *)
let last_modtime path =
  let fdesc = OUnix.openfile path [O_RDONLY; O_NONBLOCK] 644 in
  let stats = OUnix.fstat fdesc in
  stats.st_mtime

(* Gets a list of only the regular files in the directory [dir_path], that
 * is a list that ignores directories within this directory *)
let files_in_dir dir_path =
  let handle = OUnix.opendir dir_path in
  get_dir_contents [] handle >>= fun lst ->
  Deferred.return (List.filter (fun f -> is_reg_file (dir_path^Filename.dir_sep^f)) lst)

(* Given a path to a directory returns a [state] record
 * representing its current status at this time *)
let state_for_dir dir_path =
  (files_in_dir dir_path) >>=
  fun filenames ->
    let filehashed' = List.map (fun fil -> hash_file (dir_path^Filename.dir_sep^fil)) filenames in
    let unwrap_and_cons = fun acc i -> i >>= fun e -> acc >>= fun lst -> Deferred.return (e::lst) in
    List.fold_left unwrap_and_cons (Deferred.return []) filehashed' >>=
      fun filehashes ->
        let filemodtimes = List.map (fun fil -> last_modtime
                          (dir_path^Filename.dir_sep^fil)) filenames in
        let file_info = List.map2 (fun a b -> (a,b)) filehashes filemodtimes in
        let file_mappings = List.fold_left2 (fun acc fname finfo -> FileMap.add fname finfo acc)
          FileMap.empty filenames file_info in
        let time = last_modtime dir_path in
        Deferred.return
        {dir_path = dir_path;
         files_to_info = file_mappings;
         last_modified = time;}

(* Updates a filemap and queue given current file info  *)
let changed_files dir_path acc (fname, modtime) =
  acc >>= fun (file_map) ->
  try
    let _, stored_modtime = FileMap.find fname file_map in
    if modtime <> stored_modtime then
      hash_file (dir_path^Filename.dir_sep^fname) >>= fun new_hash ->
      Deferred.return (FileMap.add fname (new_hash, modtime) file_map)
    else Deferred.return (file_map)
  with Not_found ->
    hash_file (dir_path^Filename.dir_sep^fname) >>=
    fun new_hash -> Deferred.return
    (FileMap.add fname (new_hash, modtime) file_map)

(* Given a st, returns an updated filebinding and queue. Helper for update_state  *)
let update_file_info st =
  let dir_path = st.dir_path in
  let file_binds = st.files_to_info in
  files_in_dir dir_path >>= fun curr_dir_contents ->
    let fnames_to_modtimes = List.map (fun fil ->
        (fil, last_modtime (dir_path^Filename.dir_sep^fil))) curr_dir_contents in
  List.fold_left (fun acc x -> changed_files dir_path acc x)
        (Deferred.return file_binds) fnames_to_modtimes

(* Given a st update it by looking at the current directory *)
let update_state st =
  let dir_path = st.dir_path in
  let new_modtime = last_modtime dir_path in
  if new_modtime <> st.last_modified then
    update_file_info st >>= fun binds -> Deferred.return
      {st with files_to_info = binds; last_modified = new_modtime}
  else Deferred.return st

(* Looks up a [file] in [st]'s files_to_info *)
let lookup_file file st = FileMap.find file st.files_to_info

(* Compares two versions of the same file [f] in [st1] and [st2]. Returns true if
 * the version of [st2] is newer than that of [st1 ]*)
let cmp_file_versions st1 st2 f =
  let h1,t1 = lookup_file f st1 in
  let h2,t2 = lookup_file f st2 in
  (t2 > t1) && (h2 <> h1)

(* Determines which files to request from another device by comparing
 * the hashes of files in this directory with the expected hashes*)
let files_to_request st_curr st_inc =
  let curr_binds = st_curr.files_to_info in
  let inc_binds = st_inc.files_to_info in
  FileMap.fold (fun k _ acc ->
      if not (FileMap.mem k curr_binds) then k::acc
      else if (cmp_file_versions st_curr st_inc k)
      then k::acc else acc) inc_binds []

(* When a file is transfered to this device externally from another
 * device use this function to given an ack of it*)
let acknowledge_file_recpt st fname =
  let fpath = st.dir_path ^ Filename.dir_sep ^ fname in
  let modtime = last_modtime fpath in
  hash_file fpath >>= fun hash ->
    let filemap = FileMap.add fname (hash, modtime) (st.files_to_info) in
    let dir_lastmodtime = last_modtime st.dir_path in
    Deferred.return {st with
                    files_to_info = filemap;
                    last_modified = dir_lastmodtime}

let to_string (st : state_info) = Marshal.to_string st [] |> String.escaped

let from_string (s : string) : state_info = Marshal.from_string (Scanf.unescaped s) 0

