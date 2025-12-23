# AudioTrace Silence Issue Test Harness (OCaml)

This is a test harness written in OCaml that demonstrates and verifies the AudioTrace silence issue.

## What It Does

1. **Starts AudioTrace** - Launches the app and monitors its output
2. **Plays Audio** - Uses macOS `say` command to generate audio
3. **Monitors for 30 seconds** - Captures all RMS values from AudioTrace output
4. **Analyzes Results** - Counts zero vs non-zero RMS samples
5. **Reports Findings** - Confirms whether the silence bug is present

## OCaml Learning Points

This test harness demonstrates several OCaml concepts:

- **Result types**: Explicit error handling with `Result.t`
- **Pattern matching**: Comprehensive matching on variants
- **Records**: Structured data with `process_handle` and `test_result`
- **Modules**: Organization with the `Color` module
- **Unix module**: Process management and IPC
- **Recursion**: Tail-recursive monitoring loop
- **String processing**: Regex matching with `Str` module
- **Option types**: Handling `Some`/`None` for non-blocking reads

## Building

```bash
cd test_harness
dune build
```

## Running

```bash
# Run the compiled executable
dune exec ./test_silence_issue.exe

# Or run directly
./_build/default/test_silence_issue.exe
```

## Expected Output

```
═══════════════════════════════════════════════════
  AudioTrace Silence Issue Test Harness (OCaml)
═══════════════════════════════════════════════════

▶ Starting AudioTrace...
🔊 Playing audio: "Testing audio capture..."
⏱ Monitoring AudioTrace output for 30 seconds...

[AudioTrace output appears here in real-time]

⏹ Test duration elapsed, stopping AudioTrace...

🔍 Analyzing captured data...
  • Total RMS samples found: 143
  • Zero RMS samples: 143
  • Non-zero RMS samples: 0

═══════════════════════════════════════════════════
✓ SILENCE BUG REPRODUCED SUCCESSFULLY
═══════════════════════════════════════════════════

The test confirms the silence issue:
  • AudioTrace captured 143 RMS samples
  • All samples were 0.0000... (complete silence)
  • Audio was played during capture
  • This demonstrates that AudioTrace is not capturing actual audio data.
```

## Exit Codes

- `0` - Success: Silence bug reproduced (all RMS values were 0)
- `1` - Failure: Non-zero audio detected (bug is fixed!)
- `2` - Inconclusive: Could not determine (e.g., AudioTrace didn't start)

## Why OCaml?

This harness uses OCaml to provide:

1. **Strong typing** - Catch errors at compile time
2. **Explicit error handling** - Result types make error paths visible
3. **Pattern matching** - Clear, exhaustive case handling
4. **Immutability** - Fewer bugs from unexpected state changes
5. **Functional style** - Clean, composable code

Great for learning OCaml before contributing to large OCaml codebases!
