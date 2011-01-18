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
open Update
type entry = Sn.t * Update.t

let uncompress_block compressed = 
  let lc = String.length compressed in
  Bz2.uncompress compressed 0 lc

module type TR = sig
  val fold: Lwt_io.input_channel -> 
    Sn.t -> Sn.t option -> first:Sn.t ->
    'a ->
    ('a -> Sn.t* Update.t -> 'a Lwt.t) -> 'a Lwt.t
    (** here this fold does not attempt to eliminate doubles:
	it makes the code simpler and any state-updates that you need
	to do this can be done in the acc anyway.
    **)
end

module U = struct
  let fold ic lowerI 
      (higherI:Sn.t option)
      ~first
      (a0:'a) (f:'a -> Sn.t * Update.t -> 'a Lwt.t) =
    let sno2s sno= Log_extra.option_to_string Sn.string_of sno in
    Lwt_log.debug_f "U.fold %s %s" (Sn.string_of lowerI)
      (sno2s higherI) >>= fun () ->
    let next () =
      Lwt.catch
	(fun () ->
	  Tlogcommon.read_entry ic >>= fun t ->
	  Lwt.return (Some t)
	)
	(function
	  | End_of_file -> (Lwt_io.close ic >>= fun () -> Lwt.return None )
	  | exn -> Lwt.fail exn)
    in
    let rec skip_until () =
      next () >>= function
	| None -> Lwt.return None
	| Some (i,update) ->
	  if i < lowerI
	  then skip_until ()
	  else Lwt.return (Some (i, update) )
    in
    let rec _fold (a:'a) (i,u) =
      match higherI with
	| None -> 
	  begin 
	    f a (i,u) >>= fun a' -> 
	    next () >>= function
	      | None -> Lwt.return a'
	      | Some (i',u') -> _fold a' (i',u')
	  end
	| Some hi ->
	  if (i > hi) 
	  then Lwt.return a
	  else 
	    begin
	      f a (i,u) >>= fun a' ->
	      next () >>= function
		| None -> Lwt.return a'
		| Some (i',u') -> _fold a' (i',u')
	    end
    in skip_until () >>= function
      | None ->  Lwt.return a0
      | Some (i0,u0) ->
	_fold a0 (i0,u0)

end


module C = struct
  let fold ic (lowerI:Sn.t) (higherI:Sn.t option) ~first a0 f = 
    Lwt_log.debug_f "C.fold lowerI:%s higherI:%s ~first:%s" (Sn.string_of lowerI)
      (Log_extra.option_to_string Sn.string_of higherI) 
      (Sn.string_of first)
    >>= fun () ->
    let rec _skip_blocks c = 
      Llio.input_int ic >>= fun ne_i ->
      Llio.input_string ic >>= fun s ->
      let n_entries = Sn.of_int ne_i in
      let c' = Sn.add c n_entries in
      Lwt_log.debug_f "n_entries=%i c'=%s%!" ne_i (Sn.string_of c') 
      >>= fun () ->
      if c' <= lowerI then
	begin
	  _skip_blocks c' 
	end
      else
	begin
	  Lwt.return s
	end
    in
    let rec _skip_in_block buffer pos =
      let beyond = String.length buffer in 
      let rec _loop (maybe_p:entry option) pos =
	if pos = beyond then maybe_p, pos
	else
	  begin
	    let (i1,update1), pos1 = Tlogcommon.entry_from buffer pos in
	    if i1 > lowerI 
	    then maybe_p, pos
	    else 
	      _loop (Some (i1,update1)) pos1
	  end
      in
      _loop None pos 
    in
    let rec _fold_block a buffer pos =
      Lwt_log.debug_f "_fold_block:pos=%i" pos>>= fun() ->
      let rec _loop a p =
	if p = (String.length buffer) 
	then Lwt.return a
	else
	  let (i2,update2), pos2 = Tlogcommon.entry_from buffer p in
	  match higherI with
	    | None ->  
	      begin
		f a (i2, update2) >>= fun a' ->
		_loop a' pos2
	      end
	    | Some hi ->
	      if i2 < hi then
		begin
		  f a (i2, update2) >>= fun a' ->
		  _loop a' pos2 
		end
	      else
		Lwt.return a

      in
      _loop a pos
    in
    let maybe_read_buffer () =
      Lwt.catch 
	(fun () -> Llio.input_int ic >>= fun _ (* how many entries *) ->
	  Llio.input_string ic >>= fun compressed -> Lwt.return (Some compressed))
	(function 
	  | End_of_file -> Lwt.return None
	  | e -> Lwt.fail e
	)
    in
    let rec _fold_blocks a =
      Lwt_log.debug "_fold_blocks " >>= fun () ->
      maybe_read_buffer () >>= function
	| None -> Lwt.return a
	| Some compressed ->
	  begin
	    Lwt_log.debug_f "compressed: %i" (String.length compressed) >>= fun () ->
	    let buffer = uncompress_block compressed in
	    _fold_block a buffer 0 >>= fun a' ->
	    _fold_blocks a'
	  end
    in
    _skip_blocks first >>= fun compressed -> 
    Lwt_log.debug_f "... to _skip_in_block %i" (String.length compressed) >>= fun () ->
    let buffer = uncompress_block compressed in
    Lwt_log.debug_f "uncompressed (size=%i)" (String.length buffer) >>= fun () ->
    let maybe_first, pos = _skip_in_block buffer 0 in
    begin
      match maybe_first with
	| None -> Lwt.return a0
	| Some entry-> f a0 entry
    end >>= fun a' ->
    Lwt_log.debug "post_skip_in_block" >>= fun () ->
    _fold_block (a':'a) buffer pos >>= fun a1 -> 
    Lwt_log.debug "after_block" >>= fun () ->
    _fold_blocks a1
    
end

module AU = (U: TR)
module AC = (C: TR)
