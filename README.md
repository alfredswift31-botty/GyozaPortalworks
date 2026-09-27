# GyozaPortalworks

To practice for a better me.

GyozaPortalworks is a macOS app for practising PLC programming the way two industry tools work: **Siemens TIA Portal** (S7-1200) and **Mitsubishi GX Works3** (MELSEC iQ-F FX5U). Both live in one window. Switch with the toolbar or ⌘1 / ⌘2; each tool keeps its own project and simulation.

> Not affiliated with or endorsed by Siemens AG or Mitsubishi Electric Corporation. TIA Portal, SIMATIC and STEP 7 are trademarks of Siemens AG; MELSEC and GX Works are trademarks of Mitsubishi Electric Corporation. This is a practice environment. It mirrors the tools' workflows, languages and CPU behaviour so the habits transfer, but it is not the real software and can't program real hardware.

## TIA Portal side (CPU 1214C DC/DC/DC)
- **Project view**: project tree, Add new block (OB/FB/FC/DB), PLC tag tables (duplicate names become "Name(1)", duplicate addresses flagged), data blocks, PLC data types, watch and force tables.
- **LAD and FBD**: the networks behave the same in both views.
  - Branches (Shift+F8 / Shift+F9), contacts and coils, S/R, P/N edges.
  - IEC timers and counters with the Call options dialog (IEC_Timer_0_DB).
  - Compare, math, MOVE, CONVERT, NORM_X/SCALE_X, word logic and shifts.
  - FC/FB calls.
  - A block switches between LAD and FBD in its properties.
- **SCL**:
  - IF/CASE/FOR/WHILE/REPEAT; `#local`, `"global"` and `%absolute` operands; multi-instance timers; `"IEC_Timer_0_DB".TON(...)` calls.
  - TIA's editor auto-correction.
  - Monitoring with a value column.
- **Compile, download and simulate**:
  - Compile with Ctrl+B; messages appear in Inspector › Info › Compile.
  - Start simulation with Ctrl+Shift+X. It opens an S7-PLCSIM-style simulator, runs the Extended download → Load preview → Load results flow, and gives RUN/STOP/MRES.
  - Download changes with Ctrl+L.
- **Online and monitoring**: go online with Ctrl+K; the title bar turns orange.
  - Monitoring shows green solid lines for power flow and blue dashed for none, with values in grey boxes.
  - Modify to 1/0, watch tables with Modify now, and a force table.
- **Real S7 behaviour**:
  - Big-endian M/MW/MD overlap (%M10.0 is in the high byte of %MW10).
  - System and clock memory bits.
  - A warm restart keeps only retentive data.
  - A programming error lights ERROR but the CPU stays in RUN; the cycle watchdog stops it.

## GX Works3 side (FX5U-32MR/ES)
- **Tool layout**: Navigation, Element Selection, global and local labels, device comments, CPU parameter summary.
- **Ladder editor**: GX Works3 keys, including F5/F6/F7/F8/F9 with their Shift/Alt/Ctrl variants and Shift+Insert/Delete. Or just type: `LD X0`, `OUT T0 K50`, `MOV K10 D0` open the Ladder Input dialog.
- **Convert and check**:
  - F4 turns grey unconverted blocks white and reports conversion errors in the Output window.
  - The Conversion Result window shows the step list.
  - Program Check finds duplicate coils, MC/MCR pairs, and more.
- **ST** with devices and labels.
- **Simulation**: Start Simulation leads to Online Data Operation, then the GX Simulator3-style window (READY/ERROR/P RUN LEDs, RUN/STOP switch, RESET).
  - Monitor mode (F3) fills ON contacts and coils blue and shows timer values by the coil.
  - Shift+Enter toggles a bit; Modify Value, Watch 1–4 and the Device Batch Monitor are there too.
- **Real FX5U behaviour**:
  - Octal X/Y and SM400/SM402/SM412.
  - 100 ms / 10 ms / 1 ms timers (OUT/OUTH/OUTHS), retentive ST timers and counters.
  - MC/MCR, CJ/CALL, pulse instructions, 32-bit and float instructions.
  - Operation errors stop the CPU until RESET.

## Both tools
- **I/O Trainer** (⇧⌘T): push buttons (including normally-closed stop buttons), switches, lamps, contactors and analog sliders, wired to the simulated CPU (TIA: %I0.0–%I1.5, %Q0.0–%Q1.1, %IW64/66; GX: X0–X17, Y0–Y17, SD6020/SD6060).
- **Exercises** (⇧⌘E): ten per tool. They run from a seal-in circuit to star-delta starters, analog scaling and an SCL state machine, each with wiring, hints and a reference solution. **Check my program** runs your program in a fresh CPU in simulated time and tells you exactly which behaviour is wrong.

## Keyboard
The vendors' shortcuts are kept: Ctrl+B, Ctrl+L, Ctrl+K and Shift+F2/F3/F7 in TIA; F2, F3, F4 and F5–F10 in GX Works3. On a Mac laptop, hold **fn** for F-keys, or turn on *System Settings › Keyboard › Use F1, F2, etc. keys as standard function keys*. Every F-key action is also in the menus and toolbars.

## Install
1. Download `GyozaPortalworks.zip` from the latest [release](https://github.com/alfredswift31-botty/GyozaPortalworks/releases).
2. Unzip, and drag `GyozaPortalworks.app` to Applications.
3. The build is ad-hoc signed, not notarized. The first time, right-click the app and choose **Open**, or allow it under System Settings › Privacy & Security.

Requires macOS 15.6 or later. Projects are saved automatically in `~/Library/Containers/com.gyoza.GyozaPortalworks/Data/Library/Application Support/GyozaPortalworks`. You can export or import a project as JSON from the Project menu.

## Building
Open `GyozaPortalworks.xcodeproj` in Xcode 26 and run the `GyozaPortalworks` scheme. The unit tests use Swift Testing: about 360 of them cover the runtime, both CPUs, both languages, the editors' model logic and every exercise scenario. CI also renders the main screens off screen to prove they lay out.

## How it's built
- `Runtime/`: the shared PLC core. It holds IEC data types and values, symbolic storage, arithmetic with CPU-accurate overflow, IEC timers and counters, and the contract every language compiles against.
- `Language/`: one Structured Text engine with two dialects, TIA's SCL and GX Works3's ST. It has a lexer, parser, type checker, interpreter, standard library, monitoring trace and highlighting.
- `Siemens/`: S7-1200 memory and addressing, tags, DBs, the LAD/FBD network model and compiler, the simulated CPU and the TIA Portal workspace.
- `Melsec/`: FX5U devices, the instruction set, the ladder grid and converter, Program Check, the simulated CPU and the GX Works3 workspace.
- `Shared/` and `App/`: the window and tool switcher, I/O trainer, exercises and checker, code editor, project storage and vendor chrome.

## Limits
- Hardware and network configuration (PROFINET, HMI, motion, safety), online change, and Cross Reference aren't included.
- One CPU per tool: CPU 1214C and FX5U-32MR/ES.
- No STRING or date/time types, and arrays are one-dimensional.
- TIA: jump instructions and counter coils aren't available, and a box output can't be wired straight into another box.
- GX Works3: no Find/Replace, fold markers or long-rung wrapping.
- Where the vendor documentation couldn't be checked, the most standard behaviour was chosen, for example GX Works3 step counts and the wording of some TIA messages.
