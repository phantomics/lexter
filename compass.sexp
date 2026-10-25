;;; compass.sexp — Compass project manifest for Lexter
;;;
;;; Read by the compass toolchain with a restricted reader: strings, integers,
;;; keywords, and lists only. See COMPASS-DRAFT-toolchain-D4 and D15 in the
;;; Compass repository.

(:namespaces ("LEXTER")
 :doc-directory "doc/"
 :federation ((:namespace "COMPASS" :path "../../lisp/compass")
              (:namespace "CLASSIC" :path "../../lisp/classic")
              (:namespace "ORIGIN" :path "../../lisp/origin"))
 :commands ((:name :test-mouse :repl "(asdf:test-system \"lexter/mouse-tests\")"
             :doc "Run the mouse-reporting tests (no display needed)")
            (:name :test-origin :repl "(asdf:test-system \"lexter/origin-tests\")"
             :doc "Run the Origin and Impulse integration tests"))
 :stewards ((:namespace "LEXTER" :steward "Andrew Sengul" :approval :solo)))
