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

let serialize_string  b s = Llio.string_to b s
let serialize_hashtbl b f h = Llio.hashtbl_to b f h
let serialize_string_list b sl = Llio.string_list_to b sl

type input = Llio.buffer
let make_input s i = Llio.make_buffer s i

let deserialize_string i = Llio.string_from i
let deserialize_string_list i = Llio.string_list_from i
let deserialize_hashtbl i f = Llio.hashtbl_from i f

let generic_f f x =
  let k s = Lwt.ignore_result (f s) in
  Printf.kprintf k x

let debug_f x = generic_f Client_log.debug x
