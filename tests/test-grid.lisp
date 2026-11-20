;;;; tests/test-grid.lisp — The flush into the display grid, and its buffers.
;;;;
;;;; Pure: screens flushed into display grids in memory, and instance buffers
;;;; built as byte arrays; nothing is uploaded, and no GL. They cover the
;;;; flush, the cursor, and the grid's operations (LEXTER-O19, LEXTER-O26,
;;;; LEXTER-O28; LEXTER-D98, LEXTER-D101). The tests of LEXTER-O27, of layered
;;;; cells in a screen, were retired when screens stopped holding them
;;;; (LEXTER-D124); their invariants return with the API's surfaces.

(in-package #:lexter-tests)
(in-suite grid)

;;; ------------------------------------------------------------
;;; Double-width glyphs  (LEXTER-O19, LEXTER-O26)
;;; ------------------------------------------------------------

(def-test flush-keeps-wide-pair ()
  "LEXTER-O19: flushing a double-width character marks its left cell wide and
its right cell as the continuation in the grid."
  (with-clean-terminal ()
    (write-wide 0 0)
    (flush)
    (is (= (glyph *atlas* #x4E00) (grid-glyph *grid* 0 0)))
    (is-true (grid-wide-p *grid* 0 0))
    (is-true (grid-continuation-p *grid* 1 0))))

(def-test cursor-on-wide-cell-keeps-pair ()
  "LEXTER-O19: drawing the cursor on a double-width character keeps it a pair
in the grid."
  (with-clean-terminal ()
    (write-wide 0 0)
    (lexter/model:set-cursor-position *screen* 0 0)
    (flush :cursor-visible t)
    (is-true (grid-wide-p *grid* 0 0))
    (is-true (grid-continuation-p *grid* 1 0))))

(def-test resize-grid-keeps-wide-pair ()
  "LEXTER-O26: resizing the grid keeps the wide and continuation flags of the
cells that remain."
  (let ((grid (lexter/grid:make-display-grid :cols 10 :rows 2 :atlas (make-test-atlas))))
    (lexter/surface:put-char grid 0 0 (code-char #x4E00))
    (lexter/grid:resize-grid grid 12 2)
    (is-true (grid-wide-p grid 0 0))
    (is-true (grid-continuation-p grid 1 0))))

;;; ------------------------------------------------------------
;;; Blanks  (LEXTER-O28)
;;; ------------------------------------------------------------

(def-test clear-grid-writes-the-empty-glyph ()
  "LEXTER-O28: clearing the grid fills it with the atlas's empty glyph at
position 0, not with codepoint 32."
  (let ((grid (make-test-grid :cols 4 :rows 2)))
    (lexter/panes:clear-grid grid)
    (dotimes (row 2)
      (dotimes (col 4)
        (is (= 0 (grid-glyph grid col row)) "cell ~d,~d" col row)))))

;;; ------------------------------------------------------------
;;; Records built from text and styles  (LEXTER-D124, LEXTER-D125)
;;; ------------------------------------------------------------

(defun grid-records-of (grid)
  "Every record of GRID, as a list of (col row plist)."
  (loop :for row :below (lexter/grid:display-grid-rows grid)
        :nconc (loop :for col :below (lexter/grid:display-grid-cols grid)
                     :collect (list col row (grid-record grid col row)))))

(def-test a-character-is-built-as-one-layer ()
  "A character is built as a record of the plain format with one glyph layer,
its glyph in ink slot 1 over background slot 0 of its style's swatch, in the
terminal's palette slot (LEXTER-D83, LEXTER-D87)."
  (with-clean-terminal ()
    (write-coloured *screen* 0 0 #x41 0 4)
    (lexter/model:set-cursor-visible *screen* nil)
    (lexter/model:flush-to-display *screen* *grid* :atlas *atlas* :palette-slot 3)
    (let ((record (grid-record *grid* 0 0)))
      (is (= 1 (getf record :glyph-count)))
      (is (= (glyph *atlas* #x41) (getf (getf record :g0) :glyph)))
      (is (= 1 (getf (getf record :g0) :ink-slot)))
      (is (= 0 (getf record :background-slot)))
      (is (= 3 (getf record :palette-slot)))
      (is (= (intern-colours *screen* 0 4) (getf record :swatch))))))

(def-test reverse-video-is-built-through-the-background-slot ()
  "Reverse video is built as the background slot 1 and the text's ink slot 0,
within the same swatch as the text without it, so a reversed cell interns no
swatch of its own (LEXTER-D86, LEXTER-O24)."
  (with-clean-terminal ()
    (feed (csi "31m") "A" (csi "7m") "A")
    (flush)
    (let ((plain (grid-record *grid* 0 0))
          (reversed (grid-record *grid* 1 0)))
      (is (= (getf plain :swatch) (getf reversed :swatch)))
      (is (= 1 (getf reversed :background-slot)))
      (is (= 0 (getf (getf reversed :g0) :ink-slot))))))

(def-test invisible-text-is-built-with-no-glyphs ()
  "Invisible text (SGR 8) is built with a glyph count of 0, in its colours,
and its characters are kept in the text grid (LEXTER-D83)."
  (with-clean-terminal ()
    (feed (csi "8;41m") "A")
    (flush)
    (is (= #x41 (screen-char *screen* 0 0)))
    (is (= 0 (getf (grid-record *grid* 0 0) :glyph-count)))
    (is (equal '(1 7 7 0) (grid-cell-colours *grid* 0 0)))))

(def-test an-underline-is-a-mask-in-the-text-s-colour ()
  "An underlined character is built with the single underline, line glyph 9,
as a union mask on its glyph, so that it takes the text's colour
(LEXTER-D88, LEXTER-D89)."
  (with-clean-terminal ()
    (feed (csi "4m") "A")
    (flush)
    (let ((record (grid-record *grid* 0 0)))
      (is (= 2 (getf record :glyph-count)))
      (is (= 1 (getf record :type-1)))
      (is (= (lexter/atlas:line-glyph-position 0 1) (getf (getf record :g1) :glyph)))
      (is (eq :union (getf (getf record :g1) :operation)))
      (is (= 0 (getf (getf record :g1) :reach))))))

(def-test blinking-text-carries-the-blink-flag ()
  "Blinking text (SGR 5) is built with the blink flag, and nothing else in its
record changes as it blinks (LEXTER-D94)."
  (with-clean-terminal ()
    (feed (csi "5m") "A" (csi "25m") "B")
    (flush)
    (is (= 1 (getf (grid-record *grid* 0 0) :blink)))
    (is (= 0 (getf (grid-record *grid* 1 0) :blink)))))

(def-test a-wide-character-is-built-as-two-halves ()
  "A double-width character is built as two halves, both wide and the second
the right half, each naming the atlas column it draws: the right half the
glyph's position plus 1; a narrow glyph drawn wide, as the \"no glyph\"
glyph, names itself in both (LEXTER-D103, LEXTER-D126)."
  (with-clean-terminal ()
    (feed (string (code-char #x4E00)) (string (code-char #x1F600)))
    (flush)
    (let ((records (lexter/grid:display-grid-records *grid*))
          (wide (glyph *atlas* #x4E00)))
      (is (= wide (grid-glyph *grid* 0 0)))
      (is (= (1+ wide) (grid-glyph *grid* 1 0)))
      (is-true (grid-continuation-p *grid* 1 0))
      (is (null (lexter/manifests:half-pair-violations
                 records 0 :wide-first-column-p (lambda (g) (= g wide)))))
      (is (= lexter/atlas:+no-glyph-position+ (grid-glyph *grid* 2 0)))
      (is (= lexter/atlas:+no-glyph-position+ (grid-glyph *grid* 3 0)))
      (is (null (lexter/manifests:half-pair-violations records 2))))))

(def-test built-records-keep-the-invariants ()
  "Every record built from a terminal's text keeps the invariants of a record
(LEXTER-0016, Invariants of a record)."
  (with-clean-terminal (:cols 10 :rows 3)
    (feed "A" (csi "4;7m") "B" (csi "0;5;8m") "C" (csi "0m") (string (code-char #x4E00))
          (csi "4m") (string (code-char #x4E00)))
    (flush :cursor-visible t)
    (let ((records (lexter/grid:display-grid-records *grid*)))
      (dotimes (index (lexter/manifests:record-array-count records))
        (is (null (lexter/manifests:record-invariant-violations records index))
            "record ~d" index)))))

;;; ------------------------------------------------------------
;;; The interim cursor  (LEXTER-D101)
;;; ------------------------------------------------------------

(def-test the-cursor-exchanges-the-background-and-the-topmost-ink ()
  "The cursor is drawn by exchanging its cell's background slot with its
topmost layer's ink slot, past any mask, and keeping its swatch; on a cell
with no glyph it takes slot 1 as the background (LEXTER-D101)."
  (with-clean-terminal ()
    (feed (csi "4m") "A")
    (lexter/model:set-cursor-position *screen* 0 0)
    (flush :cursor-visible t)
    (let ((record (grid-record *grid* 0 0)))
      (is (= 1 (getf record :background-slot)))
      (is (= 0 (getf (getf record :g0) :ink-slot)))
      (is (= 2 (getf record :glyph-count))))
    (lexter/model:set-cursor-position *screen* 5 0)
    (flush :cursor-visible t)
    (is (= 0 (getf (grid-record *grid* 0 0) :background-slot)))
    (is (= 1 (getf (grid-record *grid* 5 0) :background-slot)))))

(def-test the-cursor-on-a-wide-character-changes-both-halves ()
  "The cursor on either half of a double-width character exchanges the slots
of both halves, so that the halves still match (LEXTER-D126)."
  (with-clean-terminal ()
    (write-wide 0 0)
    (lexter/model:set-cursor-position *screen* 1 0)
    (flush :cursor-visible t)
    (is (= 1 (getf (grid-record *grid* 0 0) :background-slot)))
    (is (= 1 (getf (grid-record *grid* 1 0) :background-slot)))
    (is (null (lexter/manifests:half-pair-violations
               (lexter/grid:display-grid-records *grid*) 0)))))

;;; ------------------------------------------------------------
;;; Drawn rows  (LEXTER-D113)
;;; ------------------------------------------------------------

(def-test writing-a-record-stamps-its-row ()
  "Writing a record gives its row a change stamp newer than any taken before,
from one counter, and leaves the other rows' stamps as they were; touching
every row makes each newer than before (LEXTER-D113)."
  (let* ((grid (make-test-grid :cols 4 :rows 3))
         (before (loop :for row :below 3 :collect (lexter/grid:row-stamp grid row))))
    (lexter/grid:write-text-record grid 1 1 :glyph 70)
    (is (> (lexter/grid:row-stamp grid 1) (second before)))
    (is (= (first before) (lexter/grid:row-stamp grid 0)))
    (is (= (third before) (lexter/grid:row-stamp grid 2)))
    (let ((stamp (lexter/grid:row-stamp grid 1)))
      (lexter/grid:touch-all-rows grid)
      (dotimes (row 3)
        (is (> (lexter/grid:row-stamp grid row) stamp))))))

(def-test a-resized-grid-is-newer-in-every-row ()
  "Resizing a grid gives every row a new stamp, so that every reader takes the
whole grid again (LEXTER-D113)."
  (let* ((grid (make-test-grid :cols 4 :rows 2))
         (stamp (lexter/grid:row-stamp grid 1)))
    (lexter/grid:resize-grid grid 5 3)
    (dotimes (row 3)
      (is (> (lexter/grid:row-stamp grid row) stamp)))))

;;; ------------------------------------------------------------
;;; Uploads and clocks  (LEXTER-D113, LEXTER-O40)
;;; ------------------------------------------------------------

(def-test a-renderer-takes-a-new-grid-whole ()
  "A renderer uploads the whole of a grid it has not drawn, and of a grid it
has drawn whose size has changed (LEXTER-D113)."
  (let ((grid (make-test-grid :cols 4 :rows 3))
        (state (lexter/grid:make-record-upload-state)))
    (multiple-value-bind (spans whole) (lexter/grid:plan-record-uploads grid state)
      (is-true whole)
      (is (equal '((0 3)) spans)))
    (lexter/grid:resize-grid grid 5 3)
    (is-true (nth-value 1 (lexter/grid:plan-record-uploads grid state)))
    (is-true (nth-value 1 (lexter/grid:plan-record-uploads (make-test-grid :cols 5 :rows 3)
                                                          state)))))

(def-test a-renderer-uploads-only-the-rows-written ()
  "LEXTER-O40: a renderer that has taken a grid uploads again only the runs of
rows written since, as their change stamps show, and nothing when none was;
the grid keeps no dirty bits for a reader to clear (LEXTER-D113)."
  (let ((grid (make-test-grid :cols 4 :rows 5))
        (state (lexter/grid:make-record-upload-state)))
    (lexter/grid:plan-record-uploads grid state)
    (is (null (lexter/grid:plan-record-uploads grid state)))
    (lexter/grid:write-text-record grid 0 1 :glyph 70)
    (lexter/grid:write-text-record grid 3 2 :glyph 70)
    (lexter/grid:write-text-record grid 1 4 :glyph 70)
    (multiple-value-bind (spans whole) (lexter/grid:plan-record-uploads grid state)
      (is-false whole)
      (is (equal '((1 2) (4 1)) spans)))
    (is (null (lexter/grid:plan-record-uploads grid state)))))

(def-test two-renderers-take-a-grid-each-for-itself ()
  "Each renderer keeps the stamps it took, so a row one renderer uploads is
still new to another that has not taken it (LEXTER-D113)."
  (let ((grid (make-test-grid :cols 4 :rows 2))
        (first (lexter/grid:make-record-upload-state))
        (second (lexter/grid:make-record-upload-state)))
    (lexter/grid:plan-record-uploads grid first)
    (lexter/grid:plan-record-uploads grid second)
    (lexter/grid:write-text-record grid 0 1 :glyph 70)
    (is (equal '((1 1)) (lexter/grid:plan-record-uploads grid first)))
    (is (equal '((1 1)) (lexter/grid:plan-record-uploads grid second)))))

(def-test a-row-s-clock-mask-is-derived-from-its-records ()
  "A row's clock mask is derived from its records as the renderer takes it:
its blink bit is set while a cell in it blinks, and cleared once none does;
writers never write it (LEXTER-D113, LEXTER-D94)."
  (with-clean-terminal (:cols 4 :rows 2)
    (let ((state (lexter/grid:make-record-upload-state)))
      (feed (csi "5m") "A" (csi "25m"))
      (flush)
      (lexter/grid:plan-record-uploads *grid* state)
      (is (= lexter/grid:+clock-blink+ (aref (lexter/grid:display-grid-clock-masks *grid*) 0)))
      (is (= 0 (aref (lexter/grid:display-grid-clock-masks *grid*) 1)))
      (feed (csi "1;1H") "B")
      (flush)
      (lexter/grid:plan-record-uploads *grid* state)
      (is (= 0 (aref (lexter/grid:display-grid-clock-masks *grid*) 0))))))

(def-test the-grid-holds-records-only ()
  "LEXTER-D129: the composed grid holds its records in one array of bytes,
beside its drawn rows, and none of the first edition's per-cell arrays or
layered cells."
  (let ((slots (mapcar (lambda (slot) (symbol-name (sb-mop:slot-definition-name slot)))
                       (sb-mop:class-slots (find-class 'lexter/grid:display-grid)))))
    (dolist (name '("GLYPHS" "SWATCH-INDICES" "WIDE-FLAGS" "CONTINUATION-FLAGS"
                    "LAYERED-CELLS" "LAYERED-FLAGS" "ROW-DIRTY"))
      (is (null (member name slots :test #'string=)) "slot ~a" name))
    (is (member "RECORDS" slots :test #'string=))
    (is (member "STAMPS" slots :test #'string=))))
