(*
This file is part of Arakoon, a distributed key-value store. Copyright
(C) 2010-2014 Incubaid BVBA

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


type finished_fun = Store.update_result -> unit Lwt.t
type master_option = (finished_fun list) option

type v_limits = int * (Value.t * int) list
(* number of times None was chosen;
   all Some v promises and their frequency *)
type n = Sn.t
type i = Sn.t
type slave_awaiters = (unit Lwt.t * unit Lwt.u) list

type mballot = int * Messaging.id list
type master_state = { mo:master_option;
                      v: Value.t ;
                      n:n;
                      i:i;
                      lew: slave_awaiters}

type transitions =
  (* dummy to always have a previous transition *)
  | Start_transition

  (* election only *)
  | Election_suggest of (n * int)

  (* slave or pending slave *)
  | Slave_fake_prepare of (n * i)
  | Slave_steady_state of (n * i * Value.t option) (* value received for this n and previous i *)
  | Slave_discovered_other_master of (Messaging.id * Mp_msg.MPMessage.n *
                                        Mp_msg.MPMessage.n * Mp_msg.MPMessage.n )

  | Promises_check_done of (n * i *
                              Messaging.id list *
                              v_limits *
                              (string * Mp_msg.MPMessage.n) option *
                              slave_awaiters * int)
  | Wait_for_promises of (n * i * Messaging.id list *
                            v_limits *
                            (string * Mp_msg.MPMessage.n) option *
                            slave_awaiters * int)
  | Accepteds_check_done of (master_state * mballot)
  | Wait_for_accepteds   of (master_state * mballot)

  (* active master only *)
  | Master_consensus of master_state
  | Stable_master    of (n * i * slave_awaiters)
  | Master_dictate   of master_state
  (* read only *)
  | Read_only

(* utility functions *)
let show_transition = function
  | Start_transition -> "Start_transition"
  | Election_suggest _ -> "Election_suggest"
  | Slave_fake_prepare _ -> "Slave_fake_prepare"
  | Slave_steady_state _ -> "Slave_steady_state"
  | Slave_discovered_other_master _ -> "Slave_discovered_other_master"
  | Wait_for_promises _ -> "Wait_for_promises"
  | Promises_check_done _ -> "Promises_check_done"
  | Wait_for_accepteds _ -> "Wait_for_accepteds"
  | Accepteds_check_done _ -> "Accepteds_check_done"
  | Master_consensus _ -> "Master_consensus"
  | Stable_master _ -> "Stable_master"
  | Master_dictate _ -> "Master_dictate"
  | Read_only -> "Read_only"

type effect =
  | ELog of (unit -> string)
  | EMCast  of Mp_msg.MPMessage.t
  | ESend of Mp_msg.MPMessage.t * Messaging.id
  | EAccept of (Value.t * n * i)
  | EStartElectionTimeout of n * i
  | EConsensus of (master_option * Value.t * n * i * bool (* is slave *))
  | EGen of (unit -> unit Lwt.t)
