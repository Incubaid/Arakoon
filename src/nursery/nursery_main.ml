(*
This file is part of Arakoon, a distributed key-value store. Copyright
(C) 2010 Incubaid BVBA

Licensees holding a valid Incubaid license may use this file in
accordance with Incubaid's Arakoon commercial license agreement. For
more information on how to enter into this agreement, please contact
Incubaid (contact details can be found on www.arakoon.org/licensing).

Alternatively, this file may be redistributed and/or modified under
the terms of the GNU Affero General Public License version 3, as
published by the Free Software Foundation. Under this license, this
file is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.

See the GNU Affero General Public License for more details.
You should have received a copy of the
GNU Affero General Public License along with this program (file "COPYING").
If not, see <http://www.gnu.org/licenses/>.
*)


open Lwt
open Node_cfg
open Nursery
open Routing
open Interval

let with_admin (cluster:string) cfg f =
  let host,port = cfg in
  let sa = Network.make_address host port in
  let do_it connection =
    Remote_admin.make cluster connection 
    >>= fun (client) ->
    f client
  in
    Lwt_io.with_connection sa do_it

let find_master cluster_id cli_cfg =
  let check_node node_name node_cfg acc = 
    begin
      Lwt_log.info_f "node=%s" node_name >>= fun () ->
      let (ip,port) = node_cfg in
      let sa = Network.make_address ip port in
      Lwt.catch
        (fun () ->
          Lwt_io.with_connection sa
            (fun connection ->
              Arakoon_remote_client.make_remote_client cluster_id  connection
            >>= fun client ->
            client # who_master ())
            >>= function
              | None -> acc
              | Some m -> Lwt_log.info_f "master=%s" m >>= fun () ->
                Lwt.return (Some m) )
        (function 
          | Unix.Unix_error(Unix.ECONNREFUSED,_,_ ) -> 
            Lwt_log.info_f "node %s is down, trying others" node_name >>= fun () ->
            acc
          | exn -> Lwt.fail exn
        )
    end
  in 
  Hashtbl.fold check_node cli_cfg (Lwt.return None) >>= function 
    | None -> failwith "No master found"
    | Some m -> Lwt.return m  

let with_master_admin cluster_id cfg f =
  find_master cluster_id cfg >>= fun master_name ->
  let master_cfg = Hashtbl.find cfg master_name in
  with_admin cluster_id master_cfg f

let setup_logger file_name =
  Lwt_log.Section.set_level Lwt_log.Section.main Lwt_log.Debug;
  Lwt_log.file
    ~template:"$(date): $(level): $(message)"
    ~mode:`Append ~file_name () >>= fun file_logger ->
  Lwt_log.default := file_logger;
  Lwt.return ()
  
let get_keeper_config config =
  let inifile = new Inifiles.inifile config in
  let m_cfg = Node_cfg.get_nursery_cfg inifile config in
  begin 
    match m_cfg with
      | None -> failwith "No nursery keeper specified in config file"
      | Some (keeper_id, cli_cfg) -> 
        keeper_id, cli_cfg
  end

let get_nursery_client keeper_id cli_cfg =
  let get_nc client =
    client # get_nursery_cfg () >>= fun ncfg ->
    Lwt.return ( NC.make ncfg keeper_id )
  in
  with_master_admin keeper_id cli_cfg get_nc 


let __migrate_nursery_range config left sep right =
  Lwt_log.debug "=== STARTING MIGRATE ===" >>= fun () ->
  let keeper_id, cli_cfg = get_keeper_config config in
  get_nursery_client keeper_id cli_cfg >>= fun nc ->
  NC.migrate nc left sep right 
    
let __init_nursery config cluster_id = 
  Lwt_log.info "=== STARTING INIT ===" >>= fun () ->
  let (keeper_id, cli_cfg) = get_keeper_config config in
  let set_routing client =
    Lwt.catch( fun () ->
      client # get_routing () >>= fun cur ->
      failwith "Cannot initialize nursery. It's already initialized."
    ) ( function
      | Arakoon_exc.Exception( Arakoon_exc.E_NOT_FOUND, _ ) ->
         let r = Routing.build ( [], cluster_id ) in
         client # set_routing r 
      | e -> Lwt.fail e 
    ) 
  in
  with_master_admin keeper_id cli_cfg set_routing 
  

let __get_routing config = 
  let (keeper_id, cli_cfg) = get_keeper_config config in
  let get_routing client = 
    client # get_routing () >>= fun cur ->
    let cur_s = Routing.to_s cur in
    Lwt_io.printl cur_s
  in
  with_master_admin keeper_id cli_cfg get_routing
  
let __delete_from_nursery config cluster_id sep = 
  Lwt_log.info "=== STARTING DELETE ===" >>= fun () ->
  let m_sep =
  begin
    if sep = ""
    then None
    else Some sep
  end
  in
  let (keeper_id, cli_cfg) = get_keeper_config config in
  get_nursery_client keeper_id cli_cfg >>= fun nc ->
  NC.delete nc cluster_id m_sep 
  
let __main_run log_file f =
  let () = Client_log.enable_lwt_logging_for_client_lib_code () in
  Lwt.catch
  ( fun () ->
    setup_logger log_file >>= fun () ->
    f () 
    (* 
       >>= fun () ->
       File_system.unlink log_file  
    *)
  )
  ( fun e -> 
    let msg = Printexc.to_string e in 
    Lwt_log.fatal msg >>= fun () ->
    Lwt.fail e)

let get_interval cfg_name = 
  let client_cfg = Client_cfg.ClientCfg.from_file "global" cfg_name in
  with_master_admin "xxx" client_cfg 
    (fun admin -> 
      admin # get_interval () >>= fun interval ->
      Lwt_io.printl (Interval.to_string interval) >>= fun () ->
      Lwt.return ())  
    >>= fun () ->
  (*
  let cluster_cfg = Node_cfg.read_config cfg_name in
  let cluster_id = Node_cfg.cluster_id cluster_cfg in

  *)
  Lwt.return ()
    (*

    *)
    
let migrate_nursery_range config left sep right =
  __main_run "/tmp/nursery_migrate.log" ( fun() -> __migrate_nursery_range config left sep right )

let init_nursery config cluster_id =
  __main_run "/tmp/nursery_init.log" ( fun () -> __init_nursery config cluster_id )

let delete_nursery_cluster config cluster_id sep =
  __main_run "/tmp/nursery_delete.log" ( fun () -> __delete_from_nursery config cluster_id sep )
    
let get_routing config = 
  __main_run "/tmp/get_routing.log" (fun () -> __get_routing config)
