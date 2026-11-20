;;;; tests/test-checksums.lisp — The cell checksum, and terminals without a window.
;;;;
;;;; Pure: grids, stores, and palettes in memory, and standalone terminals
;;;; composed without a window or GL context, in the in-memory font. They cover
;;;; the cell checksum that each fixture records beside its pixel checksum
;;;; (LEXTER-D108): what its normalisation ignores, what it sees, and that a
;;;; replay computes it on a machine with no display.

(in-package #:lexter-tests)
(in-suite checksums)

(defun default-palettes ()
  "The palettes of a grid whose cells draw in slot 0 alone."
  (list (cons 0 (lexter/swatches:make-default-palette))))

(defun checksum-of (grid store &optional (palettes (default-palettes)))
  (lexter/test:cell-checksum grid store palettes))

(defun two-cell-grid (first second)
  "A grid of two cells, A in global swatch FIRST and B in global swatch SECOND."
  (let ((grid (lexter/grid:make-display-grid :cols 2 :rows 1 :atlas (make-test-atlas))))
    (lexter/surface:put-char grid 0 0 #\A :swatch first)
    (lexter/surface:put-char grid 1 0 #\B :swatch second)
    grid))

(def-test the-cell-checksum-ignores-the-order-of-interning ()
  "LEXTER-D108: two grids whose cells draw the same colours have the same cell
checksum though their swatches were interned in opposite orders and have
different indices, since each swatch counts as the palette indices it
resolves to."
  (let* ((one (lexter/swatches:make-swatch-store))
         (other (lexter/swatches:make-swatch-store))
         (t1 (lexter/swatches:swatch-store-display-table one))
         (t2 (lexter/swatches:swatch-store-display-table other))
         (a1 (lexter/swatches:intern-swatch t1 3 9 9 0))
         (b1 (lexter/swatches:intern-swatch t1 4 10 10 0))
         (b2 (lexter/swatches:intern-swatch t2 4 10 10 0))
         (a2 (lexter/swatches:intern-swatch t2 3 9 9 0)))
    (is (/= a1 a2))
    (is (= (checksum-of (two-cell-grid a1 b1) one)
           (checksum-of (two-cell-grid a2 b2) other)))))

(def-test the-cell-checksum-ignores-what-no-format-defines ()
  "LEXTER-D108: a reserved bit set and a glyph word beyond the glyph count
written, as a careless writer might leave them, leave the cell checksum as it
was, since the shader ignores them and the picture is unchanged."
  (let* ((store (lexter/swatches:make-swatch-store))
         (table (lexter/swatches:swatch-store-display-table store))
         (a (lexter/swatches:intern-swatch table 3 9 9 0))
         (grid (two-cell-grid a a))
         (records (lexter/grid:display-grid-records grid))
         (before (checksum-of grid store)))
    ;; The parameters byte, reserved in the plain format, and the last byte of
    ;; glyph word 5, beyond the glyph count of one
    (setf (aref records 3) 5
          (aref records 31) 9)
    (is (= before (checksum-of grid store)))))

(def-test the-cell-checksum-sees-every-field-drawn ()
  "LEXTER-D108: a change of any field the renderer reads changes the cell
checksum: a glyph, an ink slot, the palette slot, the background slot, the
blink flag, and a palette index of the cell's swatch."
  (let* ((store (lexter/swatches:make-swatch-store))
         (table (lexter/swatches:swatch-store-display-table store))
         (a (lexter/swatches:intern-swatch table 3 9 9 0))
         (c (lexter/swatches:intern-swatch table 3 9 11 0)))
    (flet ((changed (change)
             (let* ((grid (two-cell-grid a a))
                    (before (checksum-of grid store)))
               (funcall change grid (lexter/grid:display-grid-records grid))
               (/= before (checksum-of grid store)))))
      (is-true (changed (lambda (grid records)
                          (declare (ignore records))
                          (lexter/surface:put-char grid 1 0 #\A :swatch a))))
      (is-true (changed (lambda (grid records)
                          (declare (ignore grid))
                          (setf (lexter/manifests:record-ink-slot records 0 0) 2))))
      (is-true (changed (lambda (grid records)
                          (declare (ignore grid))
                          (lexter/manifests:patch-record-common records 0 :palette-slot 1))))
      (is-true (changed (lambda (grid records)
                          (declare (ignore grid))
                          (lexter/manifests:patch-record-common records 0 :background-slot 1))))
      (is-true (changed (lambda (grid records)
                          (declare (ignore grid))
                          (lexter/manifests:patch-record-common records 0 :blink 1))))
      (is-true (changed (lambda (grid records)
                          (declare (ignore grid))
                          (lexter/manifests:patch-record-common records 0 :swatch c)))))))

(def-test the-cell-checksum-sees-the-palettes-drawn-in ()
  "LEXTER-D108: a colour changed in a palette that a cell draws in changes the
cell checksum, as OSC 4 changes it; a palette that no cell draws in does not
count."
  (let* ((store (lexter/swatches:make-swatch-store))
         (table (lexter/swatches:swatch-store-display-table store))
         (a (lexter/swatches:intern-swatch table 3 9 9 0))
         (grid (two-cell-grid a a))
         (changed (lexter/swatches:make-default-palette))
         (before (checksum-of grid store)))
    (lexter/manifests:write-palette-texel changed 9 0 255 0)
    (is (/= before (checksum-of grid store (list (cons 0 changed)))))
    (is (= before (checksum-of grid store (acons 5 changed (default-palettes)))))))

(def-test a-terminal-without-a-window-composes-its-screen ()
  "LEXTER-D108: a standalone terminal made without a window or GL context is
fed through its VT handler and composes its screen into its grid, so that a
fixture's cell checksum is computed on a machine with no display; a palette
the host changes changes the checksum."
  (with-clean-windowless-terminal (:cols 4 :rows 1)
    (let* ((comp (lexter/unix-term:unix-terminal-compositor *terminal*))
           (handler (lexter/unix-term:unix-terminal-vt-handler *terminal*))
           (atlas (lexter/panes:compositor-atlas comp)))
      (is (null (lexter/unix-term:unix-terminal-window *terminal*)))
      (lexter/vt-handler:process-output handler (octets "A"))
      (let ((grid (lexter/unix-term:terminal-compose *terminal*)))
        (is (= (glyph atlas #x41)
               (lexter/manifests:record-glyph (lexter/grid:display-grid-records grid) 0 0))))
      (let ((before (lexter/test:terminal-cell-checksum *terminal*)))
        (lexter/vt-handler:process-output handler (octets (format nil "~c]4;1;rgb:00/ff/00~c"
                                                                  #\Esc (code-char 7))))
        (lexter/unix-term:terminal-compose *terminal*)
        (is (/= before (lexter/test:terminal-cell-checksum *terminal*)))))))

(def-test a-terminal-without-a-window-keeps-its-atlas-columns ()
  "LEXTER-D108: the atlas of a terminal without a window is packed in the
column count its configuration fixes, which its configuration reports, so that
glyph positions do not depend on a GPU; without one, it cannot be made."
  (with-clean-windowless-terminal ()
    (let ((comp (lexter/unix-term:unix-terminal-compositor *terminal*)))
      (is (= 16 (lexter/atlas:atlas-cols (lexter/panes:compositor-atlas comp))))
      (is (= 16 (getf (lexter/unix-term:terminal-config-plist *terminal*) :atlas-cols)))))
  (signals error
    (lexter/unix-term:terminal-initialize-windowless
     (lexter/unix-term:make-terminal nil :no-pty t :fonts (list (make-test-font))))))

(def-test a-terminal-without-a-window-gives-back-its-palette-slot ()
  "A terminal without a window takes a palette slot as one with a window does,
and gives it back when it is destroyed (LEXTER-D92)."
  (let ((slots nil))
    (with-clean-windowless-terminal ()
      (setf slots (lexter/panes:compositor-palette-slots
                   (lexter/unix-term:unix-terminal-compositor *terminal*)))
      (is (eq (lexter/unix-term:unix-terminal-pane *terminal*)
              (lexter/swatches:palette-slot-owner slots 1))))
    (is (null (lexter/swatches:palette-slot-owner slots 1)))))
