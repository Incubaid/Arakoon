open Update
open Routing
open Interval
open Client_cfg
open Ncfg

class type nodestream = object
  method iterate:
    Sn.t -> (Sn.t * Value.t -> unit Lwt.t) ->
    Tlogcollection.tlog_collection ->
    head_saved_cb:(string -> unit Lwt.t) -> unit Lwt.t

  method collapse: int -> unit Lwt.t

  method set_routing: Routing.t -> unit Lwt.t
  method set_routing_delta: string -> string -> string -> unit Lwt.t
  method get_routing: unit -> Routing.t Lwt.t

  method optimize_db: unit -> unit Lwt.t
  method defrag_db:unit -> unit Lwt.t
  method get_db: string -> unit Lwt.t

  method get_fringe: string option -> Routing.range_direction -> ((string * string) list) Lwt.t
  method set_interval : Interval.t -> unit Lwt.t
  method get_interval : unit -> Interval.t Lwt.t

  method store_cluster_cfg: string -> ClientCfg.t -> unit Lwt.t

  method get_nursery_cfg: unit -> NCFG.t Lwt.t

  method drop_master: unit -> unit Lwt.t

end

val make_remote_nodestream :
  string -> Lwt_io.input_channel * Lwt_io.output_channel -> nodestream Lwt.t
