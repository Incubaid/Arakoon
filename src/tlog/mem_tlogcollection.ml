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



open Tlogcollection
open Tlogcommon
open Lwt

let delay = ref None

class mem_tlog_collection name =
  object (self: #tlog_collection)

    val mutable data = []
    val mutable last_entry = (None: Entry.t option)

    method validate_last_tlog () =
      Lwt.return (TlogValidComplete, last_entry, None)

    method get_infimum_i () = Lwt.return Sn.start

    method get_last_i () =
      match last_entry with
        | None -> Sn.start
        | Some entry -> Entry.i_of entry

    method get_last_value i =
      match last_entry with
        | None -> None
        | Some entry ->
          let i' = Entry.i_of entry in
          begin
            if i = i'
            then
              let v = Entry.v_of entry in
              Some v
            else
              None
          end

    method get_last () =
      match last_entry with
        | None -> None
        | Some e -> Some (Entry.v_of e, Entry.i_of e)


    method iterate from_i too_far_i f =
      let data' =
        List.filter
          (fun entry ->
            let ei = Entry.i_of entry in
            ei >= from_i && ei < too_far_i)
          data in
      Lwt_list.iter_s f (List.rev data')


    method get_tlog_count() = failwith "get_tlog_count not supported"

    method dump_tlog_file start_i oc = failwith "dump_tlog_file not supported"

    method save_tlog_file name length ic = failwith "save_tlog_file not supported"

    method which_tlog_file start_i = failwith "which_tlog_file not supported"

    method log_value_explicit i (v:Value.t) sync marker =
      let entry = Entry.make i v 0L marker in
      let () = data <- entry::data in
      let () = last_entry <- (Some entry) in
      match !delay with
      | None ->
         Lwt.return ()
      | Some d ->
         Lwt_unix.sleep (Random.float d)

    method log_value i v = self #log_value_explicit i v false None


    method dump_head oc = Llio.lwt_failfmt "dump_head not implemented"
    method save_head ic = Llio.lwt_failfmt "save_head not implemented"

    method get_head_name () = failwith "get_head_name not implemented"

    method get_tlog_from_name n = failwith "get_tlog_from_name not implemented"

    method get_tlog_from_i _ = Sn.start

    method close ?(wait_for_compression = false) () = Lwt.return ()

    method remove_oldest_tlogs count = Lwt.return ()

    method remove_below i = Lwt.return ()
  end

let make_mem_tlog_collection tlog_dir tlf_dir head_dir ~fsync name ~fsync_tlog_dir =
  let x = new mem_tlog_collection name in
  let x2 = (x :> tlog_collection) in
  Lwt.return x2
