open Lwt
open Routing
open Node_cfg.Node_cfg
open Interval

module S = (val (Store.make_store_module (module Batched_store.Local_store)))

let try_fetch name (f:unit -> 'a Lwt.t) (r2s: 'a -> string)  =
  Lwt.catch
    (fun () ->
       f () >>= fun r ->
       let s = r2s r in
       Lwt_io.printlf "%s: %s" name s
    )
    (function
      | Not_found -> Lwt_io.printlf "%s : --" name
      | e ->         Lwt_io.printlf "%s : %s" name (Printexc.to_string e)
    )


let _dump_routing store =  try_fetch "routing" (fun () -> S.get_routing store) Routing.to_s

let _dump_interval store = try_fetch "interval" (fun () -> S.get_interval store) Interval.to_string

let summary store =
  let consensus_i = S.consensus_i store
  and mdo = S.who_master store
  in
  Lwt_io.printlf "i: %s" (Log_extra.option2s Sn.string_of consensus_i) >>= fun () ->
  let s =
    match mdo with
      | None -> "None"
      | Some (m,e) -> Printf.sprintf "Some(%s,%f)" m e
  in
  Lwt_io.printlf "master: %s" s
  >>= fun () ->
  _dump_routing store >>= fun () ->
  _dump_interval store

let dump_store filename =
  let t () =
    S.make_store ~lcnum:1024 ~ncnum:512 filename >>= fun store ->
    summary store >>= fun () ->
    S.close store
  in
  Lwt_main.run (t());
  0

exception ExitWithCode of int;;

let inject_as_head fn node_id cfg_fn force =
  let canonical =
    if cfg_fn.[0] = '/'
    then cfg_fn
    else Filename.concat (Unix.getcwd()) cfg_fn
  in
  let cluster_cfg = read_config canonical in
  let node_cfgs = List.filter
                    (fun ncfg -> node_name ncfg = node_id)
                    cluster_cfg.cfgs
  in
  let node_cfg = match node_cfgs with
    | [] -> failwith (Printf.sprintf "unknown node: %S" node_id)
    | x :: _ -> x
  in
  let t () =
    let tlog_dir = node_cfg.tlog_dir in
    let tlf_dir = node_cfg.tlf_dir in
    let head_dir = node_cfg.head_dir in
    let old_head_name = Filename.concat head_dir Tlc2.head_fname  in

    let read_i head_name =
      S.make_store ~lcnum:1024 ~ncnum:512 head_name >>= fun head ->
      let head_i = S.consensus_i head in
      S.close head >>= fun () ->
      Lwt.return head_i in

    (Lwt.catch
       (fun () -> read_i old_head_name)
       (fun exn ->
          if force
          then
            Lwt.return None
          else
            begin
              Lwt_io.printl (Printexc.to_string exn) >>= fun () ->
              Lwt.fail (ExitWithCode 3)
            end)) >>= fun old_head_i ->
    (Lwt.catch
       (fun () -> read_i fn)
       (fun exn ->
          Lwt_io.printl (Printexc.to_string exn) >>= fun () ->
          Lwt.fail (ExitWithCode 4))) >>= fun new_head_i ->

    Lwt_io.printlf "# %s @ %s" old_head_name (Log_extra.option2s Sn.string_of old_head_i) >>= fun () ->
    Lwt_io.printlf "# %s @ %s" fn (Log_extra.option2s Sn.string_of new_head_i) >>= fun () ->


    let ok = match old_head_i, new_head_i with
      | None,None -> false
      | Some oi, None -> false
      | None, Some ni -> true
      | Some oi, Some ni -> ni > oi
    in
    Lwt_io.printlf "# head is newer">>= fun () ->
    if not ok then failwith "new head is not an improvement";
    let bottom_n = match new_head_i with
      | None -> failwith "can't happen"
      | Some i -> Sn.to_int (Tlc2.get_file_number i)
    in
    Lwt_io.printf "cp %S %S" fn old_head_name >>=fun () ->
    File_system.copy_file fn old_head_name true >>= fun () ->
    Lwt_io.printlf "# [OK]">>= fun () ->
    Lwt_io.printlf "# remove superfluous .tlf files" >>= fun () ->
    Tlc2.get_tlog_names tlog_dir tlf_dir >>= fun tlns ->
    let old_tlns = List.filter (fun tln -> let n = Tlc2.get_number tln in n < bottom_n) tlns in
    Lwt_list.iter_s
      (fun old_tln ->
         let canonical = Tlc2.get_full_path tlog_dir tlf_dir old_tln in
         Lwt_io.printlf "rm %s" canonical >>= fun () ->
         File_system.unlink canonical
      ) old_tlns >>= fun () ->
    Lwt_io.printlf "# [OK]" >>= fun () ->
    Lwt.return 0

  in
  try
    Lwt_main.run (t ())
  with
    | ExitWithCode i -> i
    | exn -> raise exn
