(*----------------------------------------------------------------------------
 *  Copyright (c) 2019 António Nuno Monteiro
 *
 *  All rights reserved.
 *
 *  Redistribution and use in source and binary forms, with or without
 *  modification, are permitted provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice,
 *  this list of conditions and the following disclaimer.
 *
 *  2. Redistributions in binary form must reproduce the above copyright
 *  notice, this list of conditions and the following disclaimer in the
 *  documentation and/or other materials provided with the distribution.
 *
 *  3. Neither the name of the copyright holder nor the names of its
 *  contributors may be used to endorse or promote products derived from this
 *  software without specific prior written permission.
 *
 *  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 *  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 *  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 *  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 *  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 *  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 *  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 *  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 *  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 *  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *  POSSIBILITY OF SUCH DAMAGE.
 *---------------------------------------------------------------------------*)

open Lwt.Infix

let _ = Nocrypto_entropy_lwt.initialize ()

module Io :
  Httpaf_lwt.IO
    with type socket = Lwt_unix.file_descr * Tls_lwt.Unix.t
     and type addr = Unix.sockaddr = struct
  type socket = Lwt_unix.file_descr * Tls_lwt.Unix.t

  type addr = Unix.sockaddr

  let read (_, tls) bigstring ~off ~len =
    Lwt.catch
      (fun () -> Tls_lwt.Unix.read_bytes tls bigstring off len)
      (function
        | Unix.Unix_error (Unix.EBADF, _, _) as exn ->
          Lwt.fail exn
        | exn ->
          Lwt.async (fun () -> Tls_lwt.Unix.close tls);
          Lwt.fail exn)
    >>= fun bytes_read ->
    if bytes_read = 0 then
      Lwt.return `Eof
    else
      Lwt.return (`Ok bytes_read)

  let writev (_, tls) iovecs =
    Lwt.catch
      (fun () ->
        let cstruct_iovecs =
          List.map
            (fun { Faraday.len; buffer; off } ->
              Cstruct.of_bigarray ~off ~len buffer)
            iovecs
        in
        Tls_lwt.Unix.writev tls cstruct_iovecs >|= fun () ->
        `Ok (Cstruct.lenv cstruct_iovecs))
      (function
        | Unix.Unix_error (Unix.EBADF, "check_descriptor", _) ->
          Lwt.return `Closed
        | exn ->
          Lwt.fail exn)

  let shutdown_send (_, tls) = ignore (Tls_lwt.Unix.close_tls tls)

  let shutdown_receive (_, tls) = ignore (Tls_lwt.Unix.close_tls tls)

  let close (_, tls) = Tls_lwt.Unix.close tls
end

type client = Tls_lwt.Unix.t
type server = Tls_lwt.Unix.t

let make_client ?client socket =
  match client with
  | Some client -> Lwt.return client
  | None ->
    X509_lwt.authenticator `No_authentication_I'M_STUPID >>= fun authenticator ->
    let config = Tls.Config.client ~authenticator () in
    Tls_lwt.Unix.client_of_fd config socket

let make_server ?server ?certfile ?keyfile socket =
  let server =
    match server, certfile, keyfile with
    | Some server, _, _ ->
      Lwt.return server
    | None, Some cert, Some priv_key ->
      X509_lwt.private_of_pems ~cert ~priv_key >>= fun certificate ->
      let config =
        Tls.Config.server
          ~alpn_protocols:[ "http/1.1" ]
          ~certificates:
            (`Single certificate)
          ()
      in
      Tls_lwt.Unix.server_of_fd config socket
    | _ ->
      Lwt.fail
        (Invalid_argument
           "Certfile and Keyfile required when server isn't provided")
  in
  server