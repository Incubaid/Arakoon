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

let archive_name tlog_name = tlog_name ^ ".tlc"

let tlog_name archive_name =
  let len = String.length archive_name in
  let ext = String.sub archive_name (len-4) 4 in
  assert (ext=".tlc");
  String.sub archive_name 0 (len-4)


let tlog2tlc tlog_name archive_name =
  let limit = 1024 * 1024 in
  Lwt_io.with_file ~mode:Lwt_io.input tlog_name
    (fun ic ->
       Lwt_io.with_file ~mode:Lwt_io.output archive_name
         (fun oc ->
            let rec fill_buffer buffer i =
              Lwt.catch
                (fun () ->
                   Tlogcommon.read_into ic buffer >>= fun () ->
                   if Buffer.length buffer < limit then
                     fill_buffer buffer (i+1)
                   else
                     Lwt.return i
                )
                (function
                  | End_of_file -> Lwt.return i
                  | exn -> Lwt.fail exn
                )
            in
            let compress_and_write n_entries buffer =
              let contents = Buffer.contents buffer in
              let output = Bz2.compress ~block:9 contents 0 (String.length contents) in
              Llio.output_int oc n_entries >>= fun () ->
              Llio.output_string oc output
            in
            let buffer = Buffer.create limit in
            let rec loop () =
              fill_buffer buffer 0 >>= fun n_entries ->
              if n_entries = 0
              then Lwt.return ()
              else
                begin
                  compress_and_write n_entries buffer >>= fun () ->
                  let () = Buffer.clear buffer in
                  loop ()
                end
            in
            loop ()
         )
    )

let tlc2tlog archive_name tlog_name =
  Lwt_io.with_file ~mode:Lwt_io.input archive_name
    (fun ic ->
       Lwt_io.with_file ~mode:Lwt_io.output tlog_name
         (fun oc ->
            let rec loop () =
              Lwt.catch
                (fun () ->
                   Llio.input_int ic >>= fun n_entries ->
                   Llio.input_string ic >>= fun compressed ->
                   Lwt.return (Some compressed))
                (function
                  | End_of_file -> Lwt.return None
                  | exn -> Lwt.fail exn
                )
              >>= function
              | None -> Lwt.return ()
              | Some compressed ->
                begin
                  let lc = String.length compressed in
                  let output = Bz2.uncompress compressed 0 lc in
                  let lo = String.length output in
                  Lwt_io.write_from_exactly oc output 0 lo >>= fun () ->
                  loop ()
                end
            in loop ()))
