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

open OUnit
open Node_cfg
open Node_cfg
open Lwt.Infix
let test_correctness () =

  let t =
    Node_cfg.retrieve_cfg !config_url >>= fun cfg ->
    let r = OUnit.assert_equal cfg.cluster_id "ricky" in
    Lwt.return r
  in
  Lwt_main.run t

let suite = "node_cfg" >::: [
      "correctness" >:: test_correctness;
    ]
