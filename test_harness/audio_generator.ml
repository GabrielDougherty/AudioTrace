(* Audio Generator Module
   
   Generates and plays test audio signals (sine waves) for testing AudioTrace.
   This is more reliable than using 'say' because:
   - Continuous signal ensures audio is playing during the test window
   - Known frequency makes it easier to verify capture
   - No dependency on text-to-speech timing
*)

open Printf

(* WAV file format constants *)
module WAV = struct
  let sample_rate = 48000  (* Match AudioTrace's expected sample rate *)
  let bits_per_sample = 16
  let num_channels = 2     (* Stereo *)
  
  (* Write a 16-bit little-endian integer *)
  let write_le16 oc value =
    output_byte oc (value land 0xFF);
    output_byte oc ((value lsr 8) land 0xFF)
  
  (* Write a 32-bit little-endian integer *)
  let write_le32 oc value =
    output_byte oc (value land 0xFF);
    output_byte oc ((value lsr 8) land 0xFF);
    output_byte oc ((value lsr 16) land 0xFF);
    output_byte oc ((value lsr 24) land 0xFF)
  
  (* Write WAV header *)
  let write_header oc data_size =
    let file_size = data_size + 36 in
    let byte_rate = sample_rate * num_channels * (bits_per_sample / 8) in
    let block_align = num_channels * (bits_per_sample / 8) in
    
    (* RIFF header *)
    output_string oc "RIFF";
    write_le32 oc file_size;
    output_string oc "WAVE";
    
    (* fmt chunk *)
    output_string oc "fmt ";
    write_le32 oc 16;                    (* Chunk size *)
    write_le16 oc 1;                     (* Audio format (1 = PCM) *)
    write_le16 oc num_channels;
    write_le32 oc sample_rate;
    write_le32 oc byte_rate;
    write_le16 oc block_align;
    write_le16 oc bits_per_sample;
    
    (* data chunk *)
    output_string oc "data";
    write_le32 oc data_size
end

(* Generate a sine wave sample at given time and frequency *)
let sine_sample frequency time =
  let pi = 4.0 *. atan 1.0 in
  sin (2.0 *. pi *. frequency *. time)

(* Generate a WAV file with a sine wave *)
let generate_sine_wave ~filename ~frequency ~duration =
  try
    let oc = open_out_bin filename in
    let num_samples = int_of_float (float_of_int WAV.sample_rate *. duration) in
    let data_size = num_samples * WAV.num_channels * (WAV.bits_per_sample / 8) in
    
    (* Write WAV header *)
    WAV.write_header oc data_size;
    
    (* Generate and write samples *)
    for i = 0 to num_samples - 1 do
      let t = float_of_int i /. float_of_int WAV.sample_rate in
      let sample = sine_sample frequency t in
      
      (* Convert to 16-bit signed integer (range -32768 to 32767) *)
      let sample_int = int_of_float (sample *. 32767.0) in
      
      (* Write stereo (same sample to both channels) *)
      WAV.write_le16 oc sample_int;  (* Left channel *)
      WAV.write_le16 oc sample_int;  (* Right channel *)
    done;
    
    close_out oc;
    Ok filename
  with
  | e -> Error (sprintf "Failed to generate WAV file: %s" (Printexc.to_string e))

(* Play a WAV file using afplay (macOS native audio player) *)
let play_wav_file filename =
  try
    (* Fork a process to play the file *)
    let pid = Unix.fork () in
    if pid = 0 then begin
      (* Child process - exec afplay *)
      Unix.execv "/usr/bin/afplay" [| "/usr/bin/afplay"; filename |]
    end else begin
      (* Parent process - return the PID for later cleanup *)
      Ok pid
    end
  with
  | e -> Error (sprintf "Failed to play audio: %s" (Printexc.to_string e))

(* Stop playing audio by killing the afplay process *)
let stop_audio pid =
  try
    Unix.kill pid Sys.sigterm;
    (* Wait for process to avoid zombies *)
    let _ = Unix.waitpid [] pid in
    ()
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> ()  (* Process already dead *)
  | e -> 
      printf "Warning: Failed to stop audio: %s\n" (Printexc.to_string e)

(* High-level function: create and play a test tone *)
let play_test_tone ~frequency ~duration ~temp_file =
  match generate_sine_wave ~filename:temp_file ~frequency ~duration with
  | Error msg -> Error msg
  | Ok wav_file ->
      match play_wav_file wav_file with
      | Error msg -> Error msg
      | Ok pid -> Ok (pid, wav_file)

(* Clean up: stop audio and delete temp file *)
let cleanup (pid, temp_file) =
  stop_audio pid;
  (* Give it a moment to stop *)
  Unix.sleepf 0.1;
  (* Delete temp file *)
  try
    Sys.remove temp_file
  with _ -> ()

(* Example usage:
   
   match play_test_tone ~frequency:220.0 ~duration:35.0 ~temp_file:"/tmp/test.wav" with
   | Error msg -> printf "Error: %s\n" msg
   | Ok handle ->
       (* Do your testing here *)
       Unix.sleep 30;
       (* Clean up *)
       cleanup handle
*)
