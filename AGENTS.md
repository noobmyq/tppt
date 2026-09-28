# TPPT superproject guide

This is the superproject at `/mnt/storage/tppt`. Start here even when the initial
working directory is a submodule such as `linux-tp`. The main Linux experiment
pipeline is workload execution in Linux/QEMU, binary trace capture, downstream
simulation in `tp-emt-dynamorio`, then numerical analysis and plots.

Keep this file focused on durable rules, navigation, and output conventions.
Keep dated progress, commit hashes, experiment measurements, and milestone status
in the owning repository's plans, logs, or results. Read the actual scripts and
current Git state before relying on a default described here.

Quick navigation: [first pass](#first-pass), [components](#component-map-and-where-to-go-next),
[experiments and their folders](#experiments-and-their-folders),
[entry points](#use-the-existing-experiment-entry-points),
[capture rules](#capture-contracts-and-resource-rules),
[output layout](#output-layout-and-retention),
[trace interpretation](#trace-interpretation-and-fair-simulation), and
[analysis](#numerical-analysis-and-deeper-investigations).
File and directory links below are relative to this superproject root.

## First pass

- Read [.gitmodules](.gitmodules) and applicable `AGENTS.md` files. More specific instructions
  apply within their directory. Read [linux-tp/AGENTS.md](linux-tp/AGENTS.md) in full before Linux
  implementation or validation work. Copied instructions in generated build or
  result trees do not govern the source repositories.
- Begin onboarding with read-only inspection: `git rev-parse`, `git log`,
  `git diff`, `GIT_OPTIONAL_LOCKS=0 git status --short`, and
  `GIT_OPTIONAL_LOCKS=0 git submodule status`. Inspect each relevant submodule;
  the superproject status alone can hide nested changes and ignored artifacts.
- Treat dirty and untracked files as user-owned. Do not reset, clean, switch
  branches, rebuild, or rerun setup just to understand the checkout. Setup,
  simulation, and plotting scripts can write, overwrite, or delete outputs.
- Use bounded searches in source and documentation. Inspect names, sizes, and
  provenance before reading generated trees. Do not recursively grep binary
  traces, disk images, or large build/result directories.
- Distinguish committed work, uncommitted files, ignored outputs, and unpublished
  commits. Comparing HEAD to a local remote-tracking ref does not verify the
  current remote server. Submodule branch hints in `.gitmodules` are not proof
  of the checked-out branch.

## Component map and where to go next

| Component | Purpose and first pointers |
| --- | --- |
| [linux-tp](linux-tp/) | TPPT on Linux 6.8. Read its [policy](linux-tp/AGENTS.md), [implementation plan](linux-tp/development-log/impl_plan.md), and [roadmap](linux-tp/development-log/tppt_development_roadmap.md), then the active milestone's detailed plan. Implementation: [mm/tppt](linux-tp/mm/tppt/) and [tppt.h](linux-tp/include/linux/tppt.h). Validation: `kernel/tppt_*_test.c`, [TPPT tools](linux-tp/tools/testing/tppt/), [TPPT selftests](linux-tp/tools/testing/selftests/tppt/), and `tools/testing/selftests/mm/tppt_*`. |
| [qemu-linux](qemu-linux/) | Linux TPPT execution, decode, and trace capture. Start with the [launcher](qemu-linux/run-qemu-linux.sh), [decoder](qemu-linux/target/i386/tppt-decode.c), [decode vectors](qemu-linux/spec/tppt_decode_vectors_v1.json), and [plugins](qemu-linux/contrib/plugins/). Design/state: [implementation plan](qemu-linux/development-log/tppt_qemu_impl_plan.md), [roadmap](qemu-linux/development-log/tppt_qemu_development_roadmap.md), and [THP plan](qemu-linux/development-log/tppt_thp_qemu_impl_plan.md). Evidence: [reviews](qemu-linux/notes/reviews/). |
| [tp-emt-dynamorio](tp-emt-dynamorio/) | Shared downstream frontend and page-walk/cache simulator for native TPPT and EMT traces. Start with [run_common.sh](tp-emt-dynamorio/run_common.sh), the [trace reader](tp-emt-dynamorio/clients/drcachesim/reader/qemu_file_reader.cpp), [simulator](tp-emt-dynamorio/clients/drcachesim/simulator/), and [CLI options](tp-emt-dynamorio/clients/drcachesim/common/options.cpp). |
| [dmt-simulator](dmt-simulator/) | DMT simulation and comparison postprocessing. For the Linux comparison, [plot.py](dmt-simulator/results/plot.py) consumes downstream text results and emits CSVs and figures. |
| [workloads](workloads/) | Guest workload sources and instrumentation: [Linux apps](workloads/qemu-dynamorio-workload/linux-workload/), [memory/graph apps](workloads/qemu-dynamorio-workload/osv-workload/), and [microbenchmarks](workloads/microbenchmark/). Guest copy/build provenance starts in [setup-disk.sh](scripts/setup-disk.sh). |
| [linux-6.8](linux-6.8/) | Vanilla Linux 6.8 comparison kernel. It is distinct from EMT's older radix kernel. Read [setup-vanilla-kernel.sh](scripts/setup-vanilla-kernel.sh); verify the actual source/config/image instead of assuming this directory is a separate Git repository. |
| [emt-baselines](emt-baselines/) | Generated, ignored upstream EMT source/build area, not a superproject submodule. [setup-emt-baselines.sh](scripts/setup-emt-baselines.sh) owns pinned sources and FPT/ECPT/radix build profiles. |
| [osv](osv/), [qemu](qemu/) | OSv experiment path and its QEMU. Start with [setup-osv.sh](scripts/setup-osv.sh), [run-osv.sh](scripts/run-osv.sh), and [run-qemu.sh](scripts/run-qemu.sh); do not substitute these binaries for the Linux path by directory-name similarity. |
| [osv-dynamorio](osv-dynamorio/), [dynamorio-puresim](dynamorio-puresim/), [tracer](tracer/) | Other DynamoRIO-based simulation/tracing paths. Check their local scripts, branch, and callers before reusing them; the Linux TPPT/EMT comparison normally uses `tp-emt-dynamorio`. |
| [shadow_pgtbl_kernel](shadow_pgtbl_kernel/), [linux-5.11.6](linux-5.11.6/) | Older Linux/shadow-page-table experiment and reference material. Do not count their implementation or validation as Linux 6.8 completion. |
| [hardware_quantization](hardware_quantization/) | Hardware area/timing experiments. Start with its [README](hardware_quantization/README.md) and [setup script](scripts/setup-hardware-quantization.sh). |
| [scripts](scripts/), [spec](spec/), [notes](notes/) | Superproject setup/orchestration, shared specifications, and cross-component records. [tp-simulation](tp-simulation/) and [thp_alloc_exp](thp_alloc_exp/) contain additional experiment material; inspect their local entry points when relevant. |
| `disk.img` | Shared immutable guest root filesystem used by Linux runs. See [capture rules](#capture-contracts-and-resource-rules). |

Linux design authority is `impl_plan.md`, its later amendments, and the active
milestone's detailed plan; live gate state belongs in the roadmap. Review notes
and the development log are evidence/history. For large-application debugging,
read the [debug roadmap](linux-tp/development-log/tppt_debug_roadmap.md) and
[debug runbook](linux-tp/development-log/debug_plan.md) and follow
their human-in-the-loop workflow. Drafts such as `development-log/plan_draft.md`
are not approved plans unless the user or authoritative plan explicitly adopts
them. Keep Linux 6.8 status, Linux 5.11 reference status, and portability separate.

## Experiments and their folders

Use this map to choose the relevant part of the superproject before exploring
individual files. The linked result directories are navigation examples, not
proof that every run there is complete or uses the same configuration. Verify
each run's command and retained logs. Some generated directories may be absent
in another checkout.

| Experiment | Participating components and starting point | Capture, simulation, and analysis locations |
| --- | --- | --- |
| Linux 4 KiB memory/graph comparison: TP, vanilla, FPT, ECPT | [Memory workloads](workloads/qemu-dynamorio-workload/osv-workload/) and [commands](qemu-linux/run_linux_mem_command.sh); `linux-tp`/`linux-6.8` + `qemu-linux` for TP/vanilla; `emt-baselines` supplies the matched FPT/ECPT kernels and QEMU/plugins. The [four-way driver](scripts/run-tppt-mem-4way-serial.sh) orchestrates capture and `tp-emt-dynamorio` analysis. | [Capture logs / retained traces](qemu-linux/results_tppt_emt_mem_4k_1b/) → [simulator results](tp-emt-dynamorio/results/tppt_emt_mem_4k_1b/), divided into `default` and `mmu_to_l2` → [plot.py](dmt-simulator/results/plot.py). Published [default CSVs](dmt-simulator/results/csv_linux_with_emt/) / [plots](dmt-simulator/results/linux_with_emt/) and [L2 CSVs](dmt-simulator/results/csv_linux_with_emt_mmu_to_l2/) / [plots](dmt-simulator/results/linux_with_emt_mmu_to_l2/) are separate sets. |
| Linux applications: PostgreSQL / Redis | [Linux app sources](workloads/qemu-dynamorio-workload/linux-workload/) and [commands](qemu-linux/run_linux_command.sh) → `linux-tp`/`linux-6.8` + `qemu-linux` → `tp-emt-dynamorio`. Start with [run_all.sh](qemu-linux/run_all.sh) or the [single-capture launcher](qemu-linux/run-qemu-linux.sh) for an authorized variant. | PostgreSQL examples: [captures](qemu-linux/results_logkernel_mp_1b/) → [text results](tp-emt-dynamorio/results/linux_multi_process/). Its `default/` and `mmu_to_l2/` hold the 12M variant; [r20m/](tp-emt-dynamorio/results/linux_multi_process/r20m/) holds the `-R 20000000` read-range variant. Use [compare_ipc.py](tp-emt-dynamorio/compare_ipc.py) or [plot.py](dmt-simulator/results/plot.py) with explicit inputs; exploratory outputs go to `/tmp/tppt-<experiment>/`. |
| Paired TP / vanilla THP workload experiments | [THP commands](qemu-linux/run_linux_thp_command.sh), [capture driver](qemu-linux/run_thp_linux_all.sh), `linux-tp`/`linux-6.8`, `qemu-linux`, and [THP simulator driver](tp-emt-dynamorio/run_linux_thp_all.sh). For design/validation first read the [Linux THP plan](linux-tp/development-log/tppt_thp_shared_anon_impl_plan.md) and [QEMU THP plan](qemu-linux/development-log/tppt_thp_qemu_impl_plan.md). | Default example: [results_thp_logkernel](qemu-linux/results_thp_logkernel/) → [linux_thp_run](tp-emt-dynamorio/results/linux_thp_run/). A separate graph variant uses [results_thp_top_pad_64g](qemu-linux/results_thp_top_pad_64g/) → [linux_thp_top_pad_64g](tp-emt-dynamorio/results/linux_thp_top_pad_64g/). Keep variant command files, formats, and output roots matched. |
| Fork overhead and huge-page fork measurements | [Microbenchmark sources](workloads/microbenchmark/), kernel sources/configs, and [run_fork_overhead.sh](qemu-linux/run_fork_overhead.sh). This driver builds experiment-specific kernel images and extracts guest measurements. | [results_fork_overhead](qemu-linux/results_fork_overhead/) contains its own build/log layout and `fork_overhead.csv` / `fork_overhead_thp.csv`. [quick_plot_fork_overhead.py](qemu-linux/quick_plot_fork_overhead.py) plots these CSVs directly; this workflow does not require downstream trace simulation to produce its reported fork measurements. |
| Kernel / decode / shared-memory correctness | [Linux TPPT tools](linux-tp/tools/testing/tppt/), [selftests](linux-tp/tools/testing/selftests/tppt/), [microbenchmarks](workloads/microbenchmark/), and [QEMU decode vectors](qemu-linux/spec/tppt_decode_vectors_v1.json). Follow the active plans and [Linux policy](linux-tp/AGENTS.md) for the narrow validation gate. | Evidence belongs in the owning [Linux development log](linux-tp/development-log/tppt_development_log.md), [Linux reviews](linux-tp/notes/reviews/), or [QEMU reviews](qemu-linux/notes/reviews/) under their ownership rules. These are functional validation results; use the chosen runbook's artifact paths. |
| OSv workloads and TP width/scaling comparisons | `workloads` + [OSv apps](osv/apps/) → `osv` + `qemu`. Start with [run-osv.sh](scripts/run-osv.sh), [QEMU commands](qemu/run_command.sh), and [QEMU batch capture](qemu/run_all.sh). [osv-dynamorio/run_osv_all.sh](osv-dynamorio/run_osv_all.sh) and [tp-emt-dynamorio/run_osv_all.sh](tp-emt-dynamorio/run_osv_all.sh) are distinct analysis routes. | Capture output is selected by the OSv driver (default `qemu/results/`); analysis output is selected by its matching simulator driver. Check the actual caller before selecting an analysis folder or plot input. This route uses OSv-built images rather than the Linux `disk.img` boot path. |
| TPPT decoder ASIC area/timing | [RTL](hardware_quantization/sv/), [table data](hardware_quantization/mem/), [functional simulation](hardware_quantization/simulation/), and [run scripts](hardware_quantization/scripts/run/). [README](hardware_quantization/README.md) explains the Yosys/OpenROAD flow and external tool paths. | Intermediates: [generated](hardware_quantization/generated/). Durable tables/figures: [results](hardware_quantization/results/), including [area_delay](hardware_quantization/results/area_delay/). Use its [plot scripts](hardware_quantization/scripts/plot/); Linux/QEMU traces and DynamoRIO outputs are not inputs to this flow. |

## Use the existing experiment entry points

Most experiment stages already have scripts. Find the matching one and inspect
its arguments, environment overrides, output handling, and skip/delete behavior
before creating another driver. Keep reusable orchestration in `scripts/` or the
owning repository; keep disposable wrappers in `/tmp`, outside result trees.

| Task | Entry point / command source |
| --- | --- |
| Linux app commands, including PostgreSQL and Redis | [run_linux_command.sh](qemu-linux/run_linux_command.sh); capture suite: [run_all.sh](qemu-linux/run_all.sh) |
| Memory/graph workload commands | [run_linux_mem_command.sh](qemu-linux/run_linux_mem_command.sh) |
| Paired TP/vanilla THP experiments | [run_linux_thp_command.sh](qemu-linux/run_linux_thp_command.sh) and [run_thp_linux_all.sh](qemu-linux/run_thp_linux_all.sh) |
| One Linux/QEMU capture | [run-qemu-linux.sh](qemu-linux/run-qemu-linux.sh) `<kernel-folder> <guest-command> <trace-path> [user-instruction-limit]` |
| Four-way TP/vanilla/FPT/ECPT comparison | [run-tppt-mem-4way-serial.sh](scripts/run-tppt-mem-4way-serial.sh) |
| One trace simulation | [run_common.sh](tp-emt-dynamorio/run_common.sh); read its positional arguments and pass an explicit simulator binary/output path |
| Linux analysis batches | [run_linux_all.sh](tp-emt-dynamorio/run_linux_all.sh) or [run_linux_thp_all.sh](tp-emt-dynamorio/run_linux_thp_all.sh), as appropriate for the trace family |
| Fork measurements | [run_fork_overhead.sh](qemu-linux/run_fork_overhead.sh) and [microbenchmarks](workloads/microbenchmark/) |
| Machine/kernel/EMT/guest setup | [setup-machine.sh](scripts/setup-machine.sh), [setup-linux.sh](scripts/setup-linux.sh), [setup-vanilla-kernel.sh](scripts/setup-vanilla-kernel.sh), [setup-emt-baselines.sh](scripts/setup-emt-baselines.sh), and [setup-disk.sh](scripts/setup-disk.sh) |

Setup scripts provision hosts and artifacts. Some install host packages, format
storage, switch branches, recreate images, or rebuild sources.
Inspect them and run only the portion authorized by the task.

`run_linux_all.sh` discovers legacy `.log` traces and includes a modeled ECPT
mode derived from vanilla traces. That mode is not the native EMT ECPT
comparison. For measured FPT/ECPT, use the four-way driver or the explicit
EMT format/architecture arguments to `run_common.sh`. THP batch analysis has
its own `.bin` naming and command-file interface.

## Capture contracts and resource rules

When proposing an experiment, identify the existing driver, exact workload
command, kernel/QEMU/plugin selection, trace format, RAM/pool/THP settings,
instruction limit, output destinations, queue, and trace-retention policy.
Follow the task's existing authorization and the owning repository's run rules.

- Every QEMU boot attaching `/mnt/storage/tppt/disk.img` must use `-snapshot`.
  Do not mount or modify that shared image to stage an ordinary experiment.
  Guest workload sources on the host and copies already in the image can differ;
  `setup-disk.sh` explains the copy layout but must not be rerun against the
  shared image as an incidental synchronization step.
- Use the authorized kernel, QEMU, and plugin as a matched set. The launcher
  accepts `TPPT_KERNEL_FILE`, `QEMU_BIN`, `TPPT_WORKLOAD_PLUGIN`,
  `QEMU_TRACE_FORMAT`, `QEMU_MEMORY`, and TPPT/THP overrides. Check the resolved
  invocation and console log; a filename or today's script default does not
  prove how an existing trace was captured.
- TP pool size and QEMU decode geometry must agree. Check Linux
  [pool.c](linux-tp/mm/tppt/pool.c) and [tppt.h](linux-tp/include/linux/tppt.h)
  against the [QEMU decoder](qemu-linux/target/i386/tppt-decode.c).
  When overriding geometry, provide both `TPPT_POOL_BASE_PFN` and
  `TPPT_BIN_COUNT`, and verify the kernel's selected pool/bin count at boot.
  Changing guest RAM or `TPPT_POOL_MB` alone does not set QEMU's bin count.
- For a 4 KiB comparison, explicitly disable the applicable guest THP mechanisms
  (`TPPT_THP_MODE=off`, `TRANSPARENT_HUGEPAGE_MODE=never`, and workload huge-page
  settings where relevant). A kernel may have THP compiled in while it is
  disabled for the run. Borrowing a THP launcher's RAM/pool sizes does not imply
  enabling THP or using the `tppt-thp` format.
- Standard capture limits are commonly one billion **user instructions**.
  Kernel records may also be present (`TPPT_WORKLOAD_PLUGIN_MODE=logAll`).
  Distinguish warmup, traced application phase, user instructions, kernel
  instructions, and memory-reference counts when reporting results.
- Before a new expensive run, inspect active processes and resource use. Do not
  stop someone else's job. Queue shared Linux captures on
  `/tmp/tppt-mem-4way-qemu.lock` when participating in that experiment queue.
  The four-way driver's separate `/tmp/tppt-mem-4way-serial.lock` prevents
  duplicate drivers. The generic launchers do not all acquire these locks.
- Captures are normally serialized because traces are large. Once a trace is
  complete, its default and `mmu_to_l2` analyses can run concurrently if resources
  permit. Set simulator batch concurrency deliberately; scripts may default to
  `nproc`. Follow the owning workflow's approval and process-lifetime rules.

## Output layout and retention

Use explicit experiment-specific paths. Keep outputs out of source directories
and avoid adding launcher logs, provenance dumps, copied scripts, and abandoned
attempt folders to a trace collection by default.

```text
qemu-linux/results_<experiment>/
    <workload-or-variant>_<mode>_<user-instruction-limit>.bin
    logs/qemu_<same-trace-stem>.log

tp-emt-dynamorio/results/<experiment>/
    default/{tp,vanilla,fpt,ecpt}/<workload>.txt
    mmu_to_l2/{tp,vanilla,fpt,ecpt}/<workload>.txt
```

- Prefer `.bin` for new binary captures when the chosen consumer supports it.
  Existing drivers also produce binary traces named `.log`; extension alone
  does not identify text. Preserve names required by their discovery logic.
  QEMU console text belongs in `logs/qemu_<trace-stem>.log`, as generated by
  `run-qemu-linux.sh`. QEMU `-d ... -D ...` debug logging is separate from the
  `-plugin` binary trace stream and is not required for capture.
- Preserve a suite's existing result convention. Single-configuration suites
  may use `<experiment>/{tp,vanilla}/<workload>.txt`; the THP analysis script
  writes textual `<workload>.log` instead. Both are simulator output, not binary
  captures. Do not create both extensions for the same workload in one results
  folder: some postprocessors choose `.log` first.
- Give changed workload sizes/phases a distinct variant name or result root.
  Never overwrite a completed comparison to try another setting. Existing
  variant subdirectories may be intentional; inspect their contents before
  flattening them. Moving a trace can leave paths recorded in analysis logs
  stale; report relocations explicitly and preserve the historical results.
- File existence or nonzero size is not completion. Check the capture's end
  marker and simulator summaries, including `num_requests`, detailed performance
  statistics, and the requested instruction count. The four-way driver uses
  `.partial` outputs and promotes them only after its checks pass; use the same
  principle for new orchestration. Some batch scripts merely skip existing files.
- Retain completed simulator text and QEMU console logs. Delete a large binary
  trace only under an explicitly chosen retention policy, after every required
  analysis validates. The four-way driver deletes traces after both analyses
  validate; do not invoke it on traces that the user wants retained.
- Temporary analysis CSVs, plots, wrappers, and debug outputs normally belong
  under `/tmp/tppt-<experiment>/`. Do not put exploratory outputs into
  `dmt-simulator/results/`. Publish durable CSV/plot sets there only when requested,
  using distinct names for each configuration. Binary traces and generated
  builds are generally ignored; text results may be tracked. Inspect Git rules
  rather than adding generated files indiscriminately.

## Trace interpretation and fair simulation

```text
workload command + matched Linux/QEMU/plugin
    -> binary trace + QEMU console log
    -> tp-emt-dynamorio frontend and page-walk/cache model
    -> retained simulator text
    -> analysis scripts -> CSVs and figures
```

| Capture | Frontend / walk configuration |
| --- | --- |
| TP Linux + TPPT QEMU/plugin | `qemu_trace_format=tppt`, `arch=radix`, TP walking enabled |
| Vanilla Linux 6.8 + current QEMU/plugin | `tppt`, `radix`, `skip_tiny_pointer_walk` |
| Native TP THP | `tppt-thp`; use the paired THP launch/analysis scripts |
| Vanilla THP | Native `tppt` format with TP walking skipped; `vanilla-thp` is the filename mode, not a separate trace format |
| EMT FPT Linux + EMT FPT QEMU/plugin | `emt`, `arch=fpt`, `skip_tiny_pointer_walk` |
| EMT ECPT Linux + EMT ECPT QEMU/plugin | `emt`, `arch=ecpt`, `cache_correct_only`, `skip_tiny_pointer_walk` |

The frontend converts native and EMT records into the shared downstream model.
ECPT needs its parallel candidate-walk/selected-way interpretation and CWC
behavior; do not parse it as a serial radix walk. The standard Linux comparison
baseline is our `linux-6.8`, not the generated EMT radix kernel.

Use `run_common.sh` and the four-way driver as the hardware configuration
references. Standard PWC entry counts are **4/4/16**; ECPT CWC entry counts and
associativities are **2/16** for PUD/PMD. These are implemented in
[cache_simulator.cpp](tp-emt-dynamorio/clients/drcachesim/simulator/cache_simulator.cpp). The alternate
`pwc_asplos_config` selects a different PWC geometry. `mmu_to_l2` changes the
page-walk cache entry point. Record such differences rather than mixing their
outputs in one comparison. Check simulator initialization output as well as CLI
arguments; the standard runner uses a 300-million-reference simulation warmup.

## Numerical analysis and deeper investigations

- [dmt-simulator/results/plot.py](dmt-simulator/results/plot.py) accepts explicit `--base-dir`, `--tp-dir`,
  measured `--fpt-dir`/`--ecpt-dir`, `--workloads`, and `--models`. Always set
  `--csv-dir` and `--output-dir`. Its `--csv-mode write` extracts CSVs from text;
  `--csv-mode read` replots CSVs. Example durable sets are
  [csv_linux_with_emt](dmt-simulator/results/csv_linux_with_emt/) and
  [linux_with_emt](dmt-simulator/results/linux_with_emt/), with separate
  `_mmu_to_l2` sets. Omitted FPT/ECPT inputs can select analytical estimates;
  identify whether a reported comparator is measured or modeled.
- For the fuller modeled IPC/cycle accounting, use
  [compare_ipc.py](tp-emt-dynamorio/compare_ipc.py) with `--tp`, `--vanilla`, and `--output-dir`.
  Its implementation is [ipc_with_inst.py](tp-emt-dynamorio/ipc_with_inst.py), which adds TLB, page-walk, data,
  instruction-execution, and instruction-cache cycle terms. Inspect its latency
  and parallelism assumptions. Do not run the module's historical main routine
  blindly; it contains machine-specific input paths and remote-copy helpers.
- The IPC proxy in `dmt-simulator/results/plot.py` uses memory requests and
  TLB/page-walk costs. It is a different calculation from the full cycle model;
  neither is a host hardware IPC measurement. State which script/formula was
  used. Check instruction-count versus post-warmup statistics windows before
  interpreting absolute IPC. Report TLB-hit cost separately from page-walk cost,
  and specify the denominator for hit rates and cycle percentages.
- For an unexpected workload result, trace the command back to the actual
  workload source and captured phase. Dataset size, configured buffers, RSS,
  random lookup count, and TLB misses are different quantities. PostgreSQL's
  custom workload lives under
  [postgres](workloads/qemu-dynamorio-workload/linux-workload/postgres/); inspect its
  [postgres.c](workloads/qemu-dynamorio-workload/linux-workload/postgres/src/backend/tcop/postgres.c)
  and related query execution code when reasoning
  about `-a`/`-R`, warmup, and lookup behavior.

When changing a cross-repository contract, read both implementations and the
owning plans first. Keep decode geometry, trace schema, workload markers, and
simulator interpretation aligned. Commit changes in their owning repositories;
update superproject submodule pointers separately when that operation is in scope.
