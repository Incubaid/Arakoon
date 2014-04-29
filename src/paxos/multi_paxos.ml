(*
Copyright (2010-2014) INCUBAID BVBA

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*)



open Mp_msg
open Lwt
open MPMessage
open Messaging
open Multi_paxos_type
open Master_type


let section =
  let s = Logger.Section.make "paxos" in
  let () = Logger.Section.set_level s Logger.Debug in
  s

let quorum_function = Quorum.quorum_function

exception ConflictException of (Value.t * Value.t list)
exception TooFewPromises of (float * int * string list)

exception PaxosFatal of string
(* timeout and to_receive, and who got through *)

let paxos_fatal me fmt =
  let k x =
    Logger.fatal_ (me^": "^x) >>= fun () ->
    Lwt.fail (PaxosFatal x)
  in
  Printf.ksprintf k fmt

let can_promise (type s) (module S : Store.STORE with type t = s) store lease_expiration requester =
  match S.who_master store with
    | Some (m, ml) ->
      if (
        ( (ml +. float lease_expiration) > (Unix.gettimeofday ()) )
        &&
        (String.compare requester m) <> 0
      )
      then false
      else true
    | None -> true

type ballot = int * string list (* still needed, & who voted *)

let network_of_messaging (m:messaging) =
  (* conversion since not all code is 'networked' *)
  let send msg source target =
    Logger.debug_f_ "%s: sending msg to %s: %s" source target (Mp_msg.MPMessage.string_of msg) >>= fun () ->
    let g = MPMessage.generic_of msg in
    m # send_message g ~source ?sub_target:None ~target
  in
  let register = m # register_receivers in
  let run () = m # run () in
  let is_alive id = m#expect_reachable ~target:id in
  send, run, register, is_alive


let update_votes (nones,somes) = function
  | None -> (nones+1, somes)
  | Some x ->
    let is_master_set = Value.is_master_set x in
    let rec build_new acc = function
      | [] -> (x,1)::acc
      | (a,fa) :: afs ->
        if a = x || (is_master_set && Value.is_master_set a)
        then ((a,fa+1) :: afs) @ acc
        else let acc' = (a,fa) :: acc  in build_new acc' afs
    in
    let tmp = build_new [] somes in
    let somes' = List.sort (fun (a,fa) (b,fb) -> fb - fa) tmp in
    (nones, somes')

type paxos_event =
  | FromClient of ((Update.Update.t) * (Store.update_result -> unit Lwt.t)) list
  | FromNode of (MPMessage.t * Messaging.id)
  | LeaseExpired of (float)
  | Quiesce of (Quiesce.Mode.t * Quiesce.Result.t Lwt.t * Quiesce.Result.t Lwt.u)
  | Unquiesce
  | ElectionTimeout of Sn.t * Sn.t
  | DropMaster of (unit Lwt.t * unit Lwt.u)

let paxos_event2s = function
  | FromClient _ -> "FromClient _"
  | FromNode _ -> "FromNode _ "
  | LeaseExpired _ -> "LeaseExpired _"
  | Quiesce (mode, _, _) -> Printf.sprintf "Quiesce (%s, _, _)" (Quiesce.Mode.to_string mode)
  | Unquiesce -> "Unquiesce _"
  | ElectionTimeout _ -> "ElectionTimeout _"
  | DropMaster _ -> "DropMaster _"

type 'a constants =
  {me:id;
   others: id list;
   send: MPMessage.t -> id -> id -> unit Lwt.t;
   get_value: Sn.t -> Value.t option;
   on_accept: Value.t * Sn.t * Sn.t -> unit Lwt.t;
   on_consensus:
     Value.t * Mp_msg.MPMessage.n * Mp_msg.MPMessage.n ->
     (Store.update_result list) Lwt.t;
   on_witness: id -> Sn.t -> unit;
   last_witnessed: id -> Sn.t;
   quorum_function: int -> int;
   master: master;
   store: 'a;
   store_module: (module Store.STORE with type t = 'a);
   tlog_coll:Tlogcollection.tlog_collection;
   other_cfgs:Node_cfg.Node_cfg.t list;
   lease_expiration: int;
   inject_event: paxos_event -> unit Lwt.t;
   is_alive: id -> bool;
   cluster_id : string;
   is_learner: bool;
   quiesced : bool;
   stop : bool ref;
   catchup_tls_ctx : [ `Client | `Server ] Typed_ssl.t option;
   mutable election_timeout : (Sn.t * Sn.t * float) option;
   mutable lease_expiration_id : int;
   mutable respect_run_master : (string * float) option;
   renew_lease : unit -> unit;
   drop_master : unit -> unit;
  }

let am_forced_master constants me =
  match constants.master with
    | Forced x -> x = me
    | _ -> false

let is_election constants =
  match constants.master with
    | Elected | Preferred _ -> true
    | ReadOnly | Forced _ -> false

let make (type s) ~catchup_tls_ctx me is_learner others send get_value
      on_accept on_consensus on_witness
      last_witnessed quorum_function (master:master) (module S : Store.STORE with type t = s) store tlog_coll
      other_cfgs lease_expiration inject_event is_alive ~cluster_id
      quiesced stop ~renew_lease ~drop_master =
  {
    me=me;
    is_learner;
    others;
    send;
    get_value;
    on_accept;
    on_consensus;
    on_witness;
    last_witnessed;
    quorum_function;
    master = master;
    store = store;
    store_module = (module S);
    tlog_coll;
    other_cfgs;
    lease_expiration;
    inject_event;
    is_alive;
    cluster_id;
    quiesced;
    stop;
    catchup_tls_ctx;
    election_timeout = None;
    lease_expiration_id = 0;
    respect_run_master = None;
    drop_master;
    renew_lease;
  }

let mcast constants msg =
  let send = constants.send in
  let me = constants.me in
  let others = constants.others in
  Lwt_list.iter_p (fun o -> send msg me o) others


let update_n constants n =
  let nodes = List.sort String.compare (constants.me :: constants.others) in
  let position =
    let rec inner p = function
      | hd :: tl ->
        if hd = constants.me
        then
          p
        else
          inner (p+1) tl
      | [] -> failwith "couldn't find node in node list" in
    inner 0 nodes in
  let nnodes = Sn.of_int (List.length nodes) in
  let strictly_positive a =
    if (Sn.compare a 0L) <= 0
    then
      Sn.add a nnodes
    else
      a in
  Sn.add n (strictly_positive (Sn.sub (Sn.of_int position) (Sn.rem n nnodes)))

let push_value constants v n i =
  constants.on_accept (v,n,i) >>= fun () ->
  let msg = Accept(n,i,v) in
  mcast constants msg


let start_lease_expiration_thread (type s) ?(immediate_lease_expiration=false) constants =
  let module S = (val constants.store_module : Store.STORE with type t = s) in
  constants.lease_expiration_id <- constants.lease_expiration_id + 1;
  let id = constants.lease_expiration_id in
  let rec inner () =
    let lease_start, slave = match S.who_master constants.store with
      | None -> 0.0, true
      | Some(m, ls) -> ls, constants.me <> m in
    let lease_expiration = float_of_int constants.lease_expiration in
    let factor =
      if slave
      then
        (* sleep a little longer than necessary on a slave
           to prevent a node thinking it's still the master
           while some slaves have elected a new master amongst them
           (in case the clocks don't all run at the same speed) *)
        1.1
      else
        0.5 in
    let sleep_sec =
      let now = Unix.gettimeofday () in
      if lease_start +. lease_expiration < now
      then
        lease_expiration *. factor
      else
        (lease_expiration -. (now -. lease_start)) *. factor in
    let t () =
      begin
        Logger.debug_f_ "%s: waiting %2.1f seconds for lease to expire"
          constants.me sleep_sec >>= fun () ->
        let t0 = Unix.gettimeofday () in
        Lwt_unix.sleep sleep_sec >>= fun () ->
        if id = constants.lease_expiration_id
        then
          begin
            let t1 = Unix.gettimeofday () in
            Logger.debug_f_ "%s: lease expired (%2.1f passed, %2.1f intended)=> injecting LeaseExpired event for %f"
              constants.me (t1 -. t0) sleep_sec lease_start >>= fun () ->
            constants.inject_event (LeaseExpired (lease_start)) >>= fun () ->
            inner ()
          end
        else
          Lwt.return ()
      end in
    if immediate_lease_expiration
    then
      begin
        Logger.ign_debug_f_ "start_lease_expiration_thread, taking immediate path";
        Lwt.ignore_result (constants.inject_event (LeaseExpired (lease_start)))
      end;
    let () = Lwt.ignore_result (t ()) in
    Lwt.return () in
  inner ()

let start_election_timeout ?(from_master=false) constants n i =
  let sleep_sec =
    if from_master
    then
      float_of_int (constants.lease_expiration) /. 4.0
    else
      float_of_int (constants.lease_expiration) /. 2.0 in
  let () = match constants.election_timeout with
    | None ->
      begin
        let rec t sleep_sec =
          Logger.debug_f_ "%s: waiting %2.1f seconds for timeout" constants.me sleep_sec >>= fun () ->
          let t0 = Unix.gettimeofday () in
          Lwt_unix.sleep sleep_sec >>= fun () ->
          let t1 = Unix.gettimeofday () in
          Logger.debug_f_ "%s: timeout (n=%s) should have finished by now (%2.1f passed, intended %2.1f)." constants.me (Sn.string_of n) (t1 -. t0) sleep_sec >>= fun () ->
          match constants.election_timeout with
            | None -> Logger.warning_f_ "%s: scheduled election timeout thread but no timeout configured!" constants.me
            | Some (n', i', until) ->
              if t1 < until
              then
                t (until -. t1)
              else
                begin
                  constants.election_timeout <- None;
                  constants.inject_event (ElectionTimeout (n', i'))
                end
        in
        Lwt.ignore_result (t sleep_sec)
      end
    | Some _ -> () in
  constants.election_timeout <- Some (n, i, Unix.gettimeofday () +. sleep_sec);
  Lwt.return ()

type prepare_repsonse =
  | Prepare_dropped
  | Promise_sent_up2date
  | Promise_sent_needs_catchup
  | Nak_sent

let handle_prepare (type s) constants dest n n' i' =
  let module S = (val constants.store_module : Store.STORE with type t = s) in
  let me = constants.me in
  let () = constants.on_witness dest i' in
  if not ( List.mem dest constants.others) then
    begin
      let store = constants.store in
      let s_i = S.consensus_i store in
      let nak_i =
        begin
          match s_i with
            | None -> Sn.start
            | Some si -> Sn.succ si
        end in
      let reply = Nak( n',(n,nak_i)) in
      Logger.debug_f_ "%s: replying with %S to learner %s" me (string_of reply) dest
      >>= fun () ->
      constants.send reply me dest >>= fun () ->
      Lwt.return Nak_sent
    end
  else
    begin
      let store = constants.store in
      let s_i = S.consensus_i store in
      let nak_max =
        begin
          match s_i with
          | None -> Sn.start
          | Some si -> Sn.succ si
        end
      in

      if ( n' > n && i' < nak_max && nak_max <> Sn.start ) || n' <= n
      then
        (* Send Nak, other node is behind *)
        let reply = Nak( n',(n,nak_max)) in
        Logger.debug_f_ "%s: NAK:other node is behind: i':%s nak_max:%s" me
                        (Sn.string_of i') (Sn.string_of nak_max) >>= fun () ->
        Lwt.return (Nak_sent, Some reply)
      else
        begin
          (* Ok, we can make a Promise to the other node, if we want to *)
          let maybe_promise () =
            let can_pr = can_promise constants.store_module constants.store constants.lease_expiration dest in
            if not can_pr && n' >= 0L
            then
              begin
                Logger.debug_f_ "%s: handle_prepare: Dropping prepare - lease still active" me
                >>= fun () ->
                Lwt.return (Prepare_dropped, None)
              end
            else
              begin
                constants.respect_run_master <- Some (dest, Unix.gettimeofday () +. (float constants.lease_expiration) /. 4.0);
                let lv = constants.get_value nak_max in
                let reply = Promise(n',nak_max,lv) in
                Logger.debug_f_ "%s: handle_prepare: starting election timer" me >>= fun () ->
                start_election_timeout constants n' i' >>= fun () ->
                if i' > nak_max
                then
                  (* Send Promise, but I need catchup *)
                  Lwt.return(Promise_sent_needs_catchup, Some reply)
                else (* i' = i *)
                  (* Send Promise, we are in sync *)
                  Lwt.return(Promise_sent_up2date, Some reply)
              end in
          match constants.respect_run_master with
          | None ->
             maybe_promise ()
          | Some (other, until) ->
             let now = Unix.gettimeofday () in
             if until < now || dest = other
             then
               begin
                 (* handle the prepare by making a promise *)
                 (* old respect_run_master info
                           (which we can safely ignore, it will be overwritten in make_promise)
                         or a prepare from the same node again
                           (this ensures no prepares from the same node queue up here) *)
                 maybe_promise ()
               end
             else
               begin
                 (* drop the prepare to give the other node that is running
                         for master some time to do it's thing
                  *)
                 Logger.debug_f_ "%s: handle_prepare: dropping prepare to respect another potential master" me >>= fun () ->
                 Lwt.return (Prepare_dropped, None)
               end
        end
    end >>= fun (ret_val, reply) ->
    match reply with
    | None -> Lwt.return ret_val
    | Some reply ->
       Logger.debug_f_ "%s: handle_prepare replying with %S" me (string_of reply) >>= fun () ->
       constants.send reply me dest >>= fun () ->
       Lwt.return ret_val

let safe_wakeup sleeper awake value =
  Lwt.catch
    ( fun () -> Lwt.return (Lwt.wakeup awake value) )
    ( fun e ->
       match e with
         | Invalid_argument s ->
           let t = state sleeper in
           begin
             match t with
               | Fail ex -> Lwt.fail ex
               | Return v -> Lwt.return ()
               | Sleep -> Lwt.fail (Failure "Wakeup error, sleeper is still sleeping")
           end
         | _ -> Lwt.fail e
    )

let safe_wakeup_all v l =
  Lwt_list.iter_s
    (fun (s, a) -> safe_wakeup s a v)
    l

let fail_quiesce_request store sleeper awake reason =
  safe_wakeup sleeper awake reason

let handle_quiesce_request (type s) (module S : Store.STORE with type t = s) store mode sleeper (awake: Quiesce.Result.t Lwt.u) =
  S.quiesce mode store >>= fun () ->
  safe_wakeup sleeper awake Quiesce.Result.OK

let handle_unquiesce_request (type s) constants n =
  let store = constants.store in
  let tlog_coll = constants.tlog_coll in
  let module S = (val constants.store_module : Store.STORE with type t = s) in
  let too_far_i = S.get_succ_store_i store in
  S.unquiesce store >>= fun () ->
  Catchup.catchup_store ~stop:constants.stop "handle_unquiesce" ((module S),store,tlog_coll) too_far_i >>= fun () ->
  let i = S.get_succ_store_i store in
  let vo = tlog_coll # get_last_value i in
  start_lease_expiration_thread constants >>= fun () ->
  Lwt.return (i,vo)
