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

let section = Logger.Section.main

let make_address host port =
  let ha = Unix.inet_addr_of_string host in
  Unix.ADDR_INET (ha, port)

let a2s = function
  | Unix.ADDR_INET (sa,p) -> Printf.sprintf "(%s,%i)" (Unix.string_of_inet_addr sa) p
  | Unix.ADDR_UNIX s      -> Printf.sprintf "ADDR_UNIX(%s)" s

let __open_connection ?(ssl_context : [> `Client ] Typed_ssl.t option) socket_address =
  (* Lwt_io.open_connection socket_address *)
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0  in
  let () = Lwt_unix.setsockopt socket Lwt_unix.TCP_NODELAY true in
  Lwt.catch
    (fun () ->
       Lwt_unix.connect socket socket_address >>= fun () ->
       let a2 = Lwt_unix.getsockname socket in
       let peer = Lwt_unix.getpeername socket in
       begin
         if (a2 = peer)
         then Llio.lwt_failfmt "a socket should not connect to itself"
         else Lwt.return ()
       end
       >>= fun () ->
       let fd_field = Obj.field (Obj.repr socket) 0 in
       let (fdi:int) = Obj.magic (fd_field) in
       let peer_s = a2s peer in
       Logger.info_f_ "__open_connection SUCCEEDED (fd=%i) %s %s" fdi
         (a2s a2) peer_s
       >>= fun () ->
       match ssl_context with
         | None ->
             let ic = Lwt_io.of_fd ~mode:Lwt_io.input  socket
             and oc = Lwt_io.of_fd ~mode:Lwt_io.output socket in
             Lwt.return (ic,oc)
         | Some ctx ->
             Typed_ssl.Lwt.ssl_connect socket ctx >>= fun (s, lwt_s) ->
             let cert = Ssl.get_certificate s in
             Logger.info_f_
               "__open_connection: SSL connection to %s succeeded, issuer=%s, subject=%s"
               peer_s (Ssl.get_issuer cert) (Ssl.get_subject cert) >>= fun () ->
             let cipher = Ssl.get_cipher s in
             Logger.debug_f_
               "__open_connection: SSL connection to %s using %s"
               peer_s (Ssl.get_cipher_description cipher) >>= fun () ->
             let ic = Lwt_ssl.in_channel_of_descr lwt_s
             and oc = Lwt_ssl.out_channel_of_descr lwt_s in
             Lwt.return (ic, oc)
       )
    (fun exn ->
       Logger.info_f_ ~exn "__open_connection to %s failed" (a2s socket_address)
       >>= fun () ->
       Lwt_unix.close socket >>= fun () ->
       Lwt.fail exn)
