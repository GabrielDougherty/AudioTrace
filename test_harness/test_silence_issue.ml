(* AudioTrace Silence Issue Test Harness
   
   This test harness demonstrates the silence issue by:
   1. Starting AudioTrace app
   2. Playing audio (using macOS 'say' command)
   3. Monitoring output for 30 seconds
   4. Killing the app
   5. Verifying that only RMS=0.0000... was captured (proving the bug)
   
   This showcases OCaml's:
   - Result type for error handling
   - Pattern matching
   - Process management via Unix module
   - String parsing with regular expressions
*)

open Printf

(* Custom result type for our test outcomes *)
type test_result =
  | Success of { non_zero_samples: int; zero_samples: int }
  | Failure of string
  | Inconclusive of string

(* Process handle for cleanup *)
type process_handle = {
  pid: int;
  name: string;
  stdout_fd: Unix.file_descr;
}

(* ANSI color codes for pretty output *)
module Color = struct
  let red s = sprintf "\027[31m%s\027[0m" s
  let green s = sprintf "\027[32m%s\027[0m" s
  let yellow s = sprintf "\027[33m%s\027[0m" s
  let blue s = sprintf "\027[34m%s\027[0m" s
  let bold s = sprintf "\027[1m%s\027[0m" s
end

(* Configuration *)
let audio_trace_path = "/Users/gabriel/ws/AudioTrace/build/AudioTrace.app/Contents/MacOS/AudioTrace"
let test_duration = 30.0
let test_frequency = 220.0  (* A3 note - low enough to be pleasant but audible *)
let temp_wav_file = "/tmp/audiotrace_test_tone.wav"

(* Kill a process by PID, handling errors gracefully *)
let kill_process handle =
  try
    Unix.kill handle.pid Sys.sigterm;
    printf "%s Sent SIGTERM to %s (PID %d)\n" 
      (Color.yellow "⚡") handle.name handle.pid;
    
    (* Wait a bit for graceful shutdown *)
    Unix.sleepf 0.5;
    
    (* Force kill if still running *)
    begin try
      Unix.kill handle.pid Sys.sigkill;
      printf "%s Sent SIGKILL to %s (PID %d)\n" 
        (Color.yellow "⚡") handle.name handle.pid
    with Unix.Unix_error (Unix.ESRCH, _, _) ->
      (* Process already dead, that's fine *)
      ()
    end;
    
    (* Clean up file descriptor *)
    Unix.close handle.stdout_fd
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) ->
      printf "%s Process %s (PID %d) already terminated\n"
        (Color.blue "ℹ") handle.name handle.pid
  | e ->
      printf "%s Error killing process %s: %s\n"
        (Color.red "✗") handle.name (Printexc.to_string e)

(* Start a background process and return handle *)
let start_process ~name ~cmd ~args : (process_handle, string) result =
  try
    let (read_fd, write_fd) = Unix.pipe () in
    let pid = Unix.fork () in
    
    if pid = 0 then begin
      (* Child process *)
      Unix.close read_fd;
      Unix.dup2 write_fd Unix.stdout;
      Unix.dup2 write_fd Unix.stderr;
      Unix.close write_fd;
      Unix.execv cmd args
    end else begin
      (* Parent process *)
      Unix.close write_fd;
      Ok { pid; name; stdout_fd = read_fd }
    end
  with
  | e -> Error (sprintf "Failed to start %s: %s" name (Printexc.to_string e))

(* Read available output from a file descriptor without blocking *)
let read_nonblocking fd max_bytes =
  try
    Unix.set_nonblock fd;
    let buffer = Bytes.create max_bytes in
    let n = Unix.read fd buffer 0 max_bytes in
    Some (Bytes.sub_string buffer 0 n)
  with
  | Unix.Unix_error (Unix.EAGAIN, _, _) -> None
  | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) -> None
  | _ -> None

(* Parse RMS values from AudioTrace output *)
let parse_rms_samples output =
  (* Pattern matches "RMS=0.000000000" anywhere in the line *)
  let rms_pattern = Str.regexp "RMS=\\([0-9.]+\\)" in
  let lines = String.split_on_char '\n' output in
  
  let rec parse_lines lines zero_count non_zero_count =
    match lines with
    | [] -> (zero_count, non_zero_count)
    | line :: rest ->
        try
          (* search_forward searches anywhere in the string, not just at position 0 *)
          let _ = Str.search_forward rms_pattern line 0 in
          let rms_str = Str.matched_group 1 line in
          let rms = float_of_string rms_str in
          if rms = 0.0 || rms < 0.000001 then
            parse_lines rest (zero_count + 1) non_zero_count
          else
            parse_lines rest zero_count (non_zero_count + 1)
        with Not_found ->
          (* Pattern not found in this line, continue *)
          parse_lines rest zero_count non_zero_count
        | _ ->
          (* Other error (e.g., float parsing), skip line *)
          parse_lines rest zero_count non_zero_count
  in
  parse_lines lines 0 0

(* Monitor process output and collect samples *)
let monitor_process handle duration =
  let start_time = Unix.gettimeofday () in
  let buffer = Buffer.create 4096 in
  
  let rec monitor_loop () =
    let elapsed = Unix.gettimeofday () -. start_time in
    if elapsed >= duration then
      Buffer.contents buffer
    else begin
      begin match read_nonblocking handle.stdout_fd 4096 with
      | Some data ->
          Buffer.add_string buffer data;
          (* Print output in real-time for visibility *)
          print_string data;
          flush stdout
      | None -> ()
      end;
      
      Unix.sleepf 0.1;
      monitor_loop ()
    end
  in
  monitor_loop ()

(* Run the complete test *)
let run_test () =
  printf "%s\n" (Color.bold "═══════════════════════════════════════════════════");
  printf "%s\n" (Color.bold "  AudioTrace Silence Issue Test Harness (OCaml)");
  printf "%s\n" (Color.bold "═══════════════════════════════════════════════════");
  printf "\n";
  
  (* Step 1: Start AudioTrace *)
  printf "%s Starting AudioTrace...\n" (Color.blue "▶");
  
  match start_process 
    ~name:"AudioTrace" 
    ~cmd:audio_trace_path 
    ~args:[| audio_trace_path |] with
  | Error msg ->
      Failure msg
  | Ok audio_handle ->
      Unix.sleepf 2.0; (* Give it time to initialize *)
      
      (* Step 2: Generate and play continuous sine wave *)
      printf "%s Playing %.0f Hz sine wave for %.0f seconds...\n" 
        (Color.blue "🔊") test_frequency (test_duration +. 5.0);
      
      (* Generate a WAV file slightly longer than the test duration *)
      let audio_result = Audio_generator.play_test_tone 
        ~frequency:test_frequency 
        ~duration:(test_duration +. 5.0)  (* Play 5 seconds longer than test *)
        ~temp_file:temp_wav_file in
      
      let audio_cleanup = match audio_result with
      | Error msg -> 
          printf "%s Warning: Could not start audio: %s\n" 
            (Color.yellow "⚠") msg;
          None
      | Ok handle ->
          Unix.sleepf 0.5;  (* Let audio start playing *)
          Some handle
      in
      
      (* Step 3: Monitor for duration *)
      printf "%s Monitoring AudioTrace output for %.0f seconds...\n" 
        (Color.blue "⏱") test_duration;
      let output = monitor_process audio_handle test_duration in
      
      (* Step 4: Kill AudioTrace *)
      printf "\n%s Test duration elapsed, stopping AudioTrace...\n" 
        (Color.yellow "⏹");
      kill_process audio_handle;
      
      (* Clean up audio *)
      begin match audio_cleanup with
      | Some handle -> Audio_generator.cleanup handle
      | None -> ()
      end;
      
      (* Step 5: Analyze results *)
      printf "\n%s Analyzing captured data...\n" (Color.blue "🔍");
      let (zero_samples, non_zero_samples) = parse_rms_samples output in
      
      printf "  • Total RMS samples found: %d\n" (zero_samples + non_zero_samples);
      printf "  • Zero RMS samples: %s\n" 
        (Color.yellow (string_of_int zero_samples));
      printf "  • Non-zero RMS samples: %s\n" 
        (Color.green (string_of_int non_zero_samples));
      printf "\n";
      
      (* Step 6: Determine test outcome *)
      if zero_samples = 0 && non_zero_samples = 0 then
        Inconclusive "No RMS samples found in output. AudioTrace may not have started properly."
      else if non_zero_samples > 0 then
        Failure (sprintf "AudioTrace captured %d non-zero audio samples. The silence bug appears to be FIXED!" non_zero_samples)
      else
        Success { zero_samples; non_zero_samples }

(* Print final test result *)
let print_result = function
  | Success { zero_samples; _ } ->
      printf "%s\n" (Color.bold "═══════════════════════════════════════════════════");
      printf "%s %s\n" 
        (Color.green "✓") 
        (Color.green (Color.bold "SILENCE BUG REPRODUCED SUCCESSFULLY"));
      printf "%s\n" (Color.bold "═══════════════════════════════════════════════════");
      printf "\n";
      printf "The test confirms the silence issue:\n";
      printf "  • AudioTrace captured %d RMS samples\n" zero_samples;
      printf "  • All samples were 0.0000... (complete silence)\n";
      printf "  • Audio was played during capture\n";
      printf "  • %s\n" 
        (Color.yellow "This demonstrates that AudioTrace is not capturing actual audio data.");
      printf "\n";
      exit 0
      
  | Failure msg ->
      printf "%s\n" (Color.bold "═══════════════════════════════════════════════════");
      printf "%s %s\n" 
        (Color.red "✗") 
        (Color.red (Color.bold "TEST FAILED"));
      printf "%s\n" (Color.bold "═══════════════════════════════════════════════════");
      printf "\n%s\n\n" msg;
      exit 1
      
  | Inconclusive msg ->
      printf "%s\n" (Color.bold "═══════════════════════════════════════════════════");
      printf "%s %s\n" 
        (Color.yellow "?") 
        (Color.yellow (Color.bold "TEST INCONCLUSIVE"));
      printf "%s\n" (Color.bold "═══════════════════════════════════════════════════");
      printf "\n%s\n\n" msg;
      exit 2

(* Entry point *)
let () =
  (* Verify AudioTrace binary exists *)
  if not (Sys.file_exists audio_trace_path) then begin
    printf "%s AudioTrace binary not found at: %s\n" 
      (Color.red "✗") audio_trace_path;
    printf "Please build AudioTrace first: ./build.sh\n";
    exit 1
  end;
  
  (* Run the test and print results *)
  let result = run_test () in
  print_result result
