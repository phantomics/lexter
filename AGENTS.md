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
- Migration: under way, following `doc/Plan.CompassMigration.md`
  (LEXTER-DRAFT-compass-migration). The Logs in `doc/` predate Compass and
  have no front-matter yet; run checks with `compass check --skip-unmarked`

Essentials (full rules in Compass.md): every document opens with a §7 YAML
front-matter block; genre and status use the controlled vocabularies; decision
records are ADR-shaped (`D`-records); new documents and their records keep
provisional `<NAMESPACE>-DRAFT-<slug>` identifiers until a steward assigns
numbers; code references in Log/Plan are commit-pinned (`path:symbol@revision`),
never bare line numbers; documents authored with LLM help carry `provenance:`;
an assistant never sets `approved-by` or an authoritative status.
