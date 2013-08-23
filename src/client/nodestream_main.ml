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
open Node_cfg
open Remote_nodestream
open Lwt
open Network

let _do_it ip port cluster_id f =
  let do_it connection =
    make_remote_nodestream cluster_id connection >>= fun client ->
    f client
  in
  let address = make_address ip port in
  let t () =
    Lwt_io.with_connection address do_it  >>= fun () ->
    Lwt.return 0
  in
  Lwt_main.run( t())

let optimize_db ip port cluster_id =
  _do_it ip port cluster_id (fun client -> client # optimize_db ())

let defrag_db ip port cluster_id =
  _do_it ip port cluster_id (fun client -> client # defrag_db ())

let get_db ip port cluster_id location =
  _do_it ip port cluster_id (fun client -> client # get_db location)

let drop_master ip port cluster_id =
  _do_it ip port cluster_id (fun client -> client # drop_master ())
