;;;; tests/package.lisp — Test package for Lexter.
;;;;
;;;; Square-conforming (see Square.md §5). Uses FiveAM for definition and
;;;; running, and cl-hamcrest for composable assertions.
;;;;
;;;; Lexter has no single umbrella package: its subsystems each have their own
;;;; (lexter/atlas, lexter/model, lexter/grid, lexter/vt-handler, ...). The test
;;;; package uses none of them and names their symbols by package, so that a
;;;; reader sees which subsystem each operation comes from; internals reached
;;;; with :: are first-edition state that LEXTER-D106 allows tests to inspect.

(defpackage #:lexter-tests
  (:use #:cl)
  ;; Import FiveAM symbols explicitly to avoid package-lock conflicts
  ;; (Square.md §5).
  (:import-from #:fiveam
                #:def-suite #:in-suite #:def-test #:test
                #:is #:is-true #:is-false #:signals #:finishes
                #:pass #:fail
                #:explain! #:results-status #:run #:run!)
  (:import-from #:hamcrest/fiveam
                #:assert-that)
  (:import-from #:hamcrest/matchers
                #:has-length
                #:contains)
  (:export
   #:run-all-tests
   #:run-suite))
