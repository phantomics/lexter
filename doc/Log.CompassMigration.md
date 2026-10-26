---
id:            LEXTER-DRAFT-compass-migration-log
title:         "Compass Migration: Development Log"
genre:         Log
scope:         project
project:       Lexter
language:      en
status:        Draft
provenance:
  assistant:   opencode
relates-to:
  - LEXTER-DRAFT-compass-migration
  - CLASSIC-0036
  - ORIGIN-0017
decisions:
  - LEXTER-DRAFT-compass-migration-log-D1
  - LEXTER-DRAFT-compass-migration-log-D2
  - LEXTER-DRAFT-compass-migration-log-D3
---

# Compass Migration: Development Log

This document chronicles the migration of Lexter's documentation to version
0.4.0 of the Compass standard, checked by version 0.2 of its toolchain,
following the plan [LEXTER-DRAFT-compass-migration](Plan.CompassMigration.md).
The work ran in five phases: the plan itself, the infrastructure, front-matter
on every document, conformance in the document bodies in four batches, and this
Log. It changed how the eleven development Logs are shaped, identified, and
linked, not what they say about the code. It is the Lexter counterpart of
Classic's migration Log
([CLASSIC-0036](../../../lisp/classic/doc/Log.CompassMigration.md)) and
Origin's ([ORIGIN-0017](../../../lisp/origin/doc/Log.CompassMigration.md)).


## Problem

Lexter's corpus was eleven development Logs written before Compass, renamed
from `DevLog.*` to `Log.*` in commit `7c96c99`. None had front-matter, so
`compass check` reported eleven `fm/present` errors, and with
`--skip-unmarked` it checked nothing. There was no `.mailmap`, ledger, index,
CI workflow, or code owners.

The Logs' bodies fell short of the standard in the ways the plan lists: 57
decisions written as numbered headings or bold-lead paragraphs rather than
ADR-shaped records; 44 code references as bare line numbers, and one into
Origin through a home-directory path; a session transcript cited by line; spine
sections missing or misnamed; follow-up work in four different non-canonical
forms; seven `**Date:**` lines earlier than the commits holding their work; and
no table captions or diagram descriptions.


## Design Decisions

The migration followed the ten decisions of the plan,
LEXTER-DRAFT-compass-migration-D1 through LEXTER-DRAFT-compass-migration-D10.
Three further decisions were made during the build, each at the steward's
direction; the refinements they led to are recorded in the plan's text.

### LEXTER-DRAFT-compass-migration-log-D1 — Pinning is brought forward into Phase 2

**Status:** Proposed

**Context:** Phase 2's gate was `compass check` without `--skip-unmarked`. Once
the Logs carried front-matter, the toolchain read their bodies and reported 50
`ref/code-pinned` errors in five Logs: 44 bare line references, the Origin
reference, four transcript references, and a package-qualified Lisp symbol it
read as a code reference. Pinning was Phase 3 work, and CI would have failed on
every one of them.

**Decision:** The references the check flagged are pinned in Phase 2, and the
transcript becomes a `cites:` entry there, as LEXTER-DRAFT-compass-migration-D4
and LEXTER-DRAFT-compass-migration-D7 describe. The plan's Phase 2 gains a step
recording it, and Phase 3's rows for the affected Logs say the work was done.

**Alternatives:**
- Split Phase 2: front-matter only on the six Logs that checked clean, the rest
  in their Phase 3 batches. Rejected: `--skip-unmarked` would have stayed until
  two batches had landed.
- Commit Phase 2 as it stood and accept a failing CI until Phase 3's first two
  batches. Rejected: the plan's gate would have needed amending, and a failing
  check hides new errors.

### LEXTER-DRAFT-compass-migration-log-D2 — A decision written as a section becomes a record, placed first

**Status:** Proposed

**Context:** Two Logs stated their central choice in a section of its own,
outside the numbered decisions: GUI Lifecycle's "Design: Approach B" and Multi
Buffer's "How real terminals do this". The plan's count of decisions had left
them as prose. Each weighed named alternatives, and the other decisions in its
Log refine it.

**Decision:** Each becomes a decision record, numbered after the Log's existing
ones so that their numbers still match the original text, and placed first
among the records with a migration note saying why:
LEXTER-DRAFT-gui-lifecycle-D7 and LEXTER-DRAFT-multi-buffer-D6. A choice stated
in a sentence within a larger section, such as the Screenshot Test Rig's choice
of FNV-1a, stays prose.

**Alternatives:**
- Leave the sections as background. Rejected by the steward for Approach B as
  an important choice; Multi Buffer's section was treated the same way.
- Number the new record first and renumber the rest. Rejected: the records
  would no longer match the numbering in the original text.

### LEXTER-DRAFT-compass-migration-log-D3 — A steward's answer to an open question is recorded as a Resolution

**Status:** Proposed

**Context:** LEXTER-DRAFT-encoding-ranges-O1 asked where UTF-8 is decoded
relative to cl-vt. The steward confirmed that cl-vt's UTF-8 mode settled it.
The standard defines a `**Resolution:**` field only for the findings of a
critique (§8), and cl-vt has no Compass namespace, so its code cannot be cited
by a pinned code reference.

**Decision:** The answer is written as a `**Resolution:**` paragraph in the
question's record, in the form a finding's takes (the date, accepted, and the
change that answers it), stating that it is recorded at the steward's
direction. cl-vt's commit is a `cites:` entry; Lexter's side is a pinned
reference to the commit that enables the mode.

**Alternatives:**
- Leave the question open and record the answer in a later Log. Rejected by the
  steward: the fix was already in the work commit the Log describes.

Compass defines no resolution form for ordinary open questions; see
Outstanding Work.


## Implementation

### Phase 0 — The plan (`bbb5af7`)

`doc/Plan.CompassMigration.md` was written with the `compass-author` skill and
checked with `compass-review`: ten decision records, two open questions, and a
table of the commits each Log's references would pin to. Its baseline was
commit `7c96c99`, which renamed the Logs and added `compass.sexp` and
`AGENTS.md`.

### Phase 1 — Infrastructure (`f8be2f9`)

- `.mailmap` maps the Git identity `phantomics` to Andrew Sengul, so that
  derived authors and ledger entries name the steward.
- `doc/REGISTRY.sexp`, the ledger, created empty by `compass init --ledger`.
- `.github/workflows/compass-check.yml` and `.github/CODEOWNERS`, adapted from
  Origin's (LEXTER-DRAFT-compass-migration-D9), with the toolchain pinned to
  Compass `9a6ab23`. The check ran with `--skip-unmarked` until Phase 2.
- `AGENTS.md` refreshed from the current Compass snippet.
- `doc/INDEX.md` generated by `compass index`.

### Phase 2 — Front-matter and pinning (`482105a`)

- Front-matter on the eleven Logs, as the plan's Phase 2 table gives it:
  provisional identifiers, `status: Draft`, components, and
  `provenance: { assistant: opencode }`, with `created` and `updated` left to
  Git. `relates-to` on seven Logs, only where the later Log builds on the
  earlier one's work.
- 46 code references pinned (LEXTER-DRAFT-compass-migration-log-D1): Stop Flag
  at `4e800cb` and `50aeebc`, with the Origin reference federated at Origin's
  `6708956`; Input Redirect at `b4d874d`, with paths completed; Palette Paging
  at `04d69c2`; Persistent Palette at `5860229`, where its line numbers
  resolve, rather than its work commit; and the GUI Lifecycle symbol at
  `4313881`.
- The four transcript references became `cites:` entries in two Logs.
- `--skip-unmarked` removed from `AGENTS.md` and the CI workflow.

### Phase 3, batch 1 — Integration and lifecycle (`07705aa`)

Stop Flag (5 records), GUI Lifecycle (6), and Input Redirect (6). Input
Redirect gained Implementation and Verification sections; its Verification
makes no claim, since the Log recorded no testing. GUI Lifecycle's date was
corrected. The "How …" walk-throughs moved under Implementation, and each
diagram gained a description. The plan's pinning rule was refined: the code as
it stood before the work pins to the work commit's parent, and Files-table
paths are not pinned.

### Phase 3, batch 2 — Palette and rendering (`cbddb9c`)

GUI Lifecycle's Approach B became LEXTER-DRAFT-gui-lifecycle-D7
(LEXTER-DRAFT-compass-migration-log-D2). Palette Paging (4 records) gained a
Files table built from `04d69c2`. Persistent Palette (4 records) gained a Files
table for its main work, and its H1 appendix became `## Update 2026-06-20 — OSC
Palette Control`. Offscreen FBO (6 records): Motivation became Problem, its
Phase 2 list became Outstanding Work, and its in-body `**Status:**` label was
removed. Origin had numbered its migration documents in the meantime, so the
plan's four references to them were rewritten to ORIGIN-0001, ORIGIN-D4, and
ORIGIN-0017.

### Phase 3, batch 3 — Fonts and encoding (`89b4e1e`)

Enhanced Dual Width (5 records): the precursor fixes were traced to `48b917f`
and `4313881`, and their section moved under Implementation. Encoding Ranges:
Part 1 became the body, Part 2 became `## Update 2026-06-21 — UTF-8 vs. 8-bit
C1 controls`, and the candidate fixes became LEXTER-DRAFT-encoding-ranges-O1.

### Phase 3, batch 4 — VT and testing (`fa8dadc`)

LEXTER-DRAFT-encoding-ranges-O1 was resolved
(LEXTER-DRAFT-compass-migration-log-D3). Multi Buffer (7 records): the
two-buffer choice became LEXTER-DRAFT-multi-buffer-D6, and the addendum became
`## Update 2026-06-09 — Stale Grid After Buffer Swap` with its decision as
LEXTER-DRAFT-multi-buffer-D7. Mouse Reporting (7) and Screenshot Test Rig (8)
had their bold-lead decisions made records and their Files lists made tables;
the Screenshot Test Rig gained an Outstanding Work section gathered from the
items it defers.

### Corrections found along the way

Checking each Log against its commits turned up these, each recorded in the
Log concerned by a migration note rather than by changing its claims
(LEXTER-DRAFT-compass-migration-D10):

- Input Redirect's work includes `9e1e6d0`, which added the workspace
  back-reference and decorator.
- Six Files tables omit files their commits changed (Stop Flag, GUI Lifecycle,
  Input Redirect, Enhanced Dual Width, Encoding Ranges, Screenshot Test Rig).
  The omissions are named in notes; no rows were added.
- The cursor fix Enhanced Dual Width attributes to the 3270 work replaced the
  lookup with a reverse-video cursor, rather than correcting its keyword.
- Encoding Ranges' work commit `fbf8817` already enabled cl-vt's UTF-8 mode,
  which the Log does not describe; it is the fix that resolves
  LEXTER-DRAFT-encoding-ranges-O1.
- The Screenshot Test Rig's commit also carried Origin handoff code, recorded
  in Origin's [ORIGIN-0012](../../../lisp/origin/doc/Log.ImpulseIII.md).


## Verification

Every gate was checked with two builds of the toolchain, as Classic did
(CLASSIC-D111): the local `compass 0.2.0` at commit `fe188d0`, and Compass
`9a6ab23`, the revision CI builds, exported with `git archive` and built
outside the repository.

Table: The gate of each phase and batch, and its result on both builds.

| Phase | Commands | Result |
|---|---|---|
| Phase 0 | `compass check --skip-unmarked --federation` | 0 errors, 0 warnings |
| Phase 1 | `compass check --skip-unmarked`, with `--federation` and with `--base HEAD`; `compass index --check` | 0 errors, 0 warnings; index current |
| Phase 2 | `compass check`, with `--federation` and with `--base HEAD`; `compass index --check` | 0 errors, 0 warnings; index current |
| Phase 3, each batch | as Phase 2 | 0 errors, 0 warnings; index current |
| Phase 4 | as Phase 2 | 0 errors, 0 warnings; index current |

To confirm that the pins were verified rather than skipped, a misspelt symbol
and a wrong Origin revision were planted in the Stop Flag Log during Phase 2;
the check reported both, and the file was restored. The toolchain does not
check section shape or accessibility (§12, §14); those were checked by review
of each batch.


## Files

Table: Files added or changed in commits `bbb5af7` through `fa8dadc`, and in this Log's commit.

| File | Action | Description |
|------|--------|-------------|
| `doc/Plan.CompassMigration.md` | **New** | The migration plan, refined in each phase |
| `.mailmap` | **New** | Canonical name for the steward |
| `doc/REGISTRY.sexp` | **New** | The ledger, empty |
| `.github/workflows/compass-check.yml` | **New** | CI check, toolchain pinned to Compass `9a6ab23` |
| `.github/CODEOWNERS` | **New** | `/doc/REGISTRY.sexp` assigned to the steward |
| `doc/INDEX.md` | **New** | Generated by `compass index`, regenerated in each phase |
| `AGENTS.md` | Modified | Compass block refreshed; migration line updated |
| `doc/Log.StopFlag.md` | Modified | Front-matter, 5 records, pins, caption, description |
| `doc/Log.GUILifecycle.md` | Modified | Front-matter, 7 records, date, pins, caption, description |
| `doc/Log.InputRedirect.md` | Modified | Front-matter, 6 records, citation, pins, Implementation, Verification, caption, descriptions |
| `doc/Log.PalettePaging.md` | Modified | Front-matter, 4 records, citation, pins, Files table |
| `doc/Log.PersistentPalette.md` | Modified | Front-matter, 4 records, Update section, date, pins, Files table, captions, description |
| `doc/Log.OffscreenFBO.md` | Modified | Front-matter, 6 records, date, spine, pins, caption |
| `doc/Log.EnhancedDualWidth.md` | Modified | Front-matter, 5 records, date, pins, caption |
| `doc/Log.EncodingRanges.md` | Modified | Front-matter, open question and its resolution, Update section, date, pins, captions |
| `doc/Log.MultiBuffer.md` | Modified | Front-matter, 7 records, Update section, date, pins, captions |
| `doc/Log.MouseReporting.md` | Modified | Front-matter, 7 records, pins, Files table, Outstanding Work |
| `doc/Log.ScreenshotTestRig.md` | Modified | Front-matter, 8 records, pins, Files table, Outstanding Work, description |
| `doc/Log.CompassMigration.md` | **New** | This Log |

The baseline commit `7c96c99` renamed the eleven Logs and added
`compass.sexp` and `AGENTS.md`; it also carried source changes unrelated to the
migration and an editor autosave file, `src/#origin.lisp#`.


## Metrics

- Documents given front-matter: 11, plus the plan and this Log.
- Decision records: 59 in the Logs, 10 in the plan, 3 in this Log; all
  `Proposed`.
- Open-question records: 1 in the Logs (resolved), 2 in the plan.
- Commit-pinned code references in the Logs: 137, of which 46 were pinned in
  Phase 2.
- Table captions in the Logs: 15; diagram descriptions: 6.
- Files tables built or rewritten: 4 (2 built from Git, 2 from bulleted lists).
- Update sections: 3; dates corrected: 6.
- Migration notes in the Logs: 30.


## Outstanding Work

- **The steward's review.** Each Log is `Draft` and each record `Proposed`
  (LEXTER-DRAFT-compass-migration-D2). The steward sets `Implemented` on the
  Logs and accepts the records, then numbers them with `compass assign`, in
  the order LEXTER-DRAFT-compass-migration-O1 asks about.
- **A compiled README.** LEXTER-DRAFT-compass-migration-O2 remains open.
- **The editor autosave file.** `src/#origin.lisp#`, committed in `7c96c99`,
  is not part of the source and could be removed and ignored.
- **Resolutions of open questions, upstream.** Compass defines
  `**Resolution:**` only for a critique's findings
  (LEXTER-DRAFT-compass-migration-log-D3); a form for ordinary open questions,
  and for citing code in a repository without a Compass namespace, could be
  proposed to the standard.
- **Package-qualified symbols, upstream.** The toolchain reads a Lisp symbol
  such as `package:symbol` in backticks as an unpinned code reference. The
  migration worked around it in GUI Lifecycle; the rule could be refined in
  the toolchain.
- **Federated references in CI.** CI runs `compass check` without
  `--federation`, so references into Classic and Origin are not verified
  there; Origin's renumbering during the migration was caught only locally.
  Running the federated check before each documentation change, or after a
  federated repository assigns numbers, keeps them current.
