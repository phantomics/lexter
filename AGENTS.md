# Lexter — Agent Guide

Lexter is a GPU-accelerated pixel-font terminal emulator written in Common Lisp.
See [README.md](README.md) for an overview of its architecture.

## Documentation — Compass

Project documentation follows **Compass** (Common Ontological Model for Prose
Artifacts by Structural Standard). Use the `compass-*` skills rather than
improvising documents:

- `compass-author` — scaffold a new document (Survey/Eval/Plan/Log/Ref/Guide/
  Spec/Arch/Glossary/Memo) with correct front-matter and per-genre section
  shape.
- `compass-review` — the toolchain's checks plus a judgment-level review before
  accepting a doc.
- `compass-lookup` — resolve identifiers, sections, records, and references.

The skills carry the standard and its reference bundle. Load @Compass.md on
demand only if you need the source text — do not preload it.

Run `compass check` before finishing any change to the documentation, and fix
the errors it reports in the files you changed. `compass help` lists the other
commands (`show`, `outline`, `refs`, `index`, `next`, `rules`, and others).
Numbers are assigned with `compass assign` only when a person asks for it; never
edit the ledger, `doc/REGISTRY.sexp`, by hand.

Project-specific facts the skills cannot infer:

- Compass namespace: LEXTER (declared in `compass.sexp`)
- Docs directory: doc/
- The `compass` command: `compass` on the PATH after `make install` in
  `~/src/lisp/compass`; otherwise `~/src/lisp/compass/bin/compass`
- Federated repositories: COMPASS (`../../lisp/compass`), CLASSIC
  (`../../lisp/classic`), ORIGIN (`../../lisp/origin`), as listed in
  `compass.sexp`
- Migration: complete, following `doc/Plan.CompassMigration.md`
  (LEXTER-DRAFT-compass-migration) and recorded in `doc/Log.CompassMigration.md`
  (LEXTER-DRAFT-compass-migration-log). Every document carries front-matter, and
  `compass check` runs without `--skip-unmarked`; the documents await the
  steward's review and `compass assign`

Essentials (full rules in Compass.md): every document opens with a §7 YAML
front-matter block; genre and status use the controlled vocabularies; decision
records are ADR-shaped (`D`-records); new documents and their records keep
provisional `<NAMESPACE>-DRAFT-<slug>` identifiers until a steward assigns
numbers; code references in Log/Plan are commit-pinned (`path:symbol@revision`),
never bare line numbers; documents authored with LLM help carry `provenance:`;
an assistant never sets `approved-by` or an authoritative status.

## Testing — Square (Common Lisp)

Automated tests in this project follow **Square** (Software QUality Assurance
Regimen & Ethos). Use the `square-*` skills rather than improvising a suite:

- `square-author` — scaffold the test system and write conforming `def-test`s.
- `square-review` — judgment-level conformance review before accepting tests.
- `square-run` — run the suite via the ASDF `test-op` seam and triage failures.

The skills carry the standard and its reference bundle. Load @Square.md (in
the Square repository, `../square`) on demand only if you need the source
text — do not preload it.

Project-specific facts the skills cannot infer:

- Compass namespace: LEXTER
- Test directory: tests/
- Test-system form: secondary `lexter/tests`, defined in `lexter.asd`; the
  package is `lexter-tests` and the root suite `lexter`
- Run command: `sbcl --non-interactive --eval '(ql:quickload :lexter/tests)' --eval '(asdf:test-system :lexter)'`
- The suite runs headless: no GL context or display. Tests build their fonts
  in memory and pack atlases with `pack-atlas`, never `build-atlas`
- Reproduction tests for findings in LEXTER-0017 and LEXTER-0015 assert the
  repaired behaviour and fail until the repair lands; the suite stays red
  until then (LEXTER-DRAFT-cell-model-revision-D21). Each names its finding
  in its docstring
- `lexter/mouse-tests` and `lexter/origin-tests` predate the suite and are
  left as they are until they are moved into `lexter/tests`: the mouse tests
  use a homegrown `check` macro, and the Origin tests use FiveAM with a package
  and root suite of their own

Essentials (full rules in Square.md): FiveAM + cl-hamcrest only — no homegrown
assertion macros or alternative frameworks; every test isolated via a
`with-clean-*` fixture; no bare `sleep` in async tests (poll with a timeout);
every `def-test` opens with a docstring stating the invariant it proves.
