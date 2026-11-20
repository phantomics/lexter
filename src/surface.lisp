(in-package #:lexter/surface)

;;;; The API: records written by Lexter's own writers
;;;;
;;;; Chrome, decorators, function panes, and Common Lisp applications write
;;;; cells through these calls, which write records of the plain format, and,
;;;; on a surface, the text cells beside them (LEXTER-D124). They take
;;;; codepoints, looked up in the target's atlas at the width the caller asks
;;;; for, by default the glyph's natural width (LEXTER-D117), or atlas
;;;; positions; a glyph that is wide is written as two halves, each naming the
;;;; atlas column it draws, so that callers never write halves by hand
;;;; (LEXTER-D126). A TARGET is a surface or the composed grid itself, which
;;;; keeps no text. A surface reaches the composed grid by COMPOSE-SURFACE,
;;;; which copies its rows (LEXTER-D107).
;;;;
;;;; While *CHECK-RECORDS* is true, as it is in debugging builds, every record
;;;; written is checked against the invariants of a record (LEXTER-D130).

;;; --------------------------------------------------------------------------
;;; Glyphs
;;; --------------------------------------------------------------------------

(defun %wide-glyph-p (target glyph)
  "True when GLYPH, an atlas position, begins a wide entry of TARGET's atlas."
  (let ((atlas (display-grid-atlas target)))
    (and atlas (lexter/atlas:atlas-glyph-wide-p atlas glyph) t)))

(defun char-glyph (target char &optional width)
  "The atlas position of CHAR, a character or codepoint, in TARGET's atlas, at
   WIDTH, 1 or 2, or by default its glyph's natural width (LEXTER-D117); the
   \"no glyph\" glyph for a character no font covers (LEXTER-D122). The second
   value is the width it is drawn at."
  (let* ((codepoint (if (characterp char) (char-code char) char))
         (atlas (display-grid-atlas target))
         (glyph (and atlas (lexter/atlas:atlas-glyph-index atlas codepoint width))))
    (cond (glyph (values glyph (if (lexter/atlas:atlas-glyph-wide-p atlas glyph) 2 1)))
          (t (values lexter/atlas:+no-glyph-position+ (or width 1))))))

;;; --------------------------------------------------------------------------
;;; Writing one cell's records and text
;;; --------------------------------------------------------------------------

(defun %set-text (target col row content wide)
  "Write the text cell at COL, ROW of TARGET, when it is a surface."
  (when (surface-p target)
    (write-text-cell (surface-text target) (cell-index target col row)
                     :content content :wide (if wide 1 0))))

(defun %break-pair (target col row)
  "Before the cell at COL, ROW of TARGET is written, empty the other half of
   the double-width glyph it is half of, keeping its swatch, so that no half
   is left alone (LEXTER-D126)."
  (let ((records (display-grid-records target)))
    (flet ((empty (c)
             (let ((index (cell-index target c row)))
               (write-plain-record records index
                 :swatch (read-record-common records index :swatch)
                 :palette-slot (read-record-common records index :palette-slot))
               (%set-text target c row 0 nil)
               (touch-row target row))))
      (cond ((and (continuation-p target col row) (plusp col))
             (empty (1- col)))
            ((and (wide-left-p target col row) (< (1+ col) (display-grid-cols target)))
             (empty (1+ col)))))))

(defun %check (target col row pair)
  (when *check-records*
    (check-record (display-grid-records target) (cell-index target col row)
                  :pair pair
                  :wide-first-column-p (lambda (glyph) (%wide-glyph-p target glyph)))))

(defun %write-glyphs (target col row glyphs &key (swatch 0) (background-slot 0)
                                                 (content 0) blink)
  "Write GLYPHS, a list of glyph words each (kind glyph selector slot-or-op
   reach), KIND :LAYER or :MASK, as the cell at COL, ROW of TARGET, with
   SWATCH, BACKGROUND-SLOT, and BLINK, and CONTENT as its text. When any glyph
   begins a wide entry of the atlas and the next column is in TARGET, the
   cell is written as two halves, each glyph word of the right half naming
   the glyph's second column if it is wide, and itself if it is narrow
   (LEXTER-D126). Return the columns written, 1 or 2."
  (let* ((records (display-grid-records target))
         (cols (display-grid-cols target))
         (wide (and (some (lambda (g) (%wide-glyph-p target (second g))) glyphs)
                    (< (1+ col) cols)))
         (palette-slot (display-grid-palette-slot target)))
    (%break-pair target col row)
    (when wide
      (%break-pair target (1+ col) row))
    (flet ((write-half (c right)
             (let ((index (cell-index target c row)))
               (write-plain-record records index
                 :glyph-count (length glyphs) :swatch swatch :palette-slot palette-slot
                 :background-slot background-slot :blink (if blink 1 0)
                 :wide (if wide 1 0) :right-half (if right 1 0))
               (loop :for (kind glyph selector setting reach) :in glyphs
                     :for i :from 0
                     :for named = (if (and right (%wide-glyph-p target glyph)) (1+ glyph) glyph)
                     :do (ecase kind
                           (:layer
                            (when (plusp i)
                              (%set-type-bit records index i 0))
                            (setf (record-glyph records index i) named
                                  (record-selector records index i) selector
                                  (record-ink-slot records index i) setting))
                           (:mask
                            (%set-type-bit records index i 1)
                            (%set-mask records index i named selector setting reach)))))))
      (write-half col nil)
      (%set-text target col row content wide)
      (when wide
        (write-half (1+ col) t)
        (%set-text target (1+ col) row +continuation-marker+ t)))
    (touch-row target row)
    (%check target col row wide)
    (if wide 2 1)))

(defun %set-type-bit (records index i bit)
  (ecase i
    (1 (patch-plain-record records index :type-1 bit))
    (2 (patch-plain-record records index :type-2 bit))
    (3 (patch-plain-record records index :type-3 bit))
    (4 (patch-plain-record records index :type-4 bit))
    (5 (patch-plain-record records index :type-5 bit))))

(defun %set-mask (records index i glyph selector operation reach)
  (ecase i
    (1 (patch-plain-record records index (:g1 :glyph) glyph (:g1 :selector) selector
                           (:g1 :operation) operation (:g1 :reach) reach))
    (2 (patch-plain-record records index (:g2 :glyph) glyph (:g2 :selector) selector
                           (:g2 :operation) operation (:g2 :reach) reach))
    (3 (patch-plain-record records index (:g3 :glyph) glyph (:g3 :selector) selector
                           (:g3 :operation) operation (:g3 :reach) reach))
    (4 (patch-plain-record records index (:g4 :glyph) glyph (:g4 :selector) selector
                           (:g4 :operation) operation (:g4 :reach) reach))
    (5 (patch-plain-record records index (:g5 :glyph) glyph (:g5 :selector) selector
                           (:g5 :operation) operation (:g5 :reach) reach))))

;;; --------------------------------------------------------------------------
;;; The calls
;;; --------------------------------------------------------------------------

(defun put-char (target col row char &key (swatch 0) (ink-slot 1) (background-slot 0)
                                          width underline blink)
  "Write CHAR, a character or codepoint, at COL, ROW of TARGET, in INK-SLOT
   over BACKGROUND-SLOT of SWATCH, at WIDTH, by default its glyph's natural
   width; with UNDERLINE, cut by the single underline as a mask in its colour
   (LEXTER-D88); with BLINK, blinking (LEXTER-D94). Return the columns it
   takes, 1 or 2."
  (let ((codepoint (if (characterp char) (char-code char) char))
        (glyph (char-glyph target char width)))
    (%write-glyphs target col row
                   (cons (list :layer glyph 0 ink-slot 0)
                         (and underline
                              (list (list :mask (lexter/atlas:line-glyph-position 0 1)
                                          0 :union 0))))
                   :swatch swatch :background-slot background-slot
                   :content codepoint :blink blink)))

(defun put-string (target col row string &key (swatch 0) (ink-slot 1) (background-slot 0)
                                              underline blink)
  "Write the characters of STRING from COL, ROW of TARGET, each at its
   natural width, as PUT-CHAR does, as far as the row reaches. Return the
   column after the last written."
  (let ((c col)
        (cols (display-grid-cols target)))
    (loop :for char :across string
          :while (< c cols)
          :do (incf c (put-char target c row char :swatch swatch :ink-slot ink-slot
                                                  :background-slot background-slot
                                                  :underline underline :blink blink)))
    c))

(defun put-glyph (target col row glyph &key (swatch 0) (ink-slot 1) (background-slot 0)
                                            (content 0))
  "Write GLYPH, an atlas position, at COL, ROW of TARGET, as one layer in
   INK-SLOT over BACKGROUND-SLOT of SWATCH, two halves when it is wide; its
   text is CONTENT, by default none. Return the columns it takes."
  (%write-glyphs target col row (list (list :layer glyph 0 ink-slot 0))
                 :swatch swatch :background-slot background-slot :content content))

(defun %glyph-word (target spec)
  "The glyph word that SPEC describes, as %WRITE-GLYPHS takes it, and its
   codepoint, or NIL."
  (destructuring-bind (kind &key char glyph (selector 0) (ink-slot 1)
                                 (operation :union) (reach 0))
      spec
    (let ((position (or glyph (char-glyph target char)))
          (codepoint (and char (if (characterp char) (char-code char) char))))
      (values (ecase kind
                (:layer (list :layer position selector ink-slot 0))
                (:mask (list :mask position selector operation reach)))
              codepoint))))

(defun put-cell (target col row specs &key (swatch 0) (background-slot 0) text blink)
  "Write one cell of several glyphs at COL, ROW of TARGET: SPECS is a list of
   glyph words in order, each a layer followed by the masks that cut it
   (LEXTER-D85), as (:LAYER &key char glyph selector ink-slot) or
   (:MASK &key char glyph selector operation reach), naming the glyph by a
   character or an atlas position. The cell is two halves when any glyph is
   wide, each half drawing its own column of a wide glyph and the whole of a
   narrow one (LEXTER-D126). Its text is TEXT, by default the character of its
   last layer named by one. Return the columns it takes."
  (let ((words '())
        (last-char nil))
    (dolist (spec specs)
      (multiple-value-bind (word codepoint) (%glyph-word target spec)
        (push word words)
        (when (and codepoint (eq (first spec) :layer))
          (setf last-char codepoint))))
    (%write-glyphs target col row (nreverse words)
                   :swatch swatch :background-slot background-slot :blink blink
                   :content (cond ((characterp text) (char-code text))
                                  (text)
                                  (last-char)
                                  (t 0)))))

(defun fill-cells (target col row cols rows &key (swatch 0) (background-slot 0))
  "Make the COLS by ROWS cells from COL, ROW of TARGET solid, with no glyphs,
   in BACKGROUND-SLOT of SWATCH, and their text empty (LEXTER-D86)."
  (loop :for r :from row :below (min (+ row rows) (display-grid-rows target))
        :do (loop :for c :from col :below (min (+ col cols) (display-grid-cols target))
                  :do (%break-pair target c r)
                      (write-plain-record (display-grid-records target) (cell-index target c r)
                        :swatch swatch :palette-slot (display-grid-palette-slot target)
                        :background-slot background-slot)
                      (%set-text target c r 0 nil))
            (touch-row target r)))

(defun clear-cells (target col row cols rows)
  "Make the COLS by ROWS cells from COL, ROW of TARGET records of zeros, blank
   in global swatch 0, with their text empty."
  (fill-cells target col row cols rows))

;;; --------------------------------------------------------------------------
;;; Reading a surface's text
;;; --------------------------------------------------------------------------

(defun surface-char (surface col row)
  "The content of the text cell at COL, ROW of SURFACE: its codepoint, 0 when
   it is empty, or the continuation marker."
  (read-text-cell (surface-text surface) (cell-index surface col row) :content))

(defun surface-string (surface row &key (start 0) end)
  "The text of ROW of SURFACE from column START to END, without the
   continuations of wide characters, empty cells as spaces."
  (with-output-to-string (out)
    (loop :for col :from start :below (or end (display-grid-cols surface))
          :for content = (surface-char surface col row)
          :unless (= content +continuation-marker+)
            :do (write-char (if (zerop content) #\Space (code-char content)) out))))

;;; --------------------------------------------------------------------------
;;; Composing a surface into the grid
;;; --------------------------------------------------------------------------

(defun compose-surface (surface grid col row &key (cols (display-grid-cols surface))
                                                  (rows (display-grid-rows surface)))
  "Copy the records of SURFACE's first COLS by ROWS cells into GRID with its
   origin at COL, ROW, as far as GRID reaches, unchanged: they hold global
   swatch indices and their own palette slot (LEXTER-D107, LEXTER-D100). Each
   row of GRID written takes a new stamp. A wide glyph whose right half falls
   past what is copied loses its pair, its left half drawn narrow."
  (let* ((width (min cols (display-grid-cols surface) (max 0 (- (display-grid-cols grid) col))))
         (height (min rows (display-grid-rows surface) (max 0 (- (display-grid-rows grid) row)))))
    (when (plusp width)
      (dotimes (r height)
        (copy-records (display-grid-records surface) (cell-index surface 0 r)
                      (display-grid-records grid) (cell-index grid col (+ row r)) width)
        (when (wide-left-p grid (+ col width -1) (+ row r))
          (patch-record-common (display-grid-records grid) (cell-index grid (+ col width -1) (+ row r))
                               :wide 0))
        (touch-row grid (+ row r))))
    grid))
