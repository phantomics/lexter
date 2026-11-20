;;;; tests/test-structure.lisp — How the code is arranged.
;;;;
;;;; Structural tests of findings about the code's arrangement rather than its
;;;; behaviour (LEXTER-DRAFT-cell-model-revision-D21): they read Lexter's
;;;; source as text, or inspect its loaded functions. Pure: no GL, no writes.
;;;; They fail until Phase 1 repairs LEXTER-O36 and LEXTER-O40, Phase 2 gives
;;;; swatches one owner (LEXTER-D99), and the terminal-fixes plan the Origin
;;;; integration's reads of LEXTER-O29 (LEXTER-D70); the consolidation of the
;;;; two terminal stacks (LEXTER-D67) also removes one duplicate.

(in-package #:lexter-tests)
(in-suite structure)

(defparameter *cell-model-sources*
  '("src/pcf.lisp" "src/atlas.lisp" "src/grid.lisp" "src/swatches.lisp"
    "src/shaders.lisp" "src/renderer.lisp" "src/model.lisp")
  "The source files of the font, atlas, grid, swatch, renderer, and model layers.")

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

(def-test default-swatch-has-one-home ()
  "LEXTER-O36: the default swatch has one home, global swatch 0 of the display's
table, which every store makes for itself; no function sets swatches up in a
grid (LEXTER-DRAFT-cell-model-revision-D24)."
  (is (null (find "setup-default-swatches" (source-forms-named 'defun (all-sources))
                  :key #'car :test #'string=)))
  (assert-that (multiple-value-list
                (lexter/swatches:store-swatch (lexter/swatches:make-swatch-store) 0))
               (contains 0 7 7 0)))

(def-test the-grid-holds-no-swatches ()
  "LEXTER-D99: swatch tables have one owner, so the display grid keeps no copy
of them: it has no swatch data, no generation, and no SET-SWATCH, and no source
file defines or calls a SET-SWATCH."
  (is (null (find-if (lambda (slot)
                       (search "SWATCH-DATA" (symbol-name (sb-mop:slot-definition-name slot))))
                     (sb-mop:class-slots (find-class 'lexter/grid:display-grid)))))
  (is (null (find-symbol "SET-SWATCH" '#:lexter/grid)))
  (is (null (remove-if-not (lambda (path)
                             (search "(set-swatch " (uiop:read-file-string (source-path path))
                                     :test #'char-equal))
                           (all-sources)))))

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

(def-test terminal-modes-have-one-home ()
  "LEXTER-D78: the VT handler is the one home of terminal modes, so the screen
keeps no mode flags and the model exports no stubs that would set or read
them."
  (is (null (find-if (lambda (slot)
                       (string= "MODE-FLAGS" (symbol-name (sb-mop:slot-definition-name slot))))
                     (sb-mop:class-slots (find-class 'lexter/model:screen)))))
  (dolist (name '("SET-MODE" "GET-MODE"))
    (multiple-value-bind (symbol status) (find-symbol name '#:lexter/model)
      (declare (ignore symbol))
      (is (not (eq status :external))))))
