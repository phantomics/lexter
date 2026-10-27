---
id:            LEXTER-0011
title:         "Compass Migration: Development Plan"
genre:         Plan
scope:         project
project:       Lexter
language:      en
status:        Implemented
authors:
  - Andrew Sengul
approved-by:   Andrew Sengul
reviewed:      2026-10-26
provenance:
  assistant:   opencode
relates-to:
  - CLASSIC-0032
  - ORIGIN-0001
decisions:
  - LEXTER-D53
  - LEXTER-D54
  - LEXTER-D55
  - LEXTER-D56
  - LEXTER-D57
  - LEXTER-D58
  - LEXTER-D59
  - LEXTER-D60
  - LEXTER-D61
  - LEXTER-D62
open-questions:
  - LEXTER-O2
  - LEXTER-O3
---

# Compass Migration: Development Plan

This plan brings Lexter's documentation into conformance with version 0.4.0
of the Compass standard ([COMPASS-0001](../../../lisp/compass/Compass.md)), as
checked by version 0.2 of its toolchain. It works in four phases: the
infrastructure the standard expects; front-matter on every document;
conformance in the document bodies (decision records, commit-pinned code
references, the Log section spine, and accessibility markup), in batches;
and a Log of the work. It changes how the documents are shaped,
identified, and linked, not what they say about the code. It follows the
migrations of Classic
([CLASSIC-0032](../../../lisp/classic/doc/Plan.CompassMigration.md)) and
Origin
([ORIGIN-0001](../../../lisp/origin/doc/Plan.CompassMigration.md)),
adapted to Lexter's corpus.

## Problem

Lexter's corpus is eleven development Logs, all predating Compass. Commit
`7c96c99` renamed them from `DevLog.*` to `Log.*` and added `compass.sexp`
and `AGENTS.md`. Nothing else is in place: there is no `.mailmap`, no
ledger, no generated index, no CI workflow, and no code owners. Git records
the author as `phantomics`, while `compass.sexp` names the steward as
Andrew Sengul.

`compass check` reports 11 errors, one `fm/present` per Log. With
`--skip-unmarked` it skips all eleven and checks nothing. Once front-matter
is added, the bodies fall short of the standard in these ways:

- **Decisions are prose, not records.** 57 decisions are written as
  numbered `### N.` headings (eight Logs, 41 decisions; five of the Logs
  give each a **Question:** and a **Decision:**), as one `### Design
  Decision` in an addendum, or as bold-lead paragraphs (Mouse Reporting, 7;
  Screenshot Test Rig, 8). Encoding Ranges ends on an undecided choice
  between two fixes.
- **Code references are bare line numbers.** 45 references in four Logs
  (Stop Flag, Input Redirect, Palette Paging, Persistent Palette) take the
  `file:line` form that §9 prohibits. Input Redirect omits the directory
  from its paths. Stop Flag points into Origin through a home-directory
  path. The other Logs name files and symbols without revisions.
- **A transcript is cited by line.** Input Redirect and Palette Paging cite
  a session transcript, `session-ses_2263-Lexter6.md`, by line number in
  four places. The transcript is not in the repository.
- **Section shape (§14).** Input Redirect has no Implementation or
  Verification section. Screenshot Test Rig has no Outstanding Work, and
  Palette Paging and Persistent Palette have no Files table. Mouse
  Reporting and Screenshot Test Rig write Files as bullet lists. Encoding
  Ranges is split into `## Part 1`/`## Part 2` with the spine at H3; Offscreen
  FBO opens on Motivation and closes on `## Phase 2: outstanding work`;
  Mouse Reporting has Future work. Follow-up work is written as
  `## Addendum:` (Multi Buffer) and as an H1 `# Appendix:` (Persistent
  Palette).
- **Dates.** Seven of the thirteen `**Date:**` lines are earlier than the
  commit that holds the work they describe. Encoding Ranges, for one, is
  dated 2026-06-06 but records work committed on 2026-06-21.
- **Accessibility (§12).** None of the eleven tables has a `Table:`
  caption, and none of the five ASCII flow diagrams has a description.

No document links to another, and no document in a federated corpus links
to a Lexter document, so the renames broke no links.

## Goals

- `compass check`, without `--skip-unmarked`, reports no errors.
- `compass check --federation` reports no errors in references into the
  `COMPASS`, `CLASSIC`, and `ORIGIN` corpora.
- Every document under `doc/` has §7 front-matter and a provisional
  identifier.
- Decisions and open questions are ADR-shaped records that can be cited
  across the federation.
- Code references in the Logs are commit-pinned.
- A ledger, a generated index, CI, and code owners keep the corpus
  conforming after the migration.

## Settled Decisions

### LEXTER-D53 — Every document and record takes a provisional identifier

**Status:** Implemented

**Context:** About 60 records and 13 documents (the eleven Logs, this plan,
and its Log) need identifiers. None has been accepted, and Lexter has
allocated no numbers.

**Decision:** Each document takes `LEXTER-DRAFT-<slug>`, the slug formed
from its file name (`Log.StopFlag.md` becomes `LEXTER-0001`).
Each record takes `LEXTER-DRAFT-<slug>-D<n>` or `-O<n>`, numbered from 1
within its document. `compass assign` gives canonical numbers when the
steward accepts each document.

**Alternatives:**
- Number the corpus canonically during the migration. Rejected: canonical
  numbers are assigned at acceptance by the steward (§13), and these
  documents are drafts.

### LEXTER-D54 — Every migrated document is status Draft

**Status:** Implemented

**Context:** An assistant never sets an authoritative status or
`approved-by` (§6). The eleven Logs record work that was built and
committed; their status during the migration says only that the migration
has not been reviewed.

**Decision:** Every document takes `status: Draft`, and every decision
record takes `Proposed`. The steward sets `Implemented` on each Log after
reviewing it.

**Alternatives:**
- `Implemented` on the Logs during migration. Rejected: `Implemented` makes
  a Log eligible for `compass assign`, and that eligibility is the
  steward's to grant.

### LEXTER-D55 — Decision records add no content

**Status:** Implemented

**Context:** 57 decisions need to become ADR-shaped records (§8). In
five Logs each carries a **Question:** and a **Decision:**; the rest are a
heading and prose, or a bold-lead paragraph. Many weigh alternatives in
prose; some do not.

**Decision:** Each decision becomes
`### LEXTER-DRAFT-<slug>-D<n> — <title>`, keeping its original title, with
**Status:**, **Context:**, **Decision:**, and **Alternatives:** drawn only
from the Log's own text. A **Question:**, where there is one, becomes
the Context. Where the
text names no alternative, the field says "None recorded." Explanatory
prose that does not fit the fields stays after them. Cross-references
written as "Decision 4" become full identifiers. Any statement added to a
Log is marked `*Migration note (<date>):*`.

**Alternatives:**
- Reconstruct missing context and alternatives from the code and
  history. Rejected: it would put claims in a historical record that its
  author never made.

### LEXTER-D56 — Code references pin to the revision they describe

**Status:** Implemented

**Context:** A Log's code references must be pinned to a revision (§9).
Lexter's line references were written against the tree at a particular
commit, which is not always the commit that holds the work. Persistent
Palette's line numbers resolve at `5860229`, where the Log was committed,
and not at `0cdd2af`, which holds its work. Palette Paging's resolve at
its work commit `04d69c2` and not at `ea169de`, where its Log was
committed.

**Decision:** Each reference is pinned to the Log's work commit if the
reference resolves there, and otherwise to the commit that added the Log.
A line reference becomes a symbol reference where the line opens a
definition (`src/unix-term.lisp:run-terminal-loop@4e800cb`), and a
`#L<start>-L<end>` range where it does not. Paths are completed to the
repository root. The Origin reference becomes a federated one
(`ORIGIN:src/managed-process.lisp:stop-process@6708956`). A reference
that describes the code as it stood before the work, as in a Problem
section, pins to the work commit's parent. Files named in prose are
pinned, and so are the principal functions and classes the work defines
where the prose describes them; headings and Files-table paths are not
pinned, and keep the
names the files had at the pinned commit, with the table's caption naming
its commits.

Table: The commits each Log's references are expected to pin to, confirmed per reference in Phase 3.

| Log | Work commits | Log committed in |
|---|---|---|
| `Log.StopFlag.md` | `4e800cb`, `50aeebc` | `50aeebc` |
| `Log.InputRedirect.md` | `9e1e6d0`, `15ba060`, `b4d874d` | `5860229` |
| `Log.PalettePaging.md` | `04d69c2` | `ea169de` |
| `Log.PersistentPalette.md` | `0cdd2af`; update `5885398` | `5860229`, `5885398` |
| `Log.GUILifecycle.md` | `4313881` | `4313881` |
| `Log.MultiBuffer.md` | `b693eac`; update `4864f01` | `b693eac`, `4864f01` |
| `Log.EnhancedDualWidth.md` | `3201c61`, `2f78659`; precursor fixes `48b917f` and `4313881` | `2f78659` |
| `Log.OffscreenFBO.md` | `1a59f24` | `1a59f24` |
| `Log.EncodingRanges.md` | `fbf8817` | `fbf8817` |
| `Log.ScreenshotTestRig.md` | `1f07ee8` | `1f07ee8` |
| `Log.MouseReporting.md` | `4d6a89d` | `4d6a89d` |

**Alternatives:**
- Pin every reference to the work commit. Rejected: where the Log was
  written against a later tree, the line numbers would point at the wrong
  code.
- Pin to the current `HEAD` and update the line numbers. Rejected: it
  rewrites history.

### LEXTER-D57 — Follow-up work takes dated Update sections

**Status:** Implemented

**Context:** Four Logs record more than one piece of work, in four
different forms: Encoding Ranges as `## Part 1`/`## Part 2`, Multi Buffer
as `## Addendum:`, Persistent Palette as an H1 `# Appendix:`, and Offscreen
FBO as `## Phase 2: outstanding work`. The canonical form is
`## Update <date> — <title>` (§14), which Classic adopted under
CLASSIC-D100.

**Decision:** The first piece of work is the Log's body, with the §14
spine at H2. Each later piece becomes a `## Update <date> — <title>`
section with its own decision records and Files table, pinned to its own
commit and dated by that commit. Encoding Ranges' Part 1 becomes its body
and Part 2 its Update. Offscreen FBO's Phase 2 section records no work
done; it becomes the Log's Outstanding Work.

**Alternatives:**
- Keep `## Part N`/`## Phase N` headings with the spine repeated at H3, as
  Origin did (ORIGIN-D4). Rejected: Lexter's four
  forms would still need normalising, and Offscreen FBO's Phase 2 is a
  list of future work, not a phase.

### LEXTER-D58 — Undecided choices become open-question records

**Status:** Implemented

**Context:** Encoding Ranges closes on "Candidate fixes (decision
pending)": two ways to stop the VT parser treating UTF-8 continuation
bytes as C1 controls, one preferred but not chosen. A Log's decision
records state choices that were made.

**Decision:** The choice becomes `LEXTER-O1`, an
open-question record listing both candidates and the stated preference,
mirrored into `open-questions:`. The Log that implements a fix resolves
it.

**Alternatives:**
- A `Proposed` decision record whose Decision is left pending. Rejected: a
  decision record states a choice, and the text records none.
- Leave the candidates in Outstanding Work. Rejected: the choice could not
  be cited by identifier.

### LEXTER-D59 — The session transcript becomes a foreign citation

**Status:** Implemented

**Context:** Input Redirect and Palette Paging cite
`session-ses_2263-Lexter6.md` by line number in four places. The file is
not in the repository, so the references can neither resolve nor be
pinned.

**Decision:** Each Log takes a `cites:` entry for the transcript, with a
title, `external: true`, and a locator naming the lines it uses. The text
refers to the citation by its title and keeps the line numbers as
locators.

**Alternatives:**
- Name the session in `provenance.session` and drop the line numbers.
  Rejected: `provenance` records how a document was written, and these
  passages cite the transcript as a source.

### LEXTER-D60 — Dates in the text are kept, and corrected where Git contradicts them

**Status:** Implemented

**Context:** Each Log has a `**Date:**` line under its abstract, and two
have a second for their follow-up work. Seven of the thirteen are earlier
than the commit that holds the work they describe, which cannot be right.
`created` and `updated` can be derived from Git (§7).

**Decision:** `created` and `updated` are left to Git. `**Date:**` lines
that agree with the work commit stay as they are. A `**Date:**` line that
predates the work commit is corrected to the date of that commit, with a
migration note giving the original date. In the Logs that become Update
sections, the date moves into the Update heading.

**Alternatives:**
- Keep every `**Date:**` line unchanged, as Origin did. Rejected: seven
  would contradict the commits pinned beside them.
- Remove the `**Date:**` lines. Rejected: where they are right, they
  record when the work was done, which can differ from when the Log was
  committed.

### LEXTER-D61 — CI and code owners mirror Origin

**Status:** Implemented

**Context:** Classic and Origin enforce the standard with a CI workflow
that builds the toolchain at a pinned revision and checks the corpus
against the base branch, and with a CODEOWNERS entry that requires the
steward's approval for changes to the ledger.

**Decision:** Lexter adopts the same: `.github/workflows/compass-check.yml`
at Origin's pinned `COMPASS_REV` (`9a6ab23`), and `.github/CODEOWNERS`
assigning `/doc/REGISTRY.sexp` to the steward. Branch protection is set by
the steward in GitHub's settings.

**Alternatives:**
- No CI for now. Rejected: the uniqueness of numbers depends on a check
  that cannot be bypassed.

### LEXTER-D62 — Structure changes; content is not refreshed

**Status:** Implemented

**Context:** Several Logs record work as pending or deferred, such as
Encoding Ranges' UTF-8 fix and Mouse Reporting's deferred items, and later
commits may have changed what they describe. Refreshing them would mix
content edits with structural ones.

**Decision:** The migration changes front-matter, headings, records,
references, tables, and captions. It does not change what a Log claims.
Every migrated document records `provenance: { assistant: opencode }`,
consistent with Classic and Origin.

**Alternatives:**
- Refresh stale content in the same effort. Rejected: it multiplies the
  size of the change and makes the structural edits harder to review.

## Phase 1 — Infrastructure

1. **`.mailmap`.** Map `phantomics <andrew@foldspace.tech>` to
   `Andrew Sengul <andrew@foldspace.tech>`, so that Git-derived authors and
   ledger entries name the steward. Verify with `git check-mailmap`.
2. **The ledger.** Create `doc/REGISTRY.sexp` with
   `compass init --ledger` (run with `--dry-run` first). It starts empty.
3. **CI and code owners** (LEXTER-D61).
4. **`AGENTS.md`.** Refresh the Compass block from the current snippet:
   add `next` to the commands, and the sentence on `compass assign` and the
   ledger.
5. **The index.** Generate `doc/INDEX.md` with `compass index`.
6. **Gate:** `compass check --skip-unmarked` reports no errors, and
   `compass index --check` passes.

## Phase 2 — Front-matter on every document

1. **Add front-matter** to the eleven Logs, following the Log template:
   a provisional `id` (LEXTER-D53), a `title`
   matching the H1, `genre: Log`, `scope: component`, `project: Lexter`,
   the component below, `language: en`, `status: Draft`
   (LEXTER-D54), and
   `provenance: { assistant: opencode }`
   (LEXTER-D62). `created` and `updated` are
   omitted (LEXTER-D60).

   Table: Front-matter to add to each Log.

   | Document | Identifier | Component |
   |---|---|---|
   | `Log.EncodingRanges.md` | `LEXTER-0009` | vt |
   | `Log.EnhancedDualWidth.md` | `LEXTER-0007` | fonts |
   | `Log.GUILifecycle.md` | `LEXTER-0005` | gui |
   | `Log.InputRedirect.md` | `LEXTER-0002` | panes |
   | `Log.MouseReporting.md` | `LEXTER-DRAFT-mouse-reporting` | vt |
   | `Log.MultiBuffer.md` | `LEXTER-0006` | vt |
   | `Log.OffscreenFBO.md` | `LEXTER-0008` | renderer |
   | `Log.PalettePaging.md` | `LEXTER-0004` | renderer |
   | `Log.PersistentPalette.md` | `LEXTER-0003` | renderer |
   | `Log.ScreenshotTestRig.md` | `LEXTER-0010` | test |
   | `Log.StopFlag.md` | `LEXTER-0001` | origin |

2. **`relates-to`** is filled only where one Log builds on or names
   another's work: for example Persistent Palette and Palette Paging, and
   Screenshot Test Rig and Offscreen FBO.
3. **Pin the flagged code references**, brought forward from Phase 3.
   Once the Logs carry front-matter, `compass check` reads their bodies,
   and `ref/code-pinned` reports every reference that names a location
   without a revision: the 45 line references in Stop Flag, Input
   Redirect, Palette Paging, and Persistent Palette, and the four
   transcript references. The gate in step 5 cannot pass until they are
   pinned, and CI would fail on them. They are pinned in this phase
   (LEXTER-D56), and the transcript becomes a
   `cites:` entry in the two Logs that use it
   (LEXTER-D59).

   Table: The revisions the Phase 2 references are pinned to.

   | Log | References | Pinned to |
   |---|---|---|
   | `Log.StopFlag.md` | 11 line references, and the Origin reference | `4e800cb` (the loops), `50aeebc` (`src/origin.lisp`), Origin's `6708956` |
   | `Log.InputRedirect.md` | 19 line references, paths completed; 3 transcript references | `b4d874d` |
   | `Log.PalettePaging.md` | 7 line references; 1 transcript reference | `04d69c2` |
   | `Log.PersistentPalette.md` | 7 line references | `5860229` |

   `Log.GUILifecycle.md` names the package-qualified symbol
   `lexter/origin` `define-terminal` in the `package:symbol` form, which
   the check reads as an unpinned code reference. It becomes
   `src/origin.lisp:define-terminal@4313881`, keeping the package name
   in the text.
4. **`AGENTS.md`** and the CI workflow drop `--skip-unmarked`, and the
   index is regenerated.
5. **Gate:** `compass check --federation`, without `--skip-unmarked`,
   reports no errors.

## Phase 3 — Body conformance

Every Log receives the same treatment:

- decision records (LEXTER-D55), mirrored into
  `decisions:`;
- pinned code references for the references Phase 2 did not pin, such
  as files and symbols named without a location
  (LEXTER-D56);
- the §14 spine: Problem, Design Decisions, Implementation, Verification,
  Files, Outstanding Work, with the optional sections the Log template
  admits kept in place. A missing spine section is added with a migration
  note and no new claims. A section that walks through how the pieces
  work together (such as "How the two stop paths now compose"), or a
  lesson drawn from the implementation (such as "A recurring gotcha:
  pixel store alignment"), moves into Implementation as a subsection. A
  decision written as a section of its own (such as "Design: Approach
  B") becomes a record. An in-body `**Status:**` line loses its label,
  so that it does not compete with the front-matter `status`, and keeps
  its text;
- a `Table:` caption before every table, and a `Description:` paragraph
  after every ASCII diagram (§12). Where a Files table's commits changed
  files the table does not list, a migration note names them; no rows
  are added. A Log with no Files table gets one built from its work
  commit, with a migration note;
- dates (LEXTER-D60).

The Logs also need these specific changes:

Table: Changes specific to each Log, besides the common treatment.

| Log | Specific changes |
|---|---|
| `Log.EncodingRanges.md` | Part 1 becomes the body and Part 2 an Update (LEXTER-D57); the candidate fixes become `LEXTER-O1` (LEXTER-D58); the `(pending)` Files rows move to the Update's Outstanding Work; a Design Decisions section is added with a migration note, since Part 1 records no decisions; the steward resolved `LEXTER-O1` (cl-vt's UTF-8 mode, enabled in the work commit `fbf8817`), recorded as a `**Resolution:**` with a `cites:` entry for cl-vt, which has no Compass namespace |
| `Log.InputRedirect.md` | Implementation and Verification sections added (its line references and transcript citation were done in Phase 2) |
| `Log.MouseReporting.md` | Bold-lead decisions become records, and the "Deferred" paragraph moves to Outstanding Work; Future work becomes Outstanding Work; the Files list becomes a table |
| `Log.MultiBuffer.md` | The addendum becomes an Update (LEXTER-D57), and its decision `LEXTER-D33`; the two-buffer choice in "How real terminals do this" becomes `LEXTER-D27`, placed first among the records |
| `Log.OffscreenFBO.md` | Motivation becomes Problem; the Phase 2 section becomes Outstanding Work; the in-body `**Status:**` label is removed |
| `Log.PalettePaging.md` | Files table built from `04d69c2` (its line references and transcript citation were done in Phase 2) |
| `Log.PersistentPalette.md` | The H1 appendix becomes an Update, and its "Remaining nuance" the Update's Outstanding Work; Files table built for the main work (its line references were pinned in Phase 2) |
| `Log.ScreenshotTestRig.md` | Bold-lead decisions become records; the Files list becomes a table, with a note pointing to ORIGIN-0012 for the commit's Origin handoff files; Outstanding Work gathered from the deferred items; the Workflow section moved under Implementation |
| `Log.StopFlag.md` | The common treatment only (its line references and the Origin reference were pinned in Phase 2) |
| `Log.GUILifecycle.md` | The "Design: Approach B" section becomes `LEXTER-D20`, placed first among the records |
| `Log.EnhancedDualWidth.md` | The precursor fixes' commits identified (`48b917f`, `4313881`), and their section moved under Implementation |

The work is committed in batches. Each batch is checked before the next.

Table: Phase 3 batches.

| Batch | Documents |
|---|---|
| 1. Integration and lifecycle | `Log.StopFlag.md`, `Log.GUILifecycle.md`, `Log.InputRedirect.md` |
| 2. Palette and rendering | `Log.PalettePaging.md`, `Log.PersistentPalette.md`, `Log.OffscreenFBO.md` |
| 3. Fonts and encoding | `Log.EnhancedDualWidth.md`, `Log.EncodingRanges.md` |
| 4. VT and testing | `Log.MultiBuffer.md`, `Log.MouseReporting.md`, `Log.ScreenshotTestRig.md` |

**Gate, after each batch:** `compass check --federation` reports no
errors; the index is current; the batch is reviewed with `compass-review`.

## Phase 4 — The migration Log

`doc/Log.CompassMigration.md` (`LEXTER-0012`)
records each phase and batch with its commit, and the counts of records,
pinned references, and captions. The index is regenerated, and
`compass check --federation` is run a final time.

## Scope and Non-Goals

Outside this plan:

- Refreshing stale content in any Log
  (LEXTER-D62).
- The steward's review of statuses, acceptance of decision records, and
  `compass assign`.
- Converting `README.md` (LEXTER-O3).

## Tensions and Risks

- **Two toolchain builds.** The local toolchain is `fe188d0`, and CI will
  build `9a6ab23`. Gates are checked with both where the CI build is
  available, as Classic did (CLASSIC-D111).
- **Unchecked rules.** Version 0.2 of the toolchain does not check
  accessibility or section shape. Phase 3's captions, descriptions, and
  spine are verified by review, not by `compass check`.
- **Decision extraction is judgment.** Dividing prose into Context,
  Decision, and Alternatives can shift its emphasis. Each record keeps its
  original wording where it can.
- **Pinning is judgment.** A reference's revision is chosen by where it
  resolves (LEXTER-D56); `ref/code-exists` confirms
  the path and revision but only finds symbols by pattern.
- **Many records to accept.** The migration yields about 60 records, all
  `Proposed`.

## Open Questions

### LEXTER-O2 — Which documents are numbered first

Once the migration lands, every document and record has a provisional
identifier. Should the steward number the corpus at once, or document by
document as each Log is reviewed and set `Implemented`?

### LEXTER-O3 — A compiled README

Compass lets a repository README be compiled from a template that includes
sections of the corpus by identifier (§10). Lexter's README describes the
architecture, which no Log covers as a whole. Should it become a template
once the compiler exists, should its architecture overview become an
`Arch` or `Ref` document, or should it stay hand-written?

## Prior Art

Table: Prior work in the federation and what this plan draws from each.

| System | What to draw from |
|---|---|
| [COMPASS-0001](../../../lisp/compass/Compass.md) | The standard being conformed to (version 0.4.0) |
| [COMPASS-0004](../../../lisp/compass/doc/Plan.Toolchain.md) | What the toolchain checks, and the ledger discipline |
| Classic's migration ([CLASSIC-0032](../../../lisp/classic/doc/Plan.CompassMigration.md), [CLASSIC-0036](../../../lisp/classic/doc/Log.CompassMigration.md)) | Dated Update sections (CLASSIC-D100), the gate discipline, and checking with two toolchain builds (CLASSIC-D111) |
| Origin's migration ([ORIGIN-0001](../../../lisp/origin/doc/Plan.CompassMigration.md), [ORIGIN-0017](../../../lisp/origin/doc/Log.CompassMigration.md)) | The phase structure, the decision-record and pinning conventions, the batch gates, and the CI and CODEOWNERS files |

## Roadmap

1. Phase 0: this plan is written, checked, and reviewed.
2. Phase 1: `.mailmap`, the ledger, CI, code owners, the refreshed agent
   guide, and the index.
3. Phase 2: front-matter on the eleven Logs, and the line references
   and transcript references pinned.
4. Phase 3, by batch: integration and lifecycle; palette and rendering;
   fonts and encoding; VT and testing.
5. Phase 4: `Log.CompassMigration.md`, recording the work.
6. The steward reviews statuses, accepts records, and numbers with
   `compass assign` (LEXTER-O2).
