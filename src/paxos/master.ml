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

open Multi_paxos_type
open Multi_paxos
open Lwt
open Mp_msg.MPMessage
open Update

(* a (possibly potential) master has found consensus on a value
   first potentially finish of a client request and then on to
   being a stable master *)
let master_consensus constants {mo;v;n;i;lew} () =
  let con_e = EConsensus(mo, v,n,i) in
  let log_e = ELog (fun () ->
    Printf.sprintf "on_consensus for : %s => %i finished_fs (in master_consensus)"
      (Value.value2s v)
      (match mo with
       | None -> 0
       | Some mo -> List.length mo))
  in
  let inject_e = EGen (fun () ->
    match v with
    | Value.Vm _ ->
      let event = Multi_paxos.FromClient [(Update.Nop, fun _ -> Lwt.return ())] in
      Lwt.ignore_result (constants.inject_event event);
      Lwt.return ()
    | _ -> Lwt.return ()
  )
  in
  if Value.is_other_master_set constants.me v
  then
    (* step down *)
    Multi_paxos.safe_wakeup_all () lew >>= fun () ->
    let sides = [con_e;log_e;ELog (fun () -> "Stepping down to slave state")] in
    Fsm.return ~sides (Slave_wait_for_accept (n, Sn.succ i, None))
  else
    let state = (v,n,(Sn.succ i), lew) in
    Fsm.return ~sides:[con_e;log_e;inject_e] (Stable_master state)


let null = function
  | [] -> true
  | _ -> false

let stable_master (type s) constants ((v',n,new_i, lease_expire_waiters) as current_state) ev =
  match ev with
  | LeaseExpired n' ->
      let me = constants.me in
      if n' < n
      then
        begin
          let log_e =
            ELog (fun () ->
                  Printf.sprintf "stable_master: ignoring old lease_expired with n:%s < n:%s"
                                 (Sn.string_of n') (Sn.string_of n))
          in
          Fsm.return ~sides:[log_e] (Stable_master current_state)
        end
      else
        begin
          let extend ls =
            if not (null lease_expire_waiters)
            then
              begin

                if (Unix.gettimeofday () -. ls) > 2.2 *. (float constants.lease_expiration)
                then
                  begin
                    (* nobody is taking over, go to elections *)
                    Multi_paxos.safe_wakeup_all () lease_expire_waiters >>= fun () ->
                    let log_e =
                      ELog (fun () ->
                            "stable_master: half-lease_expired while doing drop-master but nobody taking over, go to election")
                    in
                    let new_n = update_n constants n in
                    Fsm.return ~sides:[log_e] (Election_suggest (new_n, new_i, None))
                  end
                else
                  let log_e = ELog (fun () ->
                                    "stable_master: half-lease_expired, but not renewing lease")
                  in
                  (* TODO Is this correct, to initiate handover? *)
                  Fsm.return ~sides:[log_e] (Stable_master current_state)
              end
            else (* if lease_expire_waiter is empty *)
              let log_e = ELog (fun () -> "stable_master: half-lease_expired: update lease." ) in
              let v = Value.create_master_value me in
              (* TODO: we need election timeout as well here *)
              let ms = {mo = None;
                        v;n;i = new_i;
                        lew = [];
                       }
              in
              Fsm.return ~sides:[log_e] (Master_dictate ms)
          in
          let maybe_extend () =
            let module S = (val constants.store_module : Store.STORE with type t = s) in
            match S.who_master constants.store with
            | None ->
               extend 0.0
            | Some(_, ls) ->
               extend ls in
          maybe_extend ()
        end
    | FromClient ufs ->
        begin
          let updates, finished_funs = List.split ufs in
          let synced = List.fold_left (fun acc u -> acc || Update.is_synced u) false updates in
          let value = Value.create_client_value updates synced in
          let ms = {mo = Some finished_funs;
                    v = value;
                    n;i = new_i;
                    lew = lease_expire_waiters
                   }
          in
          Fsm.return (Master_dictate ms)
        end
    | FromNode (msg,source) ->
      begin
	    let me = constants.me in
	    match msg with
	      | Prepare (n',i') ->
	        begin
              if am_forced_master constants me
	          then
		        begin
		          let reply = Nak(n', (n,new_i)) in
		          constants.send reply me source >>= fun () ->
		          if n' > 0L
		          then
		            let new_n = update_n constants n' in
		            Fsm.return (Forced_master_suggest (new_n,new_i))
		          else
		            Fsm.return (Stable_master current_state )
		        end
	          else
		        begin
                  let module S = (val constants.store_module : Store.STORE with type t = s) in
		          handle_prepare constants source n n' i' >>= function
		            | Nak_sent
		            | Prepare_dropped -> Fsm.return  (Stable_master current_state )
		            | Promise_sent_up2date ->
		              begin
                        let l_val = constants.tlog_coll # get_last () in
                        Multi_paxos.safe_wakeup_all () lease_expire_waiters >>= fun () ->
			            Fsm.return (Slave_wait_for_accept (n', new_i, l_val))
		              end
		            | Promise_sent_needs_catchup ->
                      let i = S.get_catchup_start_i constants.store in
                      Multi_paxos.safe_wakeup_all () lease_expire_waiters >>= fun () ->
                      Fsm.return (Slave_discovered_other_master (source, i, n', i'))
		        end
	        end
          | Accepted(_n,i) ->
              (* This one is not relevant anymore, but we're interested
                 to see the slower slaves in the statistics as well :
                 TODO: should not be solved on this level.
              *)
              let () = constants.on_witness source i in
              Fsm.return (Stable_master current_state)
          | Accept(n',i',_v) when n' > n && i' > new_i ->
            (*
               somehow the others decided upon a master and I got no event my lease expired.
               Let's see what's going on, and maybe go back to elections
            *)
            begin
              Multi_paxos.safe_wakeup_all () lease_expire_waiters >>= fun () ->
              let run_elections, why = Slave.time_for_elections constants in
              let log_e =
                ELog (fun () ->
                  Printf.sprintf "XXXXX received Accept(n:%s,i:%s) time for elections? %b %s"
                    (Sn.string_of n') (Sn.string_of i')
                    run_elections why)
              in
              let sides = [log_e] in
              if run_elections
              then
                Fsm.return ~sides (Election_suggest (n,new_i,Some v'))
              else
                Fsm.return ~sides (Stable_master (v',n,new_i, []))
            end
	      | _ ->
	          begin
                let log_e = ELog (fun () ->
                  Printf.sprintf "stable_master received %S: dropping" (string_of msg))
                in
	            Fsm.return ~sides:[log_e] (Stable_master current_state)
	          end
      end
    | ElectionTimeout n' ->
        begin
          let log_e = ELog (fun () ->
            Printf.sprintf "ignoring election timeout (%s)" (Sn.string_of n') )
          in
          Fsm.return ~sides:[log_e] (Stable_master current_state)
      end
    | Quiesce (_, sleep,awake) ->
      begin
        fail_quiesce_request constants.store sleep awake Quiesce.Result.FailMaster >>= fun () ->
        Fsm.return (Stable_master current_state)
      end

    | Unquiesce -> Lwt.fail (Failure "Unexpected unquiesce request while running as")

    | DropMaster (sleep, awake) ->
        let state' = (v',n,new_i, (sleep, awake) :: lease_expire_waiters) in
        Fsm.return (Stable_master state')

(* a master informes the others of a new value by means of Accept
   messages and then waits for Accepted responses *)

let master_dictate constants ({mo;v;n;i;lew} as ms) () =
  let ()= ignore mo in
  let accept_e = EAccept (v,n,i) in
  let start_e = EStartLeaseExpiration (v,n,false) in
  let mcast_e = EMCast (Accept(n,i,v)) in
  let me = constants.me in
  let others = constants.others in
  let needed = constants.quorum_function (List.length others + 1) in
  let needed' = needed - 1 in
  let mballot = (needed' , [me] ) in

  let log_e =
    ELog (fun () ->
      Printf.sprintf "master_dictate n:%s i:%s needed:%d"
        (Sn.string_of n) (Sn.string_of i) needed'
    )
  in
  let sides =
    if null lew
    then
      [mcast_e;
       accept_e;
       start_e;
       log_e;
      ]
    else
      [mcast_e;
       accept_e;
       log_e;
      ]
  in
  Fsm.return ~sides (Accepteds_check_done (ms,mballot))
