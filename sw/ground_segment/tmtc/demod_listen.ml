(*
 * $Id$
 *
 * Hardware modem receiver
 *  
 * Copyright (C) 2004 CENA/ENAC, Pascal Brisset, Antoine Drouin
 *
 * This file is part of paparazzi.
 *
 * paparazzi is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2, or (at your option)
 * any later version.
 *
 * paparazzi is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with paparazzi; see the file COPYING.  If not, write to
 * the Free Software Foundation, 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA. 
 *
 *)

open Printf

(** Ivy messages are initially tagged "modem" and with the A/C
id as soon as it is identified (IDENT message) *)
let ac_id = ref "modem"

let modem_msg_period = 1000 (** ms *)

module Tele_Class = struct let name = "telemetry_ap" end
module Tele_Pprz = Pprz.Protocol(Tele_Class)
module PprzTransport = Serial.Transport(Tele_Pprz)

(** Monitoring of the message reception *)
type status = {
    mutable rx_byte : int;
    mutable rx_msg : int;
    mutable rx_err : int
  }
let status = { rx_byte = 0; rx_msg = 0; rx_err = 0 }

(** Callback for each decoded message *)
let use_pprz_message = fun (msg_id, values) ->
  status.rx_msg <- status.rx_msg + 1; (** Monitoring update *)
  let msg = Tele_Pprz.message_of_id msg_id in
  if msg.Pprz.name = "IDENT" then
    ac_id := Pprz.string_assoc "id" values;
  (***)prerr_endline msg.Pprz.name;
  Tele_Pprz.message_send !ac_id msg.Pprz.name values

(** Listen on a dsp device *)
let listen_pprz_modem = fun pprz_message_cb devdsp ->
  let fd = Demod.init devdsp in

  (** Callback for a checksumed pprz message *)
  let use_pprz_buf = fun buf ->
    status.rx_byte <- status.rx_byte + String.length buf;
    Debug.call 'P' (fun f -> fprintf f "use_pprz: %s\n" (Debug.xprint buf));
    pprz_message_cb (Tele_Pprz.values_of_bin buf) in

  (** Callback for available chars *)
  let cb =
    let buffer = ref "" in
    fun _ ->
      printf("get_date\n%!");
      let (data_left, data_right) = Demod.get_data () in
      (***)printf "left=%s\n%!" (Debug.xprint  data_left);
      (***)printf "right=%s\n%!" (Debug.xprint  data_right);
      (** Accumulate in a buffer *)
      let b = !buffer ^ data_left in
      Debug.call 'M' (fun f -> fprintf f "Pprz buffer: %s\n" (Debug.xprint b));
      (** Parse as pprz message and ... *)
      let x = PprzTransport.parse use_pprz_buf b in
      status.rx_err <- !PprzTransport.nb_err;
      (** ... remove from the buffer the chars which have been used *)
      buffer := String.sub b x (String.length b - x);
      true
  in

  (** Attach the callback to the channel *)
  ignore (Glib.Io.add_watch [`IN] cb (Glib.Io.channel_of_descr fd))

(** Modem monitoring messages *)
let send_modem_msg =
  let rx_msg = ref 0 
  and rx_byte = ref 0 
  and start = Unix.gettimeofday () in
  fun () ->
    let dt = float modem_msg_period /. 1000. in
    let t = int_of_float (Unix.gettimeofday () -. start) in
    let byte_rate = float (status.rx_byte - !rx_byte) /. dt
    and msg_rate = float (status.rx_msg - !rx_msg) /. dt in
    rx_msg := status.rx_msg;
    rx_byte := status.rx_byte;
    let vs = ["run_time", Pprz.Int t;
	      "rx_bytes_rate", Pprz.Float byte_rate; 
	      "rx_msgs_rate", Pprz.Float msg_rate;
	      "rx_err", Pprz.Int status.rx_err;
	      "rx_bytes", Pprz.Int status.rx_byte;
	      "rx_msgs", Pprz.Int status.rx_msg
	    ] in
    Tele_Pprz.message_send !ac_id "DOWNLINK_STATUS" vs

(* main loop *)
let _ =
  let ivy_bus = ref "127.255.255.255:2010" in
  let port = ref "/dev/dsp" in
  let options =
    [ "-b", Arg.Set_string ivy_bus, (sprintf "Ivy bus (%s)" !ivy_bus);
      "-d", Arg.Set_string port, (sprintf "Port (%s)" !port)] in
  Arg.parse
    options
    (fun x -> fprintf stderr "Warning:ignoring %s\n" x)
    "Usage: ";
  
  Ivy.init "Paparazzi hw_modem_listen" "READY" (fun _ _ -> ());
  Ivy.start !ivy_bus;

  (** Listening on the given port (serial device or multimon fifo)*)
  listen_pprz_modem use_pprz_message !port;

  (** Sending periodically modem and downlink status messages *)
  ignore (Glib.Timeout.add modem_msg_period (fun () -> send_modem_msg (); true));
  
  let loop = Glib.Main.create true in
  while Glib.Main.is_running loop do
    ignore (Glib.Main.iteration true)
  done
