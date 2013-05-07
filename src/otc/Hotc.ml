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

open Otc

open Lwt

let next_prefix prefix =
  let next_char c =
    let code = Char.code c + 1 in
    match code with
      | 256 -> Char.chr 0, true
      | code -> Char.chr code, false in
  let rec inner s pos =
    let c, carry = next_char s.[pos] in
    s.[pos] <- c;
    match carry, pos with
      | false, _ -> Some s
      | true, 0 -> None
      | true, pos -> inner s (pos - 1) in
  let copy = String.copy prefix in
  inner copy ((String.length copy) - 1)


module Hotc = struct

  type t = {
    filename:string;
    bdb:Bdb.bdb;
    mutex:Lwt_mutex.t;
  }

  let get_bdb (wrapper: t) =
    wrapper.bdb

  let _do_locked t f =
    Lwt.catch (fun () -> Lwt_mutex.with_lock t.mutex f)
      (fun e -> Lwt.fail e)

  let _open t mode =
    Bdb._dbopen t.bdb t.filename mode

  let _open_lwt t mode = Lwt.return (_open t mode )

  let _close t =
    Bdb._dbclose t.bdb

  let _close_lwt t = Lwt.return (_close t)

  let _sync t =
    Bdb._dbsync t.bdb

  let _sync_lwt t = Lwt.return (_sync t)

  let create ?(mode=Bdb.default_mode) filename opts =
    let res = {
      filename = filename;
      bdb = Bdb._make ();
      mutex = Lwt_mutex.create ();
    } in
    _do_locked res (fun () ->
      Bdb.tune res.bdb opts;
      _open res mode;
      Lwt.return ()) >>= fun () ->
    Lwt.return res

  let close t =
    _do_locked t (fun () -> _close_lwt t)

  let sync t =
    _do_locked t (fun () -> _sync_lwt t)

  let read t (f:Bdb.bdb -> 'a) = _do_locked t (fun ()-> f t.bdb)

  let filename t = t.filename

  let optimize t = 
    Lwt_preemptive.detach (
      fun() -> 
        Lwt.ignore_result( Lwt_log.debug "Optimizing database" ); 
        Bdb.bdb_optimize t.bdb
    ) ()

  let defrag t = 
    _do_locked t (fun () -> let r = Bdb.bdb_defrag t.bdb in 
                            Lwt.return r)
    
  let reopen t when_closed mode=
    _do_locked t
      (fun () ->
	_close_lwt t >>= fun () ->
	when_closed () >>= fun () ->
	_open_lwt  t mode
      )

  let _delete t =
    Bdb._dbclose t.bdb;
    Bdb._delete t.bdb


  let _delete_lwt t = Lwt.return(_delete t)

  let delete t = _do_locked t (fun () -> _delete_lwt t)

  let _transaction t (f:Bdb.bdb -> 'a) =
    let bdb = t.bdb in
    Bdb._tranbegin bdb;
    Lwt.catch
      (fun () ->
	f bdb >>= fun res ->
	Bdb._trancommit bdb;
	Lwt.return res
      )
      (fun x ->
	Bdb._tranabort bdb ;
	Lwt.fail x)


  let transaction t (f:Bdb.bdb -> 'a) =
    _do_locked t (fun () -> _transaction t f)


  let with_cursor bdb (f:Bdb.bdb -> 'a) =
    let cursor = Bdb._cur_make bdb in
    Lwt.finalize
      (fun () -> f bdb cursor)
      (fun () -> let () = Bdb._cur_delete cursor in Lwt.return ())

  let with_cursor2 bdb (f:Bdb.bdb -> 'a) =
    let cursor = Bdb._cur_make bdb in
    try
      let x = f bdb cursor in
      let () = Bdb._cur_delete cursor in
      x
    with
      | exn ->
        let () = Bdb._cur_delete cursor in
        raise exn


  let rev_range_entries prefix bdb first finc last linc max =
    let first, finc = match first with
      | None -> next_prefix prefix, false
      | Some x -> Some (prefix ^ x), finc in
    let last = match last with | None -> "" | Some x -> prefix ^ x in
    let pl = String.length prefix in
    try with_cursor2 bdb (fun bdb cur ->
      let () = match first with
        | None -> Bdb.last bdb cur
        | Some first ->
            try
              let () = Bdb.jump bdb cur first in
              let jumped_key = Bdb.key bdb cur in
              if (String.compare jumped_key first) > 0 or (not finc) then Bdb.prev bdb cur
            with
              | Not_found -> Bdb.last bdb cur
      in
      let rec rev_e_loop acc count =
        if count = max then acc
        else
          let key, value = Bdb.record bdb cur in
          let l = String.length key in
          if not (String_extra.prefix_match prefix key) then
            acc
          else
            let key2 = String.sub key pl (l-pl) in
            if last = key then
              if linc then (key2,value)::acc else acc
            else if last > key then acc
            else
              let acc = (key2,value)::acc in
              let maybe_next =
                try
                  let () = Bdb.prev bdb cur in
                  None
                with
                  | Not_found ->
                      Some acc
              in
              match maybe_next with
                | Some acc -> acc
                | None -> rev_e_loop acc (count+1)
      in
      rev_e_loop [] 0
    )
    with
      | Not_found -> []

  let batch bdb (batch_size:int) (prefix:string) (start:string option) =
    transaction bdb
      (fun db2 ->
	with_cursor db2
	  (fun db3 cur ->
	    let res = match start with
	      | None ->
		begin
		  try
		    let () = Bdb.jump db3 cur prefix in
		    None
		  with
		    | Not_found -> Some []
		end
	      | Some start2 ->
		let key = prefix ^ start2 in
		try
		  let () = Bdb.jump db3 cur key in
		  let key2 = Bdb.key db3 cur in
		  if key = key2 then
		    let () = Bdb.next db3 cur in
		    None
		  else None
		with
		  | Not_found -> Some []
	    in
	    match res with
              | Some empty -> Lwt.return empty
              | None ->
		let rec one build = function
		  | 0 -> Lwt.return (List.rev build)
		  | count ->
		    Lwt.catch (fun () ->
		      let key = Bdb.key db3 cur in
		      let prefix_len = String.length prefix in
		      let prefix2 = String.sub key 0 prefix_len in
		      let () = if prefix2 <> prefix then raise Not_found in
		      let value = Bdb.value db3 cur in
		      (* chop of prefix *)
		      let skey = String.sub key prefix_len ((String.length key) - prefix_len) in
		      (* let () = log "ZZZ k:'%s' v:'%s'" skey value in *)
		      Lwt.return (Some (skey,value))
		    ) (function | Not_found -> Lwt.return None | exn -> Lwt.fail exn) >>= function
		      | None -> Lwt.return (List.rev build)
		      | Some s ->
			Lwt.catch
			  (fun () ->
			    let () = Bdb.next db3 cur in
			    one (s::build) (count-1)
			  )
			  (function | Not_found -> Lwt.return (List.rev (s::build)) | exn -> Lwt.fail exn)
		in
		one [] batch_size
	  )
      )


  let delete_prefix bdb prefix = 
    let count = ref 0 in
    with_cursor2 bdb 
      (fun bdb cur ->
        try
          let () = Bdb.jump bdb cur prefix in
          let rec step () =  
            let jumped_key = Bdb.key bdb cur in
            if String_extra.prefix_match prefix jumped_key 
            then 
              let () = Bdb.cur_out bdb cur in (* and jump to next *)
              let () = incr count in
              step () 
            else 
              ()
                
          in
          step ()
        with
          | Not_found -> ()
      );
    !count


end
