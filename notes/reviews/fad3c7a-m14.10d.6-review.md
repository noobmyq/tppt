# TPPT patch review: fad3c7a / M14.10d.6 parent staging

- Review target: `fad3c7a8b1140e1c228dffb501ef3cbd761fad09`
- Subject: `[M14.10d.6] Stage reviewed validation artifacts`
- Reviewer: Codex
- Date: 2026-09-11
- Verdict: ready through fix review of
  `08c19a5f052508e6070059db6f4bf1b6bc822f1a`; no executable-source defect
  found.

## Findings

### R-fad3c7a-01 — Pin the committed QEMU review closeout before starting M14.10d.6

- Status: `retired`
- Retired-by: `08c19a5f052508e6070059db6f4bf1b6bc822f1a`
- Retired-on: 2026-09-11
- Severity: low (P3)
- Locations: `qemu-linux` gitlink; `scripts/stage-m14-validation.sh:11-13`;
  Linux `tppt_development_roadmap.md` M14.10d.4-.6 state.
- The parent commit describes and hard-codes QEMU
  `1629b56c6d3e2b4f757563acd01ee4eba4714255` as a reviewed M14.10d.5
  dependency. That commit is the coder fix for `R-4e808bf-01` and
  `R-4e808bf-02`. The reviewer-updated retirement note
  `qemu-linux/notes/reviews/4e808bf-m14.10d.5-review.md` is still untracked,
  so no reviewer commit records the retirement required by `AGENTS.md`.
  In contrast, the Workloads gitlink includes reviewer closeout `565f976`
  and the Linux gitlink includes helper closeout `70d6878ca`.
- The pinned Linux roadmap still says M14.10d.4 QEMU work may begin and leaves
  M14.10d.5 unchecked. The replacement contract requires M14.10d.5's reviewed
  dependencies to be recorded in Linux before the ordered M14.10d.6 handoff.
  Consequently the parent can pass `--check` while the live authority still
  says its prerequisite slice is open and the QEMU finding retirement exists
  only in an untracked worktree file.
- Required fix: have the QEMU reviewer commit the retired review note, record
  the reviewed Workloads/QEMU M14.10d.5 endpoints in a concrete Linux
  dependency/status commit, then update the parent gitlinks, pinned constants,
  and staging regression to those committed endpoints. Keep M14.10d.6 and
  production readiness open until their remaining aggregate validation and
  review steps complete.
- Follow-up, 2026-09-11: QEMU reviewer commit
  `aa98de447b6725a62a0726d8b93a412123e8a43b` records the retirement of both
  findings. This satisfies the first required step. The finding remains open
  pending the Linux dependency/status commit and parent repin.
- Follow-up, 2026-09-11: Linux commit
  `dfb5d76c4671c31e355d198157e4f6023397159b` coherently records the reviewed
  Workloads/QEMU endpoints in the main plan, dedicated plans, live roadmap,
  aggregate review state and development log while keeping M14.10d.6 and
  production readiness open. Its diff and endpoint checks pass. This satisfies
  the second required step and authorizes the parent repin. The finding remains
  open because the parent gitlinks, constants and regression still name
  `70d6878c`/`1629b56`; the current staging check therefore fails against the
  reviewed Linux/QEMU heads.

## Follow-up reviewer verification — 2026-09-11

- Fix target: `08c19a5f052508e6070059db6f4bf1b6bc822f1a`.
- Reviewer: Codex. Verdict: ready; no new findings.
- The parent gitlinks now select Linux dependency record `dfb5d76c4`, QEMU
  reviewer closeout `aa98de4` and Workloads reviewer closeout `565f976`.
  `stage-m14-validation.sh` requires those same full hashes, and the permanent
  regression asserts the exact generated repository bindings.
- `git diff --check 08c19a5^ 08c19a5` and shell syntax checks passed.
- `scripts/stage-m14-validation.sh --check` passed against the reviewed heads.
- `scripts/test-m14-validation-staging.sh` passed, including copied-source
  identity, exact bindings, both warnings-as-error builds, invalid-user and
  no-overwrite rejection, and the no-image preflight.
- No image, QEMU, PostgreSQL runtime, production-readiness or M14.10d.6
  aggregate-validation operation was performed or inferred. Those gates
  remain open as stated by the fix commit.
- All reviewer-started checks exited and their disposable temporary directory
  was removed. Pre-existing workspace changes were preserved.

## Architecture and contract assessment

The staging structure is cohesive. `stage-m14-validation.sh` owns immutable
source selection and copying; `setup-disk.sh` invokes its non-destructive
preflight before image creation; `setup-userlib.sh` owns guest compilation,
the separate PostgreSQL install, and guest-local hashes. It reuses the
reviewed stateless helper, workload, and host consumers without introducing a
second runtime/provenance mechanism. The change is an `adapt` of the existing
future-image workflow and does not reuse Linux 5.11 code or evidence.

The finding is an ordered-review/provenance defect, not an architectural
redesign request. Production readiness remains false, and the commit makes no
QEMU, PostgreSQL-runtime, or milestone-closure claim.

## Validation

- `git diff --check HEAD^ HEAD` passed.
- `bash -n` passed for all four changed/new shell scripts.
- `scripts/test-m14-validation-staging.sh` passed, including the no-image
  preflight, exact copied-source comparisons, helper/workload warnings-as-error
  builds, invalid-user rejection, and no-overwrite rejection.
- `workloads/m14-validation/postgres/test_prepare.sh` passed and left the
  original source unchanged.
- QEMU host suites passed: shared 18/18 and PostgreSQL 7/7.
- A disposable two-configure PostgreSQL source-copy check confirmed the
  already-configured source shape still permits the recipe's VPATH configure.
- No image, QEMU, KUnit, PostgreSQL build/runtime, or production-readiness
  operation was performed. `shellcheck` was unavailable.
- All reviewer-started checks exited and disposable test directories were
  removed. Pre-existing changes to `qemu-linux/compile_commands.json`,
  `scripts/setup-machine.sh`, and `scripts/setup-cpa.sh`, plus the untracked
  QEMU review note, were preserved.
