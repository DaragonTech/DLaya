# DLaya

Delphi and Free Pascal binding for **Laya**, the open typed-decision model, running in-process
through the LibLayaX library (`laya.dll` / `liblaya.so` / `liblaya.dylib`, built from
[laya.cpp](https://github.com/lkarlslund/laya.cpp)). No server, no HTTP: your program loads the
model and asks it yes/no, multiple-choice and score questions about a piece of text.

| File | What it is |
|---|---|
| `Laya.pas` | The binding: raw imports of the 10 C functions plus the `TLayaAgent` class. One unit, no other unit of this project needed. |
| `LayaTokenizer.pas` | The model's tokenizer in Pascal: counts the tokens of a text without the library and without loading the model. |
| `LayaContext.pas` | Tells whether a question fits the model's limits before it is asked. |
| `LayaUnicode.pas` | Unicode tables and normalization for the tokenizer. |
| `LayaArchive.pas` | Reads the files of a model out of a `.tar` archive. Used by the tokenizer. |
| `LayaCodecExample.pas` | A codec for the weights in a unit of its own: the frame of one, without a transform. |
| `LayaTests.dpr` | Console test and demo program for `Laya.pas`. Start here. |
| `LayaTestsEx.dpr` | Console test for models in a `.tar` file and for codecs; not needed otherwise. |
| `LayaTokenizerTests.dpr`, `LayaContextTests.dpr` | Console tests for the tokenizer units. |
| `testdata/` | Tokenizer fixtures used by `LayaTokenizerTests`. |
| `LICENSE`, `NOTICE` | MIT, and the notices of the work the units build on. |

This repository contains only Pascal source. The native library and the model weights come
from elsewhere (see below).

> **64-bit only.** The LibLayaX library exists for 64-bit targets only, so a program that uses
> DLaya must be built as 64-bit. A new Delphi project starts with the 32-bit Windows platform
> selected; change it before compiling, as described under
> [Quick start](#quick-start). If you forget, `Laya.pas` stops the compiler with a message
> that says so. The three tokenizer units do not use the library and compile for any target.

## What you need

1. **The native library**, C API version 1 (`laya.dll` 1.0.5 or later), next to your `.exe`:

   | Your target | Library to ship |
   |---|---|
   | Windows 64-bit, PC with AVX2 (Intel 2013+, AMD Zen+) | `laya-windows-…-avx2` |
   | Windows 64-bit, any x86-64 CPU, or running on Windows on ARM under emulation | `laya-windows-…-compat-sse42` |
   | Windows 64-bit with a GPU (Vulkan) | `laya-windows-…-vulkan` |
   | macOS (Apple Silicon or Intel) | `liblaya.dylib` from `laya-macos-…` |
   | Linux x86-64 / ARM64 | `liblaya.so` from `laya-linux-…` |

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
  constructor Create(const ModelDir: string; const OptionsJson: string = ''); overload;
  constructor Create(const ModelDir, OptionsJson: string;
    AOnLibraryLoaded: TLayaLibraryLoadedProc); overload;      // see "Loading the library"
  function Predict(const RequestJson: string): string;      // raises ELaya on error
  function TryPredict(const RequestJson: string): string;   // returns {"error":"..."} instead
  function Prepare(const RequestJson: string): string;      // tokenized inputs, for debugging
  function Info: string;                                    // backend, device, model, limits
  function AskYesNo(const State, Instructions: string; const Id: string = 'q'): string;
  function AskChoice(const State, Instructions: string; const Options: array of string;
    const Id: string = 'q'): string;
  function AskScore(const State, Instructions: string; const Levels: array of string;
    const Id: string = 'q'): string;
  function AskChoiceB(const State, Instructions, DefaultOption: string;
    const Options: array of string; const Id: string = 'q'): Boolean;   // two options, as a Boolean
  property Handle: PLayaAgent;                              // for the raw laya_* functions
end;

function LayaVersion: string;                   // e.g. 'laya_c 1.0.14 (api 1; backends: cpu)'
function LayaQuote(const S: string): string;    // S as a JSON string literal, quotes included
```

Every method but `AskChoiceB` returns the complete response as a JSON string:

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

**`AskChoiceB`** asks a choice between exactly two options and returns it as a Boolean: `True`
when the model picked `Options[0]`, `False` when it picked `Options[1]`. `DefaultOption` must be
one of the two and decides when the answer names neither. Wrong arguments raise `ELaya`.

```pascal
if Agent.AskChoiceB(Text, 'Is this a real finding?', 'no', ['yes', 'no']) then ...
```

### Loading the library

With Delphi 2010 or later on Windows the imports are delay-loaded: `laya.dll` is loaded on the
first call into it, not when the program starts. A program therefore starts without the DLL, and
if the DLL, one of the DLLs it depends on, or one of its exports is missing, that first call
raises `ELaya` with a message that names what is missing. With Free Pascal, and with Delphi on
other systems, the library is bound when the program starts.

The second constructor takes a hook, a plain `procedure`, that runs after the library is in the
process and before the first call into it. It is meant for code that has to inspect or patch the
imports of `laya.dll` and of the DLLs loaded with it before the library does anything:

```pascal
procedure RefreshMyHooks;
begin
  // laya.dll is loaded here; nothing in it has run yet
end;

Agent := TLayaAgent.Create('C:\models\laya', '{"backend":"cpu"}', RefreshMyHooks);
```

`LayaCodecSupported` and `LayaSetCodec` (see the section on codecs) also load the library
when it is not in the process yet, and `LayaSetCodec` calls into it: used before the agent is
created, that call comes before the hook. It only stores two pointers.

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

## Checking that a question fits

The model reads a limited number of tokens per question: the question, its options and the
text together. The English model takes 512, the multilingual one 1024. A longer request is
refused by the library with an error. `LayaTokenizer.pas` and
`LayaContext.pas` let a program know before it calls the model, for example to shorten or
split a text.

They need neither the library nor a loaded model, only the `tokenizer` folder of the model
(a few megabytes for the English model, which loads in about 50 ms).

```pascal
uses Laya, LayaTokenizer, LayaContext;

var
  Tokenizer: TLayaTokenizer;
  Budget: TLayaContextBudget;
begin
  Tokenizer := TLayaTokenizer.Create;
  Tokenizer.LoadFromModelDir('C:\models\laya');     // the same folder TLayaAgent gets

  Budget := LayaGetContextBudget(Tokenizer,
    LayaYesNoQuestion(Text, 'Does the customer ask for a refund?'));

  if Budget.Fits then
    Answer := Agent.AskYesNo(Text, 'Does the customer ask for a refund?')
  else
    Writeln(Budget.Message);   // Question 'q' exceeds state context limit (482 tokens)
end;
```

`LayaYesNoQuestion`, `LayaChoiceQuestion` and `LayaScoreQuestion` take the same arguments as
`AskYesNo`, `AskChoice` and `AskScore`. The result:

| Field | Meaning |
|---|---|
| `Fits` | The library will accept this question. |
| `Status` | `lbsFits`, or which limit was hit; `LayaBudgetStatusToString` gives it as text. |
| `Message` | The error the library would return, word for word; empty if it fits. |
| `StateTokens` | Tokens of the text. |
| `AvailableStateTokens` | Room for the text with this question and these options. |
| `RemainingTokens` | Room left after the text; negative means too long by that many tokens. |
| `PromptTokens` | The whole input. This is the `usage.input_tokens` of the answer. |
| `HeadingTokens`, `OptionTokens`, `HeadTokens` | The question, the options, and both together (at most `HeadMaxLen`). |
| `Truncated` | Only with `AllowTruncation`: something had to be cut. |
| `Ids` | The token ids of the whole input, when it fits. |

What can be wrong, in the order the library checks it:

| `Status` | Cause |
|---|---|
| `lbsOptionCount` | Fewer than 2 or more than 255 options. |
| `lbsOptionTooLong` | One option is longer than 48 tokens. |
| `lbsOptionBudgetExceeded` | So many or such long options that the question's own budget does not hold them. |
| `lbsHeadingTooLong` | The instructions are too long for what the options leave. |
| `lbsHeadBudgetExceeded` | Instructions and options together exceed the question's budget (`HeadMaxLen`). |
| `lbsStateExceedsContext` | The text is longer than the room left for it. This is the usual one. |
| `lbsSequenceLimit` | The whole input exceeds the model's limit (`ContextSize`). |

Things to know:

* **Counting only.** `Tokenizer.CountTokens(Text)` gives the tokens of a text, and
  `Tokenizer.Encode(Text)` the token ids.
* **More settings.** The functions above return a `TLayaContextBudgetSettings` record that
  can be changed before it is passed on: `Descriptions` (what each option of a choice
  means), `TrueMeaning` and `FalseMeaning` (for yes/no), `QuestionId`, and `AllowTruncation`
  for a model loaded with `"allow_truncation":true`.
* **Several questions about one text.** Each question is a separate input with the whole
  text in it, so check each question on its own.
* **Other models.** Give the folder of the model itself, for example
  `C:\models\laya\multilingual`. Both tokenizer kinds of the engine are supported.
* **The limits come from the model.** They are read from `rl_agent_config.json` and are in
  `Tokenizer.MaxLen` and `Tokenizer.HeadMaxLen`: 512 and 192 for the English model, 1024 and
  256 for the multilingual one. One option may take 48 tokens in every model.
* **Threads.** A loaded tokenizer only reads; several threads can use one.
* **Long texts.** A megabyte of text is tokenized in a fraction of a second, also in scripts
  that write without spaces.
* **Same result as the library.** The units classify and normalize characters with tables
  generated from the ICU version inside the released libraries (ICU 76.1, Unicode 16.0),
  and use neither a regular expression library nor operating system calls for it, so the
  result does not depend on the platform or the compiler.
* **The text must be a string.** A request whose `state` is a JSON object is not covered.

## A model in one file, and a codec for the weights

From version 1.0.15 every LibLayaX library can read a model in two more ways than from a plain
folder. `LayaCodecSupported` tells whether the library your program loaded can: it is `False`
for a library older than 1.0.15, and with one of those everything else in this binding works
as before.

**A model in one `.tar` file.** Give the path of the archive where you would give the folder.
The archive is an uncompressed tar of the model's files, at its top or inside one folder
(`tar -cf laya.tar -C C:\models\laya .`).

```pascal
Agent := TLayaAgent.Create('C:\models\laya.tar', '{"backend":"cpu"}');
Tokenizer.LoadFromModelDir('C:\models\laya.tar');   // the tokenizer units read it too
```

The tokenizer units do not use the library, so they read the archive themselves, through
`LayaArchive.pas`, and work with any library and on any platform. `LoadFromArchive(FileName,
'multilingual')` selects one model of an archive that holds several.

**A codec for the weights.** A codec is a function that decodes the stored bytes of
`model.safetensors` while the library reads it, so that the weight file on disk can be kept in
another form than the plain one. It applies to the weight file only, in a folder and in a
`.tar` file alike; the tokenizer and the configuration files are never passed to it.

```pascal
function MyDecode(User: Pointer; Path, FileName: PAnsiChar; Offset: UInt64; Data: Pointer;
  Size: UInt64): Integer; cdecl;
begin
  // turn the Size stored bytes at Data into the plain ones;
  // Offset is where they begin in the weight file
  Result := 0;   // anything else stops the load
end;

if LayaCodecSupported then
  LayaSetCodec(MyDecode);
Agent := TLayaAgent.Create('C:\models\laya.tar');
```

`Path` is the file on disk the block came from, as a full UTF-8 path: the `.tar` file, or
`model.safetensors` in the model folder. A codec that keeps a file of its own beside the model
finds the folder with `ExtractFilePath(UTF8ToString(Path))`.

The decoded data has the same length as the stored data, and the function must be able to
decode any block from its offset alone: the library asks for about 200 blocks per load, in any
order. `LayaSetCodec(nil)` removes the codec.

`LayaCodecExample.pas` is such a function in a unit of its own, ready to copy. It shows the
signature, how the codec is given to the library and taken away again, how the model's folder
is found from `Path` on the first call, how a failure is reported without letting an exception
leave the function, and where the transform goes. The example has no transform: it leaves the
data as it is and records what the library passed to it, so it runs with any plain model.
`LayaTestsEx` uses it.

```pascal
uses Laya, LayaCodecExample;

LayaExampleCodecInstall;
try
  Agent := TLayaAgent.Create('C:\models\laya.tar');
finally
  LayaExampleCodecRemove;
end;
Writeln(LayaExampleCodecState.Calls, ' blocks from ', LayaExampleCodecState.Path);
```

The manual page `docs/model-files.md` of LibLayaX has the full description and the messages.

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
LayaTests.exe                       model-free checks only (6 checks)
LayaTests.exe C:\models\laya        full run on the CPU (23 checks)
LayaTests.exe C:\models\laya vulkan full run on another backend
```

Exit code 0 means everything passed. The full run covers all three question types,
`AskChoiceB`, the library-loaded hook, JSON escaping and Unicode, error reporting, `Prepare`,
three threads sharing one agent, and that the host's floating-point settings (MXCSR) come back
unchanged.

Building it:

```
dcc64 LayaTests.dpr                 Delphi, Windows 64-bit
fpc LayaTests.dpr                   Free Pascal (also Linux and macOS)
```

Models in a `.tar` file and codecs have a test program of their own, so that `LayaTests`
stays the plain example. It needs LibLayaX 1.0.15 or later; with an older library it says so
and stops (exit code 2).

```
LayaTestsEx.exe                         the one check that needs no model
LayaTestsEx.exe C:\models\laya.tar      a model in a .tar file, and the codec (8 checks)
LayaTestsEx.exe C:\models\laya          the codec with a model folder (8 checks)
```

It asks one question without a codec and again through the codec of `LayaCodecExample.pas`,
which must give the same answer, and checks what the codec was told: the file's path and name,
and that exactly the bytes of the weight file went through it.

The tokenizer units have two test programs of their own, built the same way:

```
LayaTokenizerTests.exe                  checks that need no model (42 checks)
LayaTokenizerTests.exe C:\models\laya   the tokenizer of that model (76 checks)
LayaContextTests.exe C:\models\laya     the units against the library itself
```

`LayaTokenizerTests` does not need the library. With a model folder it loads the tokenizer
and runs the fixtures in `testdata/`: 253 texts for the English model and 270 for the
multilingual one, each with the token ids the model's own tokenizer gives it. Keep the
`testdata` folder next to the program or in the current folder.

`LayaContextTests` needs `laya.dll` and the model. It makes up 1000 questions of every kind
and size, many of them too long on purpose, and compares what `LayaContext.pas` says with
what the library prepares for the same request: the token ids must be identical, and where
the library refuses, the message must be the same. It does this with and without
`allow_truncation`, and checks `usage.input_tokens` of three real answers. A second argument
sets the number of questions, a third the backend.

## Status

Tested with LibLayaX 1.0.14 and the real english model unless a row says otherwise.
`LayaTests` passed its 15 checks of that time with 0 failures in every row.

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
* **The tokenizer units** (`LayaTokenizer.pas`, `LayaContext.pas`, `LayaUnicode.pas`) were
  compiled and tested with Free Pascal 3.2.2 for Linux x86-64 and for Win64. They have not
  yet been compiled with Delphi. What was checked:
  * the 253 English and 270 multilingual fixtures of laya.cpp pass;
  * the token ids are identical to those of the engine's own tokenizer on 332,695 texts, for
    both tokenizer kinds; the texts include every assigned Unicode character in several
    contexts;
  * normalization is identical to ICU on 1.9 million inputs, the Unicode conformance file
    among them;
  * `LayaContext.pas` agrees with LibLayaX 1.0.14 on 47,464 generated questions for the
    English tokenizer and 11,854 for the multilingual one: the same token ids, and the same
    error message for every refused one. Run against the Linux library, and against the
    Windows DLL under Wine.

  Those runs were made on the build machine with tokenizer files rebuilt from public
  sources. Both test programs were then run on Windows x64 against the downloaded models,
  with LibLayaX 1.0.14 on the CPU:

  | Model | `LayaTokenizerTests` | `LayaContextTests` |
  |---|---|---|
  | English | 50 checks, 253 of 253 fixtures | 6680 checks |
  | Multilingual | 49 checks, 270 of 270 fixtures | 6768 checks |

  No failures. `LayaContextTests` also loads the model in the library and asks three real
  questions, so the multilingual model has now run through `Laya.pas` as well.
* **`.tar` models and codecs** (`LayaArchive.pas`, `.tar` support in the tokenizer,
  `LayaCodecSupported`, `LayaSetCodec`, `LayaCodecExample.pas`) were tested with Free Pascal
  3.2.2 on the build machine, with a test model and LibLayaX 1.0.15, on the CPU:
  * `LayaTokenizerTests`: 42 checks without a model; 76 with the English tokenizer and 75 with
    the multilingual one from a folder; 72 from a `.tar` file. Linux x86-64, and Win64 under
    Wine. The checks write archives of every kind the reader accepts and compare the tokenizer
    loaded from them with the one loaded from the folder.
  * `LayaTestsEx`: 8 checks, 0 failures, from a folder and from a `.tar` file, on Linux x86-64
    and on Win64 under Wine. With a 1.0.14 library it reports that the library is too old.
  * `LayaTests`: 23 checks, 0 failures, on both.

  With Delphi, `LayaSetCodec` has been used from a Windows program with the 1.0.15 library.
  The other parts have not been compiled with Delphi yet.
* **Delay-loading, the library-loaded hook and `AskChoiceB`.** Free Pascal has no delay-loading,
  so the delay-loaded imports, the message for a missing DLL and the hook's Delphi path have
  not been compiled or run here; that code is taken unchanged from a version of this unit that
  was in use with Delphi. `AskChoiceB` and the hook's other path are covered by `LayaTests`
  with Free Pascal (Linux, and Win64 under Wine).
  * `LayaContextTests` with a `.tar` file for both the units and the library: 2006 checks,
    0 failures.
* macOS: the unit selects `liblaya.dylib` (install name `@rpath/liblaya.dylib`; deploy it to
  `Contents/MacOS`). Not yet run from Pascal on a Mac.
* The typed-decisions model variant has not been exercised through the binding.

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

`Laya.pas` contains no code from the projects it builds on. `LayaTokenizer.pas` and
`LayaContext.pas` are Pascal versions of the tokenizer and the request preparation of
laya.cpp (MIT, Lars Karlslund), and the fixtures in `testdata/` come from its tests. The
tables in `LayaUnicode.pas` derive from the Unicode Character Database (Unicode License V3).
[NOTICE](NOTICE) has the details and the license texts.

The projects DLaya builds on keep their own terms: the LibLayaX library and laya.cpp are
MIT, Laya is Apache-2.0, and the model weights are published on Hugging Face under their own
terms.
