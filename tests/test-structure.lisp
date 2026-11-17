;;;; tests/test-structure.lisp — How the code is arranged.
;;;;
;;;; Structural tests of findings about the code's arrangement rather than its
;;;; behaviour (LEXTER-DRAFT-cell-model-revision-D21): they read Lexter's
;;;; source as text, or inspect its loaded functions. Pure: no GL, no writes.
;;;; They fail until Phase 1 repairs LEXTER-O36 and LEXTER-O40, and the
;;;; terminal-fixes plan the Origin integration's reads of LEXTER-O29
;;;; (LEXTER-D70); the consolidation of the two terminal stacks (LEXTER-D67)
;;;; also removes one duplicate.

(in-package #:lexter-tests)
(in-suite structure)

(defparameter *cell-model-sources*
  '("src/pcf.lisp" "src/atlas.lisp" "src/grid.lisp" "src/shaders.lisp"
    "src/renderer.lisp" "src/model.lisp")
  "The source files of the font, atlas, grid, renderer, and model layers.")

(defun all-sources ()
  "The paths, relative to the source tree, of every Lisp file under src/."
  (let ((root (asdf:system-source-directory :lexter)))
    (sort (mapcar (lambda (path) (enough-namestring path root))
                  (directory (merge-pathnames "src/**/*.lisp" root)))
          #'string<)))

(defun names-defined-in-several-files (definitions)
  "From DEFINITIONS, a list of (name . file), the names that more than one
file defines."
  (let ((files (make-hash-table :test 'equal)))
    (loop :for (name . file) :in definitions
          :do (pushnew file (gethash name files) :test #'string=))
    (sort (loop :for name :being :the :hash-keys :of files :using (hash-value in)
                :when (cdr in) :collect name)
          #'string<)))

(def-test cell-model-constants-have-one-home ()
  "LEXTER-O36: no constant is defined in more than one file of the model, grid,
and renderer, so that the layers cannot drift apart."
  (is (null (names-defined-in-several-files
             (source-forms-named 'defconstant *cell-model-sources*)))))

(def-test default-swatches-have-one-home ()
  "LEXTER-O36: the default swatches are set up by one function, defined once."
  (is (= 1 (count "setup-default-swatches"
                  (source-forms-named 'defun (all-sources))
                  :key #'car :test #'string=))))

(def-test one-default-palette ()
  "LEXTER-O36: the default palette is the same wherever it is made, so a
colour does not change when the first pane is focused."
  (is (equalp (lexter/model:make-default-palette)
              (lexter/panes::make-xterm-palette))))

(def-test origin-integration-reads-screens-through-the-handler ()
  "LEXTER-O29: the Origin integration reads a terminal's screen by asking its
VT handler for the active one, never through the standalone terminal's cached
screen slot, which holds the primary screen while the alternate one is shown
(LEXTER-D70)."
  (is-false (search "unix-terminal-screen"
                    (uiop:read-file-string (source-path "src/origin-impulse.lisp")))))

(def-test render-data-claims-no-incremental-rebuild ()
  "LEXTER-O40: building the render data takes no flag it ignores and claims no
incremental rebuild of dirty rows, since it rebuilds every instance."
  (is-false (member "FORCE-FULL"
                    (sb-introspect:function-lambda-list #'lexter/grid:build-render-data)
                    :key (lambda (x) (and (symbolp x) (symbol-name x)))
                    :test #'equal))
  (is-false (search "dirty rows"
                    (or (documentation 'lexter/grid:build-render-data 'function) "")
                    :test #'char-equal)))
