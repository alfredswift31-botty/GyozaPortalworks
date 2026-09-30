# Development log: GyozaPortalworks

GyozaPortalworks is a Mac app for practising Siemens TIA Portal and Mitsubishi GX Works3. It was built 26–28 September 2026. This log is the hand-over: what exists, how it was built, what's verified, and what's still open.

## Releases

| Version | Date | Release | Notes |
|---|---|---|---|
| 1.0 | 2026-09-28 | [v1.0](https://github.com/alfredswift31-botty/GyozaPortalworks/releases/tag/v1.0) | First release |
| 1.0.1 | 2026-09-30 | [v1.0.1](https://github.com/alfredswift31-botty/GyozaPortalworks/releases/tag/v1.0.1) | Live TIA monitoring fix, exercise 1 hint fix |

Every release is an ad-hoc-signed `.zip` built by GitHub Actions. To install, drag the app to Applications and right-click › Open the first time.

## 1.0 (TIA Portal + GX Works3 practice)

### Scope decision
The goal was one Mac app to practise both tools' real workflows: editors, vendor keys, compile/convert, download, simulate, monitor and watch. The CPU behaviour underneath is faithful, so habits transfer. It is not a copy of either product, and there are no vendor logos. The About box and README carry trademark notices.

### How it was built
The main agent owned the architecture and the shared code. Three subagents did the rest, each in its own git worktree and branch, and CI was the only compiler: the container has no Swift toolchain.

| Part | Owner | Branch | Size |
|---|---|---|---|
| `Runtime/`: types, values, storage, IEC FBs, execution contract | main | develop | about 1.6k lines |
| `Shared/`, `App/`: shell, tool switcher, I/O Trainer, exercises and checker, code editor, project store, vendor chrome | main | develop | about 3k lines |
| `Language/`: one ST engine, two dialects (TIA SCL, GX ST) | agent 3 | `st-engine` | about 4.8k lines + 1.8k tests |
| `Melsec/`: FX5U devices, instruction set, ladder grid, converter, Program Check, CPU, GX Works3 UI | agent 2 (did the GX research first) | `melsec` | |
| `Siemens/`: S7 memory, tags, DBs, LAD/FBD network model, CPU, TIA Portal UI | agent 1 (did the TIA research first) | `siemens` | |

In total: 123 Swift files, about 39.5k lines, and 360 unit tests (Swift Testing). The latest CI run had zero warnings.

### Research
Both research reports sit in the session scratchpad; their key points shaped the briefs.
- **Siemens:** sourced from the STEP 7 V16 Information System PDF. It set TIA's operator precedence, the exact compile messages, and the S7-1200 rules: a programming error keeps the CPU in RUN, and counter IDBs are retentive.
- **Mitsubishi:** sourced from the Japanese GX Works3 operating manual. It set the keys, the octal X/Y numbering, SM400/402/412, OUT/OUTH/OUTHS resolution, and that devices are kept through STOP.

### Verification that exists
- **Engines:** every exercise, 10 per tool, runs end to end through each engine: model or editor commands, then compiler, then CPU, then `ExerciseChecker`. For GX, the converter's output is also compared with the reference instruction list.
- **Exercise scenarios:** every scenario is also checked against a known-good reference program, so a correct user program can't be marked wrong.
- **UI snapshots:** tests render the real views off screen. The workflow prints them into the CI log as base64 JPEGs between `SNAPSHOT-BEGIN/DATA/END` lines, because artifact downloads are blocked from the dev container. Reviewing them found two layout bugs, both fixed before 1.0: GX coils were off-screen, and the TIA inspector squeezed the networks.

### Not verified
Nobody has clicked through the app on a real Mac. Focus, key handling (F-keys, Ctrl combos, typing into the ladder), drag-and-drop and window behaviour are untested at runtime. They are the first thing to check.

### Known limitations (1.0)
- **Out of scope:** hardware and network configuration, HMI, motion, safety, online change and Cross Reference.
- **Data types:** no STRING or date/time types; arrays are one-dimensional.
- **TIA:**
  - no jumps or counter coils;
  - box outputs can't be wired straight into another box;
  - Close branch always joins onto the first element after the split;
  - no Cut/Copy/Paste;
  - Portal view is only a label.
- **GX Works3:**
  - no Find/Replace, fold markers, long-rung wrapping or Element Selection drag-and-drop;
  - CPU parameters are read-only;
  - GX Simulator3 is a panel, not a separate window;
  - step counts are approximated with FX3 values;
  - errors have no real error codes.
- **Undo:** it covers the whole project, and the Ctrl+Z / ⌘Z shortcuts take precedence over text-field undo.

### Suggested next steps
1. First run on a Mac. Go through each tool's exercise 1 end to end and fix whatever focus or key problems show up.
2. Run exercise checks for exercises beyond the three per tool covered in the workspace tests. The engine tests already cover all ten.
3. TIA: support wiring one box straight into another, and fix Close branch spans.
4. GX: a separate GX Simulator3 window (needs an `App/` window scene) and Element Selection drag-and-drop.
5. Add `DiagnosticEvent.code` for real error codes, if they can be sourced.

## 1.0.1
- **29 Sep 2026: GX exercise 1 hint fixed (commit 87ff4f0).** The hint said to type `LD X0, OR Y0, ANI X1, OUT Y0`. The `OR Y0` step fails with "An OR branch needs a ladder above it", because the editor places OR at the cursor, as GX Works3 does. The hint now gives the order the tests use: `LD X0, ANI X1, OUT Y0`, and then, with the cursor at the start of the next row, `OR Y0`. CI is green. It's the only "type it in" hint in the exercises.
- **30 Sep 2026: TIA monitoring now redraws live (commit 7960344).** The user found this on a real Mac. Pressing Start in the I/O Trainer didn't turn the rung green; the ladder only caught up after switching to another tab and back.
  - **Cause:** `S7LadderContext` carried the block's `S7BlockMonitor`, one object the CPU updates in place. `SiemensNetworkList` re-ran on every refresh, but each `SiemensNetworkView` got identical inputs, so SwiftUI skipped redrawing it.
  - **Fix:** the context now also carries the session's refresh counter, so every refresh counts as new data.
  - **Not affected:** GX Works3 builds a new `MelsecLadderDrawing` value for every redraw, and the watch table, PLCSIM panel and trainer read the refresh counter themselves.
  - **Why the tests missed it:** the snapshot tests rendered a new view each time, which is the same as switching tabs.
  - **New test:** `LiveMonitoringTests` keeps one view on screen and checks that it changes when %I0.0 turns on and off. It failed on the old code (commit 8920d76) and passes with the fix.
  - **CI:** a failing test now prints its failure text.
  - **Lesson:** any view that passes a class instance the CPU mutates into child views needs a changing value alongside it.
- **Exercise 1 workflow:** the user was given a step-by-step TIA exercise 1 workflow covering tags, the network (Shift+F2 / F7 / F8 / F9 from the rail stop), Ctrl+B, Ctrl+Shift+X (Start search › Load › Load › Start all › Finish), Ctrl+K, Ctrl+T, the trainer, Check my program, then STOP, Ctrl+M and Simulation › Stop. They also asked why the watch table can't modify %I0.0: the CPU copies the inputs at the start of every cycle and overwrites it, as a real S7-1200 does. Use the Trainer or the Force table instead.
- **First use:** the user has started learning the app on a real Mac. Nothing has been reported back yet. They were asked to note focus, key, layout and Check-my-program problems. The starter path given to them: GX exercise 1 (type, F4, simulation, F3, trainer ⇧⌘T, Check my program), then TIA exercise 1. Compare the two stop buttons: NO-wired X1 is programmed with ANI, and NC-wired S2 with a normally open contact.

## Working notes (for the next session)
- **Branches:** `develop` is where work happens; `main` holds releases. The agent branches `st-engine`, `melsec` and `siemens` are fully merged.
- **Releases:** run the Build workflow manually on `main` with `release_tag: vX.Y`. The dev container's proxy rejects tag pushes, so the workflow creates the tag.
- **Syntax checks:** there is no local Swift compiler. Use the tree-sitter syntax check, then CI. Known tree-sitter false positives: `x as? T ?? y` and `await` inside `if let`.
- **Build settings:** default MainActor isolation, Swift 5 mode, and MemberImportVisibility. Engine types are marked `nonisolated`, and every file imports what it uses.
- **Delegation briefs:** they sit in the session scratchpad, not the repo: `st-agent-brief.md`, `melsec-agent-brief.md`, `siemens-agent-brief.md` and `ui-brief-*.md`.
