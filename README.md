# DLaya

Delphi and Free Pascal binding for **Laya**, the open typed-decision model, running in-process
through the LibLayaX library (`laya.dll` / `liblaya.so` / `liblaya.dylib`, built from
[laya.cpp](https://github.com/lkarlslund/laya.cpp)). No server, no HTTP: your program loads the
model and asks it yes/no, multiple-choice and score questions about a piece of text.

| File | What it is |
|---|---|
| `Laya.pas` | The binding: raw imports of the 10 C functions plus the `TLayaAgent` class. One unit, no dependencies beyond `SysUtils`. |
| `LayaTests.dpr` | Console test and demo program for the unit. |
| `LICENSE` | MIT. |

This repository contains only Pascal source. The native library and the model weights come
from elsewhere (see below).

> **64-bit only.** The LibLayaX library exists for 64-bit targets only, so a program that uses
> DLaya must be built as 64-bit. A new Delphi project starts with the 32-bit Windows platform
> selected; change it before compiling, as described under
> [Quick start](#quick-start). If you forget, `Laya.pas` stops the compiler with a message
> that says so.

## What you need

1. **The native library**, C API version 1 (`laya.dll` 1.0.5 or later), next to your `.exe`:

   | Your target | Library to ship |
   |---|---|
   | Windows 64-bit, PC with AVX2 (Intel 2013+, AMD Zen+) | `laya-windows-…-avx2` |
   | Windows 64-bit, any x86-64 CPU, or running on Windows on ARM under emulation | `laya-windows-…-compat-sse42` |
   | Windows 64-bit with a GPU (Vulkan) | `laya-windows-…-vulkan` |
   | macOS (Apple Silicon or Intel) | `liblaya.dylib` from `laya-macos-…` |
   | Linux x86-64 / ARM64 | `liblaya.so` from `laya-linux-…` |

   Download the native library from the [LibLayaX repository](https://github.com/DaragonTech/LibLayaX/releases/tag/v1.0.14)

   The library is 64-bit only; a Win32 target cannot load it. The native Windows ARM64 DLL
   (`laya-windows-arm64`) is for native ARM64 programs and cannot be loaded by a Delphi Win64
   application, which is x64 even when Windows runs on ARM.

2. **The model weights** (about 800 MB for the english variant), from the Hugging Face
   repository [convaiinnovations/laya](https://huggingface.co/convaiinnovations/laya). With the
   Hugging Face command-line tool:

   ```
   pip install huggingface_hub
   huggingface-cli download convaiinnovations/laya --local-dir /models/laya \
       --include "model.safetensors" "rl_agent_config.json" "encoder/*" "tokenizer/*"
   ```

   The folder you pass to `TLayaAgent.Create` is the one that contains `rl_agent_config.json`. The LibLayaX
   README ("Getting the model") lists the files needed, the other ways to download them, and how
   to get the multilingual and typed-decisions variants.

## Quick start

1. Add `Laya.pas` to your project.
2. **Switch the project to 64-bit.** When Delphi opens a `.dpr` or creates a new project, it
   makes a `.dproj` whose only platform is 32-bit Windows. In the Project Manager, right-click
   **Target Platforms**, choose **Add Platform…**, select **64-bit Windows** and confirm. It
   becomes the active platform (shown in bold); if it is already listed, double-click it.
   This applies to `LayaTests.dpr` too.
3. Put `laya.dll` next to the executable. With the 64-bit platform Delphi writes the `.exe`
   to `Win64\Debug` or `Win64\Release`, so that is where the DLL goes.

On the command line, `dcc64` is the 64-bit compiler; `dcc32` will not work.

What happens with a 32-bit target: `Laya.pas` refuses to compile, with the message
*"Laya.pas needs a 64-bit target: the LibLayaX library is 64-bit only…"*. Without that check
the program would compile and then fail to start with error `0xc000007b`, because a 32-bit
program cannot load a 64-bit DLL. There is no 32-bit build of the library at present.

```pascal
uses Laya, System.JSON;

var
  Agent: TLayaAgent;
  Resp: TJSONValue;
begin
  // Load once (a few seconds, about 1.7 GB of RAM on CPU) and keep it for the app's lifetime.
  Agent := TLayaAgent.Create('C:\models\laya', '{"backend":"cpu"}');
  try
    Resp := TJSONObject.ParseJSONValue(
      Agent.AskYesNo('Please refund the duplicate charge.',
                     'Does the customer ask for a refund?', 'refund'));
    try
      Writeln('P(yes) = ', Resp.GetValue<Double>('results[0].answers.refund.noul'):0:4);
    finally
      Resp.Free;
    end;

    // Choice and score questions:
    Agent.AskChoice('I want to cancel my subscription.', 'What does the customer want?',
      ['cancel', 'upgrade', 'refund'], 'intent');   // answers.intent.choice / .probabilities
    Agent.AskScore('Third time I am writing!!!', 'How angry is the customer?',
      ['calm', 'annoyed', 'furious'], 'anger');     // answers.anger.score / .probabilities

    // Anything the JSON protocol supports: several questions, several texts in one call.
    Agent.Predict('[{"state":"...","questions":{...}}, {"state":"...","questions":{...}}]');
  finally
    Agent.Free;
  end;
end;
```

## The unit

```pascal
TLayaAgent = class
  constructor Create(const ModelDir: string; const OptionsJson: string = '');
  function Predict(const RequestJson: string): string;      // raises ELaya on error
  function TryPredict(const RequestJson: string): string;   // returns {"error":"..."} instead
  function Prepare(const RequestJson: string): string;      // tokenized inputs, for debugging
  function Info: string;                                    // backend, device, model, limits
  function AskYesNo(const State, Instructions: string; const Id: string = 'q'): string;
  function AskChoice(const State, Instructions: string; const Options: array of string;
    const Id: string = 'q'): string;
  function AskScore(const State, Instructions: string; const Levels: array of string;
    const Id: string = 'q'): string;
  property Handle: PLayaAgent;                              // for the raw laya_* functions
end;

function LayaVersion: string;                   // e.g. 'laya_c 1.0.14 (api 1; backends: cpu)'
function LayaQuote(const S: string): string;    // S as a JSON string literal, quotes included
```

Every method returns the complete response as a JSON string:

```json
{"results":[{"model":"laya-rl-agent",
             "answers":{"refund":{"type":"noul","confidence":0.8364,
                                  "action":{"act_probability":1.0},"noul":0.8364}},
             "usage":{"input_tokens":40,"output_tokens":0}}],
 "elapsed_ms":244.9,"backend":"CPU","device":"..."}
```

**Options** (second argument of `Create`, a JSON object; unknown keys are rejected):

| Key | Values | Default |
|---|---|---|
| `backend` | `"cpu"`, `"vulkan"`, `"cuda"` (must be compiled into the library you ship) | `"cpu"` |
| `variant` | `"english"`, `"multilingual"`, `"typed-decisions"`: picks a subfolder of a model store | folder as given |
| `precision` | `"fp32"`, `"fp16"`, `"bf16"` (the half precisions need a GPU) | `"fp32"` |
| `threads` | CPU threads, 0 = all | 0 |
| `device` | GPU index, or part of its name such as `"RTX"` | first discrete GPU |
| `flash` | boolean, fused attention (GPU) | on for `fp16`/`bf16`, otherwise off |
| `tensor_core`, `allow_truncation` | booleans | off |

The raw functions (`laya_create`, `laya_predict`, `laya_free_string`, …) are declared in the
same unit for anyone who prefers them; `laya_c.h` in the C API source is the full contract.

### Running on the GPU

Ship the `laya.dll` from the `vulkan` package and ask for the GPU when creating the agent:

```pascal
Agent := TLayaAgent.Create('C:\models\laya', '{"backend":"vulkan","precision":"fp16"}');
```

The same DLL also runs on the CPU, so a program can fall back when `Create` raises `ELaya` on
a machine without a usable GPU. Two things to expect, measured with `LayaTests` built with
Delphi 10.2 on an RTX 5080 Laptop GPU:

* **The first questions on the GPU are slow.** The three questions of the test took 1127 ms,
  509 ms and 15 ms, in that order; on the CPU each takes about 85 to 110 ms. The GPU needs a
  few calls of one-time setup after the model is loaded.
* **A GPU pays off with batches.** Send several requests in one `Predict` (a JSON array).
  The half precisions (`fp16`, `bf16`) are the fast ones; the test itself runs at full
  precision.

## Things worth knowing

* **Errors.** `Create` and `Predict` raise `ELaya` (bad path, malformed JSON, unknown question
  type, text too long). A failed request leaves the agent usable.
* **Threads.** One `TLayaAgent` can be shared between threads; the library serializes calls on
  it. For throughput, send an array of requests in one `Predict` rather than calling from many
  threads. In a VCL or FMX application, create the agent and call it from a background thread
  (`TTask.Run`) so the UI does not freeze while the model loads.
* **Floating-point exceptions.** Delphi unmasks them and the engine's arithmetic would trip
  over that; the library masks them for the duration of each call and restores your settings
  on return. No `SetExceptionMask` needed.
* **Strings.** Everything crosses the boundary as UTF-8 JSON; the unit converts to and from
  Delphi strings. Non-ASCII model paths and texts work.
* **Memory.** About 1.7 GB per loaded model on CPU. Create one agent per model and keep it.

## Running the tests

```
LayaTests.exe                       model-free checks only (5 checks)
LayaTests.exe C:\models\laya        full run on the CPU (15 checks)
LayaTests.exe C:\models\laya vulkan full run on another backend
```

Exit code 0 means everything passed. The full run covers all three question types, JSON
escaping and Unicode, error reporting, `Prepare`, three threads sharing one agent, and that
the host's floating-point settings (MXCSR) come back unchanged.

Building it:

```
dcc64 LayaTests.dpr                 Delphi, Windows 64-bit
fpc LayaTests.dpr                   Free Pascal (also Linux and macOS)
```

## Status

Tested with LibLayaX 1.0.14 and the real english model unless a row says otherwise.
`LayaTests` passes 15 checks with 0 failures in every row.

| Compiler | System | Backend |
|---|---|---|
| **Delphi 10.2 Tokyo** (Win64) | Windows 11 x64, Intel Core Ultra 9 275HX | CPU |
| **Delphi 10.2 Tokyo** (Win64) | Windows 11 x64, NVIDIA RTX 5080 Laptop GPU | GPU (`vulkan`) |
| Free Pascal 3.2.2 | Windows 11 x64, Intel Core Ultra 9 275HX | CPU |
| Free Pascal 3.2.2 | Windows 11 on ARM, x64 emulation | CPU |
| Free Pascal 3.2.2 | Linux x86-64, synthetic test model | CPU |

* The unit and the test program compile with Delphi 10.2 without errors. Other Delphi
  versions have not been tried.
* The answers are the reference ones on the CPU and on the GPU alike: `noul` 0.8364 for the
  refund example, `cancel` at 0.9649, score 0.8568.
* The host's floating-point settings come back unchanged in the Delphi build (`MXCSR: $1900
  -> $1900`, Delphi's default with exceptions enabled), on the CPU and on the GPU.
* macOS: the unit selects `liblaya.dylib` (install name `@rpath/liblaya.dylib`; deploy it to
  `Contents/MacOS`). Not yet run from Pascal on a Mac.
* The multilingual and typed-decisions model variants have not been exercised through the
  binding.

## Credits

* **[Laya](https://github.com/NandhaKishorM/laya)** by NandhaKishorM is the original project:
  the model, the typed-decision primitives (`choice`, `score`, `noul`) and the Python
  reference implementation on PyTorch and Transformers. Apache-2.0. The weights are published
  on Hugging Face under `convaiinnovations`.
* **[laya.cpp](https://github.com/lkarlslund/laya.cpp)** by Lars Karlslund is the native C++
  port of Laya inference, built on ggml, with CPU, CUDA, Vulkan and Core ML backends. MIT.
  The native library DLaya loads is built from it.
* **DLaya** and the LibLayaX library underneath it were written by Claude (Anthropic),
  under the direction of **Felipe Daragon** of **DaragonTech**, who set the goals, guided the
  work, compiled the unit with Delphi and ran the tests on real hardware.

## License

DLaya is released under the MIT License; see [LICENSE](LICENSE).

It contains no code from the projects it builds on. Those keep their own terms: the LibLayaX
library and laya.cpp are MIT, Laya is Apache-2.0, and the model weights are published on
Hugging Face under their own terms.
