type 'a t = Ssl.context

let create_client_context proto = Ssl.create_context proto Ssl.Client_context
let create_server_context proto = Ssl.create_context proto Ssl.Server_context
let create_both_context proto = Ssl.create_context proto Ssl.Both_context

let embed_socket = Ssl.embed_socket

let use_certificate = Ssl.use_certificate
let set_verify = Ssl.set_verify
let set_client_CA_list_from_file = Ssl.set_client_CA_list_from_file
let load_verify_locations = Ssl.load_verify_locations

open Lwt

module Lwt = struct
  let ssl_connect fd ctx =
    Lwt_ssl.ssl_connect fd ctx >>= fun lwt_s ->
    match Lwt_ssl.ssl_socket lwt_s with
      | None -> Lwt.fail (Failure "Typed_ssl.Lwt.ssl_connect: unexpected plain socket")
      | Some s -> Lwt.return (s, lwt_s)

  let ssl_accept fd ctx =
    Lwt_ssl.ssl_accept fd ctx >>= fun lwt_s ->
    match Lwt_ssl.ssl_socket lwt_s with
      | None -> Lwt.fail (Failure "Typed_ssl.Lwt.ssl_accept: unexpected plain socket")
      | Some s -> Lwt.return (s, lwt_s)
end
