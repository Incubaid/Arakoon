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

open Store
open Lwt

module StringMap = Map.Make(String)

module type Extended_simple_store =
sig
  include Simple_store
  val _tranbegin : t -> transaction
  val _trancommit : t -> unit
  val _tranabort : t -> unit
end

module Batched_store = functor (S : Extended_simple_store) ->
struct
  type t = {
    s : S.t;
    mutable _cache : string option StringMap.t;
    mutable _current_tx_cache : string option StringMap.t;

    _tx_lock : Lwt_mutex.t;
    mutable _tx : transaction option;

    mutable _ls_tx : transaction option;

    mutable _counter : int;
  }

  let make_store b s =
    S.make_store b s >>= fun s -> Lwt.return {
      s;
      _cache = StringMap.empty;
      _current_tx_cache = StringMap.empty;

      _tx_lock = Lwt_mutex.create ();
      _tx = None;

      _ls_tx = None;

      _counter = 0;
    }

  let _apply_vo_to_local_store s ls_tx k vo =
    match vo with
      | Some v -> S.set s ls_tx k v
      | None ->
          if S.exists s k
          then
            S.delete s ls_tx k

  let _apply_vos_to_local_store s ls_tx m =
    StringMap.iter
      (fun k vo -> _apply_vo_to_local_store s ls_tx k vo)
      m

  let _track_or_apply_vo s k vo =
    match s._ls_tx with
      | None ->
          s._current_tx_cache <- StringMap.add k vo s._current_tx_cache
      | Some ls_tx ->
          _apply_vo_to_local_store s.s ls_tx k vo

  let _sync_cache_to_local_store s =
    if not (StringMap.is_empty s._cache)
    then
      begin
        let ls_tx = S._tranbegin s.s in
        s._ls_tx <- Some ls_tx;

        (* this should always succeed *)
        _apply_vos_to_local_store s.s ls_tx s._cache;
        S._trancommit s.s;

        s._cache <- StringMap.empty;
        s._ls_tx <- None;
        s._counter <- 0
      end

  let _sync_and_start_transaction_if_needed s =
    if s._tx = None
    then
      _sync_cache_to_local_store s
    else
      (* we're asked to sync from within a Batched_store transaction *)
      if s._ls_tx = None (* start a S transaction should none be initiated so far *)
      then
        begin
          _sync_cache_to_local_store s;
          let ls_tx = S._tranbegin s.s in
          s._ls_tx <- Some ls_tx;
          _apply_vos_to_local_store s.s ls_tx s._current_tx_cache
        end

  let with_transaction s f =
    Lwt_mutex.with_lock s._tx_lock (fun () ->
      let tx = new transaction in
      s._tx <- Some tx;
      Lwt.finalize
        (fun () ->
          f tx >>= fun r ->
          let () =
            match s._ls_tx with
              | None ->
                  (* transaction succeeded and no new transaction was started
                     (to handle the more difficult cases),
                     so let's apply the changes accumulated in _current_tx_cache to _cache *)
                  s._cache <-
                    StringMap.fold
                    (fun k vo acc ->
                      s._counter <- s._counter + 1;
                      StringMap.add k vo acc)
                    s._current_tx_cache
                    s._cache
              | Some ls_tx ->
                  (* a ls_transaction was started while in this batched_store transaction,
                     now is the time to finish that transaction *)
                  S._trancommit s.s;
                  s._ls_tx <- None
          in


          (* TODO maybe a more intelligent check to see _push_to_store if desired? *)
          if s._counter = 200
          then _sync_cache_to_local_store s;

          Lwt.return r)
        (fun () ->
          let () = match s._ls_tx with
              | None -> ()
              | Some ls_tx ->
                  (* a ls_transaction was started while in this batched_store transaction,
                     got an exception so aborting the transaction *)
                  S._tranabort s.s;
                  s._ls_tx <- None
          in

          s._tx <- None;
          s._current_tx_cache <- StringMap.empty;
          Lwt.return ()))

  let _verify_tx s tx =
    match s._tx with
      | None -> failwith "not in a batched store transaction"
      | Some tx' ->
          if tx != tx'
          then failwith "the provided transaction is not the current transaction of the batched store"

  let _with_key_in_caches s k match' else' =
    if StringMap.mem k s._current_tx_cache
    then
      match' (StringMap.find k s._current_tx_cache)
    else if StringMap.mem k s._cache
    then
      match' (StringMap.find k s._current_tx_cache)
    else
      else' ()

  let exists s k =
    _with_key_in_caches s k
      (function
        | None -> false
        | Some _ -> true)
      (fun () -> S.exists s.s k)

  let get s k =
    _with_key_in_caches s k
      (function
        | None -> raise Not_found
        | Some v -> v)
      (fun () -> S.get s.s k)

  let set s tx k v =
    _verify_tx s tx;
    _track_or_apply_vo s k (Some v)

  let delete s tx k =
    _verify_tx s tx;
    if exists s k
    then
      _track_or_apply_vo s k None
    else
      raise Not_found

  let range s prefix first finc last linc max =
    _sync_and_start_transaction_if_needed s;
    S.range s.s prefix first finc last linc max

  let range_entries s prefix first finc last linc max =
    _sync_and_start_transaction_if_needed s;
    S.range_entries s.s prefix first finc last linc max

  let rev_range_entries s prefix first finc last linc max =
    _sync_and_start_transaction_if_needed s;
    S.rev_range_entries s.s prefix first finc last linc max

  let prefix_keys s prefix max =
    _sync_and_start_transaction_if_needed s;
    S.prefix_keys s.s prefix max

  let delete_prefix s tx prefix =
    _verify_tx s tx;
    _sync_and_start_transaction_if_needed s;
    match s._ls_tx with
      | None -> failwith "batched_store s._ls_tx is None"
      | Some ls_tx -> S.delete_prefix s.s ls_tx  prefix

  let close s =
    _sync_and_start_transaction_if_needed s;
    S.close s.s

  let reopen s =
    _sync_and_start_transaction_if_needed s;
    S.reopen s.s

  let get_location s =
    S.get_location s.s

  let relocate s =
    _sync_and_start_transaction_if_needed s;
    S.relocate s.s

  let get_key_count s =
    _sync_and_start_transaction_if_needed s;
    S.get_key_count s.s

  let optimize s =
    _sync_and_start_transaction_if_needed s;
    S.optimize s.s

  let defrag s =
    _sync_and_start_transaction_if_needed s;
    S.defrag s.s

  let copy_store s =
    _sync_and_start_transaction_if_needed s;
    S.copy_store s.s

  let copy_store2 =
    S.copy_store2

  let get_fringe s =
    _sync_and_start_transaction_if_needed s;
    S.get_fringe s.s
end

module Local_store = Batched_store(Local_store)

