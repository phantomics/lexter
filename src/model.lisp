(in-package #:lexter/model)

;;;; Terminal Model
;;;;
;;;; This is the logical terminal state, independent of the display layer. A
;;;; screen holds what a terminal wrote, and no records (LEXTER-D124):
;;;;   - a text grid of 8-byte text cells, each a codepoint or a continuation
;;;;     marker, a style id, a wide bit, and a cluster flag (LEXTER-D127,
;;;;     LEXTER-D119), with the codepoints that joined a cell kept beside it;
;;;;   - a terminal row beside each row: its soft wrap, prompt kind, and line
;;;;     size (LEXTER-D119);
;;;;   - the terminal's styles, shared by its screens (styles.lisp);
;;;;   - the cursor, the scrolling region, and the history, kept as text and
;;;;     styles (LEXTER-D118).
;;;;
;;;; Its rows are built into the display grid from their text and styles by
;;;; one function, which builds the history's rows too (FLUSH-TO-DISPLAY).

;;; --------------------------------------------------------------------------
;;; Swatches and palettes
;;; --------------------------------------------------------------------------
;;;
;;; Swatch tables, their stores, and the default palette are in swatches.lisp
;;; (LEXTER-D99). A screen's table hands out the global indices that its rows
;;; are built in (LEXTER-D100). Palettes are RGBA bytes, as the GPU's integer
;;; store holds them (LEXTER-D109).

;;; --------------------------------------------------------------------------
;;; Screen buffer
;;; --------------------------------------------------------------------------

(defstruct (screen (:constructor %make-screen))
  "Terminal screen state."
  (cols      80  :type fixnum)
  (rows      24  :type fixnum)
  (mode      :unix :type keyword)  ; :unix, :3270, :application
  ;; --- Text, indexed by (row * cols + col) ---
  (text          (make-text-array 0) :type text-array)
  ;; The codepoints after the first of each cell whose cluster flag is set:
  ;; for each row, an alist of (column . codepoints) (LEXTER-D127)
  (clusters      #() :type simple-vector)
  ;; One terminal row for each row (LEXTER-D119)
  (terminal-rows (make-terminal-row-array 0) :type (simple-array (unsigned-byte 8) (*)))
  ;; --- Styles and swatch table: the terminal's, shared by its primary and
  ;; alternate screens (LEXTER-DRAFT-cell-model-revision-D24) ---
  (styles    nil :type (or null style-table))
  (swatches  nil :type (or null swatch-table))
  ;; --- Cursor state ---
  (cursor-col     0   :type fixnum)
  (cursor-row     0   :type fixnum)
  (cursor-visible t   :type boolean)
  (cursor-style   :block :type keyword)  ; :block, :underline, :bar
  (cursor-blink   nil :type boolean)
  ;; --- Scrolling region (VT only) ---
  (scroll-top    0    :type fixnum)
  (scroll-bottom 23   :type fixnum)  ; inclusive
  ;; --- Saved cursor (for DECSC/DECRC) ---
  (saved-cursor-col 0 :type fixnum)
  (saved-cursor-row 0 :type fixnum)
  ;; --- Scrollback: a ring of HISTORY-ROWs ---
  (scrollback-enabled t :type boolean)
  (scrollback-max   2000 :type fixnum)
  (scrollback-lines nil)
  (scrollback-count 0 :type fixnum)
  (scrollback-viewport 0 :type fixnum)  ; 0 = viewing live screen
  ;; --- Per-row dirty flags (for flush optimization) ---
  (row-dirty     #*  :type simple-bit-vector)
  ;; --- Color palette (256 RGBA colors as bytes, 1024 total) ---
  (palette nil :type (or null palette))
  (palette-generation 1 :type fixnum))

(defstruct (history-row (:constructor %make-history-row))
  "A row that left a screen's top: its text cells without the continuations
   of wide characters, the codepoints that joined its cells, by their place in
   it, and its terminal row (LEXTER-D118)."
  (text (make-text-array 0) :type text-array)
  (clusters nil :type list)
  (terminal-row (make-terminal-row-array 1) :type (simple-array (unsigned-byte 8) (1))))

;;; --------------------------------------------------------------------------
;;; Constructor
;;; --------------------------------------------------------------------------

(defun make-screen (&key (cols 80) (rows 24) (mode :unix)
                         (scrollback-max 2000) styles swatches palette)
  "Create a new screen whose text is written in styles of STYLES, a style
   table, and built in swatches of SWATCHES, a swatch table, and whose colours
   are PALETTE, a palette the screen copies. Without STYLES or SWATCHES the
   screen has tables of its own, the swatch table in a store of its own; a
   terminal's screens share their terminal's tables, the swatch table from the
   store of the compositor that draws them
   (LEXTER-DRAFT-cell-model-revision-D24). Without PALETTE the screen has the
   default palette. Every cell starts empty, in style 0."
  (%make-screen
   :cols            cols
   :rows            rows
   :mode            mode
   :text            (make-text-array (* cols rows))
   :clusters        (make-array rows :initial-element nil)
   :terminal-rows   (make-terminal-row-array rows)
   :styles          (or styles (make-style-table))
   :swatches        (or swatches (make-swatch-table (make-swatch-store)))
   :scroll-top      0
   :scroll-bottom   (1- rows)
   :scrollback-max  scrollback-max
   :scrollback-lines (make-array scrollback-max :initial-element nil)
   :row-dirty       (make-array rows :element-type 'bit :initial-element 1)
   :palette         (if palette (copy-seq palette) (make-default-palette))))

;;; --------------------------------------------------------------------------
;;; Palettes
;;; --------------------------------------------------------------------------

(defun set-palette-entry (screen idx r g b &optional (a 255))
  "Set palette entry IDX to the given RGBA bytes (0-255).
   Increments the palette generation for GPU sync."
  (write-palette-texel (screen-palette screen) idx r g b a)
  (incf (screen-palette-generation screen)))

(defun set-palette-entry-rgb8 (screen idx r g b)
  "Set palette entry IDX to the given RGB bytes (0-255), opaque.
   Increments the palette generation for GPU sync."
  (set-palette-entry screen idx r g b 255))

(defun get-palette-entry (screen idx)
  "Return the RGBA bytes of palette entry IDX as multiple values."
  (read-palette-texel (screen-palette screen) idx))

(defun reset-palette (screen)
  "Reset the screen's palette to the default xterm colors.
   Increments the palette generation for GPU sync."
  (replace (screen-palette screen) (make-default-palette))
  (incf (screen-palette-generation screen)))

;;; --------------------------------------------------------------------------
;;; Accessors
;;; --------------------------------------------------------------------------

(declaim (inline %idx %mark-dirty))

(defun %idx (screen col row)
  (+ (* row (screen-cols screen)) col))

(defun %mark-dirty (screen row)
  (when (< row (screen-rows screen))
    (setf (sbit (screen-row-dirty screen) row) 1)))

(defun any-row-dirty-p (screen)
  "Return T if any row in SCREEN is marked dirty."
  (not (zerop (count 1 (screen-row-dirty screen)))))

(defun mark-screen-dirty (screen)
  "Mark every row of SCREEN dirty so the next FLUSH-TO-DISPLAY repaints the
   whole screen. Used after an alternate-screen buffer swap, where the shared
   display grid still holds the previous buffer's content and must be fully
   re-copied from the now-active buffer."
  (fill (screen-row-dirty screen) 1)
  screen)

(defun default-swatch (screen)
  "The global index of the swatch of SCREEN's default colours: its table's
   default swatch, in which style 0 is built."
  (swatch-table-default (screen-swatches screen)))

;;; --------------------------------------------------------------------------
;;; Cursor accessors
;;; --------------------------------------------------------------------------

(defun cursor-col (screen) (screen-cursor-col screen))
(defun cursor-row (screen) (screen-cursor-row screen))
(defun cursor-visible-p (screen) (screen-cursor-visible screen))
(defun cursor-style (screen) (screen-cursor-style screen))
(defun cursor-blink-p (screen) (screen-cursor-blink screen))

(defun set-cursor-position (screen col row)
  "Move cursor to (COL, ROW), clamped to screen bounds."
  (let ((old-row (screen-cursor-row screen)))
    (setf (screen-cursor-col screen) (max 0 (min col (1- (screen-cols screen))))
          (screen-cursor-row screen) (max 0 (min row (1- (screen-rows screen)))))
    (%mark-dirty screen old-row)
    (%mark-dirty screen (screen-cursor-row screen))))

(defun set-cursor-style (screen style)
  "Set cursor style: :block, :underline, or :bar."
  (setf (screen-cursor-style screen) style)
  (%mark-dirty screen (screen-cursor-row screen)))

(defun set-cursor-visible (screen visible)
  (setf (screen-cursor-visible screen) visible)
  (%mark-dirty screen (screen-cursor-row screen)))

;;; --------------------------------------------------------------------------
;;; Cell access
;;; --------------------------------------------------------------------------
;;;
;;; A cell's content is a codepoint, 0 for an empty cell, or the continuation
;;; marker in a cell that the character before it covers. Both halves of a
;;; double-width character set the wide bit; the right half holds the marker
;;; (LEXTER-D119).

(defun cell-content (screen col row)
  "The content word of the cell at COL, ROW: its first codepoint, 0 when it is
   empty, or +CONTINUATION-MARKER+."
  (read-text-cell (screen-text screen) (%idx screen col row) :content))

(defun cell-style (screen col row)
  "The id of the style in which the cell at COL, ROW was written."
  (read-text-cell (screen-text screen) (%idx screen col row) :style))

(defun cell-wide-p (screen col row)
  "True when the cell at COL, ROW is either half of a double-width character."
  (= 1 (read-text-cell (screen-text screen) (%idx screen col row) :wide)))

(defun cell-continuation-p (screen col row)
  "True when the cell at COL, ROW is covered by the character before it."
  (text-cell-continuation-p (screen-text screen) (%idx screen col row)))

(defun cell-codepoints (screen col row)
  "The codepoints of the cell at COL, ROW, as a list: its first, then those of
   zero width that joined it; NIL for an empty cell or a continuation."
  (let ((content (cell-content screen col row)))
    (unless (or (zerop content) (= content +continuation-marker+))
      (cons content (coerce (%cluster screen col row) 'list)))))

(declaim (inline %wide-left-p))
(defun %wide-left-p (screen col row)
  "True when the cell at COL, ROW is the left half of a double-width pair."
  (and (< -1 col (screen-cols screen))
       (multiple-value-bind (content wide)
           (read-text-cell (screen-text screen) (%idx screen col row) :content :wide)
         (and (= wide 1) (/= content +continuation-marker+)))))

;;; --------------------------------------------------------------------------
;;; Clusters
;;; --------------------------------------------------------------------------
;;;
;;; The codepoints after the first of a cell are kept for each row, by column,
;;; and move and clear with their cells (LEXTER-D127).

(defun %cluster (screen col row)
  (cdr (assoc col (svref (screen-clusters screen) row))))

(defun %set-cluster (screen col row codepoints)
  "Keep CODEPOINTS as the joined codepoints of the cell at COL, ROW, or with
   NIL none, and set the cell's cluster flag to match."
  (let ((rest (remove col (svref (screen-clusters screen) row) :key #'car)))
    (setf (svref (screen-clusters screen) row)
          (if codepoints (acons col codepoints rest) rest))
    (patch-text-cell (screen-text screen) (%idx screen col row)
                     :cluster (if codepoints 1 0))))

;;; --------------------------------------------------------------------------
;;; Terminal rows
;;; --------------------------------------------------------------------------

(defun row-soft-wrap-p (screen row)
  "True when autowrap carried ROW's text on to the next row (LEXTER-D119)."
  (= 1 (read-terminal-row (screen-terminal-rows screen) row :soft-wrap)))

(defun set-row-soft-wrap (screen row wrapped)
  "Record whether ROW's text continues on the next row because autowrap
   carried it there."
  (patch-terminal-row (screen-terminal-rows screen) row :soft-wrap (if wrapped 1 0)))

(defun row-prompt-kind (screen row)
  "The OSC 133 zone at ROW's start: 0 none, 1 prompt, 2 input, 3 output."
  (read-terminal-row (screen-terminal-rows screen) row :prompt-kind))

(defun row-line-size (screen row)
  "ROW's DEC line size: 0 single, 1 double width, 2 and 3 the top and bottom
   of double height."
  (read-terminal-row (screen-terminal-rows screen) row :line-size))

(defun %copy-terminal-row (from from-index to to-index)
  (multiple-value-bind (soft-wrap prompt-kind line-size)
      (read-terminal-row from from-index :soft-wrap :prompt-kind :line-size)
    (write-terminal-row to to-index
                        :soft-wrap soft-wrap :prompt-kind prompt-kind :line-size line-size)))

;;; --------------------------------------------------------------------------
;;; Write operations
;;; --------------------------------------------------------------------------
;;;
;;; A character's cells, the codepoints that joined it, and its wide bit are
;;; written and erased together; every operation that cuts a double-width
;;; pair blanks the half it leaves, as a terminal blanks the other half of a
;;; pair when one half is overwritten (LEXTER-D98, LEXTER-O26).

(defun %set-cell (screen col row content style wide)
  "Write the cell at COL, ROW whole: CONTENT, STYLE, and WIDE, 0 or 1, with
   no joined codepoints."
  (%set-cluster screen col row nil)
  (write-text-cell (screen-text screen) (%idx screen col row)
                   :content content :style style :wide wide))

(defun %blank-cell (screen col row)
  "Empty the cell at COL, ROW: no character, not wide, in the style that keeps
   only its colours (ERASED-STYLE)."
  (%set-cell screen col row 0
             (erased-style (screen-styles screen) (cell-style screen col row))
             0))

(defun write-char-at (screen col row codepoint &key (style 0) wide)
  "Write CODEPOINT in the style whose id is STYLE at (COL, ROW). WIDE, when
   true, writes a double-width character, which covers (COL, ROW) and
   (COL+1, ROW): the right half holds the continuation marker. A pair never
   begins in the last column, where its right half would fall outside the row
   (LEXTER-O26); there CODEPOINT is written narrow."
  (let ((cols (screen-cols screen)))
    (when (and wide (>= col (1- cols)))
      (setf wide nil))
    ;; Overwriting the right half of a pair blanks its left half
    (when (cell-continuation-p screen col row)
      (when (%wide-left-p screen (1- col) row)
        (%blank-cell screen (1- col) row)))
    ;; Overwriting a left half, or covering a cell that begins a pair, blanks
    ;; the right half left behind
    (loop :for c :from col :to (if wide (1+ col) col)
          :when (and (%wide-left-p screen c row) (< (1+ c) cols))
            :do (%blank-cell screen (1+ c) row))
    (%set-cell screen col row codepoint style (if wide 1 0))
    (when wide
      (%set-cell screen (1+ col) row +continuation-marker+ style 1))
    (%mark-dirty screen row)))

(defun write-string-at (screen col row string &key (style 0))
  "Write the narrow characters of STRING from (COL, ROW), in the style whose id
   is STYLE, as far as the row reaches."
  (loop :for c :across string
        :for x :from col
        :while (< x (screen-cols screen))
        :do (write-char-at screen x row (char-code c) :style style)))

(defun join-character (screen codepoint)
  "Join CODEPOINT, a character of width 0, to the cell of the character before
   the cursor: on its row, or at the end of the row before when autowrap
   carried the text on (LEXTER-D119). A character with none before it is
   dropped. Only the cell's first codepoint is drawn (LEXTER-O63)."
  (let ((col (1- (screen-cursor-col screen)))
        (row (screen-cursor-row screen)))
    (when (and (< col 0) (plusp row) (row-soft-wrap-p screen (1- row)))
      (setf row (1- row)
            col (1- (screen-cols screen))))
    (when (and (>= col 0) (cell-continuation-p screen col row))
      (decf col))
    (when (and (>= col 0) (plusp (cell-content screen col row))
               (not (cell-continuation-p screen col row)))
      (%set-cluster screen col row
                    (concatenate '(vector (unsigned-byte 32))
                                 (%cluster screen col row) (list codepoint)))
      (%mark-dirty screen row))))

;;; --------------------------------------------------------------------------
;;; Cursor-relative write
;;; --------------------------------------------------------------------------

(defun put-char (screen codepoint &key (style 0) (advance t) wide)
  "Write CODEPOINT at the cursor in the style whose id is STYLE, and optionally
   advance. WIDE, when T, writes a double-wide character and advances by 2."
  (let ((col (screen-cursor-col screen))
        (cols (screen-cols screen)))
    ;; A wide char cannot begin in the last column: blank it and write the pair
    ;; at the start of the next row, scrolling at the bottom (LEXTER-O26)
    (when (and wide (>= col (1- cols)) (> cols 1))
      (%blank-cell screen col (screen-cursor-row screen))
      (set-row-soft-wrap screen (screen-cursor-row screen) t)
      (line-feed screen)
      (setf col 0))
    (write-char-at screen col (screen-cursor-row screen) codepoint :style style :wide wide)
    (when advance
      (let ((new-col (+ col (if wide 2 1))))
        (setf (screen-cursor-col screen) (min new-col (1- cols)))))))

(defun delete-char (screen)
  "Erase the character at the cursor."
  (%erase-range screen (screen-cursor-row screen)
                (screen-cursor-col screen) (1+ (screen-cursor-col screen))))

;;; --------------------------------------------------------------------------
;;; Erase operations
;;; --------------------------------------------------------------------------

(defun %repair-pair-edges (screen row start end)
  "Before an operation changes columns START to END - 1 of ROW, blank the half
   of a pair that would be left outside the range: the left half at START - 1
   of a pair whose right half is START, and the right half at END of a pair
   whose left half is END - 1."
  (let ((cols (screen-cols screen)))
    (when (and (< 0 start cols) (%wide-left-p screen (1- start) row))
      (%blank-cell screen (1- start) row))
    (when (and (< 0 end cols) (%wide-left-p screen (1- end) row))
      (%blank-cell screen end row))))

(defun %erase-range (screen row start end)
  "Erase columns START to END - 1 of ROW, repairing a pair cut at either edge.
   An erase that reaches the row's last column leaves the row unwrapped, since
   its text no longer runs on to the next."
  (let* ((cols (screen-cols screen))
         (end (min end cols)))
    (when (< start end)
      (%repair-pair-edges screen row start end)
      (loop :for col :from start :below end :do (%blank-cell screen col row))
      (when (= end cols)
        (set-row-soft-wrap screen row nil)))
    (%mark-dirty screen row)))

(defun erase-in-display (screen mode)
  "Erase parts of the display.
   MODE 0: cursor to end of screen
   MODE 1: start of screen to cursor
   MODE 2: entire screen
   MODE 3: entire screen + scrollback"
  (let ((cols (screen-cols screen))
        (rows (screen-rows screen))
        (cc (screen-cursor-col screen))
        (cr (screen-cursor-row screen)))
    (ecase mode
      (0 ;; Cursor to end
       (%erase-range screen cr cc cols)
       (loop :for row :from (1+ cr) :below rows :do (%erase-range screen row 0 cols)))
      (1 ;; Start to cursor
       (loop :for row :from 0 :below cr :do (%erase-range screen row 0 cols))
       (%erase-range screen cr 0 (1+ cc)))
      (2 ;; Entire screen
       (loop :for row :from 0 :below rows :do (%erase-range screen row 0 cols)))
      (3 ;; Entire screen + scrollback
       (erase-in-display screen 2)
       (fill (screen-scrollback-lines screen) nil)
       (setf (screen-scrollback-count screen) 0
             (screen-scrollback-viewport screen) 0)))))

(defun erase-in-line (screen mode)
  "Erase parts of the current line.
   MODE 0: cursor to end of line
   MODE 1: start of line to cursor
   MODE 2: entire line"
  (let ((cols (screen-cols screen))
        (row (screen-cursor-row screen))
        (cc (screen-cursor-col screen)))
    (ecase mode
      (0 (%erase-range screen row cc cols))
      (1 (%erase-range screen row 0 (1+ cc)))
      (2 (%erase-range screen row 0 cols)))))

(defun erase-chars (screen n)
  "Erase N characters starting at cursor (replace with blanks)."
  (let ((cc (screen-cursor-col screen)))
    (%erase-range screen (screen-cursor-row screen) cc (+ cc n))))

;;; --------------------------------------------------------------------------
;;; Insert/delete characters
;;; --------------------------------------------------------------------------

(defun %move-cell (screen src-col dst-col row)
  "Copy the cell at SRC-COL to DST-COL of ROW whole: its text cell and the
   codepoints that joined it."
  (let ((i (%idx screen 0 row)))
    (copy-text-cells (screen-text screen) (+ i src-col) (screen-text screen) (+ i dst-col) 1)
    (let ((cluster (%cluster screen src-col row)))
      (%set-cluster screen dst-col row cluster))))

(defun insert-chars (screen n)
  "Insert N blank characters at cursor, shifting rest of line right."
  (let* ((row (screen-cursor-row screen))
         (col (screen-cursor-col screen))
         (cols (screen-cols screen))
         (n (min n (- cols col))))
    (when (plusp n)
      ;; A pair cut at the cursor loses its left half
      (%repair-pair-edges screen row col col)
      ;; Shift cells right, whole
      (loop :for c :from (1- cols) :downto (+ col n)
            :do (%move-cell screen (- c n) c row))
      ;; Clear inserted positions
      (loop :for c :from col :below (+ col n)
            :do (%blank-cell screen c row))
      ;; A pair whose right half was pushed off the end loses its left half
      (when (%wide-left-p screen (1- cols) row)
        (%blank-cell screen (1- cols) row)))
    (%mark-dirty screen row)))

(defun delete-chars (screen n)
  "Delete N characters at cursor, shifting rest of line left. The blanks
   shifted in at the row's end leave it unwrapped."
  (let* ((row (screen-cursor-row screen))
         (col (screen-cursor-col screen))
         (cols (screen-cols screen))
         (n (min n (- cols col))))
    (when (plusp n)
      ;; A pair cut at either edge of the deleted range loses its other half
      (%repair-pair-edges screen row col (+ col n))
      ;; Shift cells left, whole
      (loop :for c :from col :below (- cols n)
            :do (%move-cell screen (+ c n) c row))
      ;; Clear vacated positions
      (loop :for c :from (- cols n) :below cols
            :do (%blank-cell screen c row))
      (set-row-soft-wrap screen row nil))
    (%mark-dirty screen row)))

;;; --------------------------------------------------------------------------
;;; Line operations
;;; --------------------------------------------------------------------------

(defun %copy-row (screen src-row dst-row)
  "Copy row SRC-ROW to DST-ROW whole: its text cells, the codepoints that
   joined them, and its terminal row."
  (let ((cols (screen-cols screen)))
    (copy-text-cells (screen-text screen) (%idx screen 0 src-row)
                     (screen-text screen) (%idx screen 0 dst-row) cols)
    (setf (svref (screen-clusters screen) dst-row)
          (copy-alist (svref (screen-clusters screen) src-row)))
    (%copy-terminal-row (screen-terminal-rows screen) src-row
                        (screen-terminal-rows screen) dst-row)
    (%mark-dirty screen dst-row)))

(defun %clear-row (screen row)
  "Make ROW a row of empty cells in style 0, with a terminal row of zeros."
  (clear-text-cells (screen-text screen) (%idx screen 0 row) (screen-cols screen))
  (setf (svref (screen-clusters screen) row) nil)
  (write-terminal-row (screen-terminal-rows screen) row)
  (%mark-dirty screen row))

(defun insert-lines (screen n)
  "Insert N blank lines at cursor row, scrolling lines down within scroll region."
  (let ((top (screen-cursor-row screen))
        (bottom (screen-scroll-bottom screen)))
    (loop :for row :from bottom :downto (+ top n)
          :do (%copy-row screen (- row n) row))
    (loop :for row :from top :below (min (+ top n) (1+ bottom))
          :do (%clear-row screen row))))

(defun delete-lines (screen n)
  "Delete N lines at cursor row, scrolling lines up within scroll region."
  (let ((top (screen-cursor-row screen))
        (bottom (screen-scroll-bottom screen)))
    (loop :for row :from top :to (- bottom n)
          :do (%copy-row screen (+ row n) row))
    (loop :for row :from (max top (1+ (- bottom n))) :to bottom
          :do (%clear-row screen row))))

;;; --------------------------------------------------------------------------
;;; Scrolling
;;; --------------------------------------------------------------------------

(defun %history-row (screen row)
  "ROW of SCREEN as history keeps it: its text cells without continuations,
   the codepoints that joined them by their place in the history row, and its
   terminal row (LEXTER-D118)."
  (let* ((cols (screen-cols screen))
         (text (screen-text screen))
         (base (%idx screen 0 row))
         (kept (loop :for col :below cols
                     :unless (text-cell-continuation-p text (+ base col))
                       :collect col))
         (history (%make-history-row :text (make-text-array (length kept)))))
    (loop :for col :in kept
          :for k :from 0
          :do (copy-text-cells text (+ base col) (history-row-text history) k 1)
              (let ((cluster (%cluster screen col row)))
                (when cluster
                  (push (cons k cluster) (history-row-clusters history)))))
    (%copy-terminal-row (screen-terminal-rows screen) row (history-row-terminal-row history) 0)
    history))

(defun %save-to-scrollback (screen row)
  "Save a row to scrollback before it scrolls off."
  (when (screen-scrollback-enabled screen)
    (let* ((max (screen-scrollback-max screen))
           (count (screen-scrollback-count screen)))
      (setf (aref (screen-scrollback-lines screen) (mod count max)) (%history-row screen row))
      (setf (screen-scrollback-count screen) (1+ count)))))

(defun line-feed (screen)
  "Move the cursor down one row, keeping its column, as a line feed does: on
   the scrolling region's bottom margin the region scrolls up; elsewhere the
   cursor moves down, stopping on the screen's last row. Every path that moves
   to the next line, autowrap included, goes through here, so that the
   region's rule has one home (LEXTER-D69)."
  (let ((row (screen-cursor-row screen)))
    (cond ((= row (screen-scroll-bottom screen))
           (scroll-up screen))
          ((< row (1- (screen-rows screen)))
           (set-cursor-position screen (screen-cursor-col screen) (1+ row))))))

(defun reverse-line-feed (screen)
  "Move the cursor up one row, keeping its column, as a reverse index does: on
   the scrolling region's top margin the region scrolls down; elsewhere the
   cursor moves up, stopping on the screen's first row (LEXTER-D69)."
  (let ((row (screen-cursor-row screen)))
    (cond ((= row (screen-scroll-top screen))
           (scroll-down screen))
          ((plusp row)
           (set-cursor-position screen (screen-cursor-col screen) (1- row))))))

(defun scroll-up (screen &optional (n 1))
  "Scroll the scrolling region up by N lines. More lines than the region holds
   scroll it as its height does (LEXTER-D68)."
  (let* ((top (screen-scroll-top screen))
         (bottom (screen-scroll-bottom screen))
         (n (min n (1+ (- bottom top)))))
    (loop :repeat n :do
      ;; Save top line to scrollback if at actual top
      (when (zerop top)
        (%save-to-scrollback screen top))
      ;; Shift lines up
      (loop :for row :from top :below bottom
            :do (%copy-row screen (1+ row) row))
      ;; Clear bottom line
      (%clear-row screen bottom))))

(defun scroll-down (screen &optional (n 1))
  "Scroll the scrolling region down by N lines. More lines than the region
   holds scroll it as its height does (LEXTER-D68)."
  (let* ((top (screen-scroll-top screen))
         (bottom (screen-scroll-bottom screen))
         (n (min n (1+ (- bottom top)))))
    (loop :repeat n :do
      ;; Shift lines down
      (loop :for row :from bottom :above top
            :do (%copy-row screen (1- row) row))
      ;; Clear top line
      (%clear-row screen top))))

(defun set-scrolling-region (screen top bottom)
  "Set the scrolling region (VT DECSTBM). TOP and BOTTOM are 0-indexed, inclusive."
  (setf (screen-scroll-top screen) (max 0 top)
        (screen-scroll-bottom screen) (min bottom (1- (screen-rows screen)))))

;;; --------------------------------------------------------------------------
;;; Scrollback access
;;; --------------------------------------------------------------------------

(defun scrollback-lines (screen)
  "Return the number of lines in scrollback."
  (min (screen-scrollback-count screen) (screen-scrollback-max screen)))

(defun scrollback-line (screen n)
  "Return scrollback line N (0 = most recent), a HISTORY-ROW, or NIL if out of
   range."
  (let* ((count (scrollback-lines screen))
         (max (screen-scrollback-max screen))
         (total (screen-scrollback-count screen))
         (lines (screen-scrollback-lines screen)))
    (when (< n count)
      (let ((idx (mod (- total 1 n) max)))
        (aref lines idx)))))

(defun history-row-codepoints (history)
  "The first codepoint of each cell of the HISTORY-ROW HISTORY, as a list, 0
   for an empty cell."
  (let ((text (history-row-text history)))
    (loop :for k :below (text-array-count text)
          :collect (read-text-cell text k :content))))

(defun history-row-soft-wrap-p (history)
  "True when the HISTORY-ROW HISTORY continued on the next row because
   autowrap carried it there."
  (= 1 (read-terminal-row (history-row-terminal-row history) 0 :soft-wrap)))

(defun scrollback-viewport-offset (screen)
  (screen-scrollback-viewport screen))

(defun set-scrollback-viewport (screen offset)
  "Set scrollback viewport offset. 0 = live screen, >0 = looking at history."
  (setf (screen-scrollback-viewport screen)
        (max 0 (min offset (scrollback-lines screen)))))

;;; --------------------------------------------------------------------------
;;; Resize
;;; --------------------------------------------------------------------------

(defun resize-screen (screen new-cols new-rows)
  "Resize the screen. Preserves content where possible."
  (let* ((old-cols (screen-cols screen))
         (old-rows (screen-rows screen))
         (old-text (screen-text screen))
         (old-clusters (screen-clusters screen))
         (old-terminal-rows (screen-terminal-rows screen))
         (keep-rows (min old-rows new-rows))
         (keep-cols (min old-cols new-cols)))
    (setf (screen-cols screen) new-cols
          (screen-rows screen) new-rows
          (screen-text screen) (make-text-array (* new-cols new-rows))
          (screen-clusters screen) (make-array new-rows :initial-element nil)
          (screen-terminal-rows screen) (make-terminal-row-array new-rows)
          (screen-row-dirty screen) (make-array new-rows :element-type 'bit :initial-element 1)
          (screen-scroll-top screen) 0
          (screen-scroll-bottom screen) (1- new-rows))
    (dotimes (row keep-rows)
      (copy-text-cells old-text (* row old-cols) (screen-text screen) (* row new-cols) keep-cols)
      (setf (svref (screen-clusters screen) row)
            (remove-if-not (lambda (entry) (< (car entry) new-cols))
                           (svref old-clusters row)))
      (%copy-terminal-row old-terminal-rows row (screen-terminal-rows screen) row)
      ;; A pair cut by a narrower right edge loses its left half (LEXTER-O26)
      (when (and (< new-cols old-cols) (%wide-left-p screen (1- new-cols) row))
        (%blank-cell screen (1- new-cols) row)))
    ;; Clamp cursor
    (setf (screen-cursor-col screen) (min (screen-cursor-col screen) (1- new-cols))
          (screen-cursor-row screen) (min (screen-cursor-row screen) (1- new-rows)))
    screen))

;;; --------------------------------------------------------------------------
;;; Building rows into the display grid
;;; --------------------------------------------------------------------------
;;;
;;; One function builds every terminal row, of the screen and of its history,
;;; from text cells, their styles, and the terminal's settings, so that a
;;; fault found on either path is repaired for both (LEXTER-D124). What a cell
;;; is drawn with is decided here, as a record of the plain format: its glyph,
;;; from the atlas, by its codepoint and width; its swatch, from its style
;;; under the presentation rules (LEXTER-D125); reverse video through the
;;; background slot (LEXTER-D86); invisible text as no glyphs; the underline
;;; as a mask of the line glyph in the text's colour (LEXTER-D88); and blink
;;; as the blink flag (LEXTER-D94).

(defun %cell-glyph (atlas content width space-glyph)
  "The atlas position of a cell whose content word is CONTENT and whose
   character is WIDTH columns wide: SPACE-GLYPH for an empty cell, and the
   \"no glyph\" glyph for a character no font covers (LEXTER-D122). The
   second value is true when the position begins a wide entry of the atlas,
   whose second column a right half names (LEXTER-D126)."
  (cond ((zerop content) space-glyph)
        ((and atlas (lexter/atlas:atlas-glyph-index atlas content width))
         (values (lexter/atlas:atlas-glyph-index atlas content width) (= width 2)))
        (t lexter/atlas:+no-glyph-position+)))

(defun %build-row (screen display-grid text start count grid-row col-offset atlas
                   space-glyph palette-slot)
  "Build the COUNT text cells of TEXT from cell START, one terminal row, into
   GRID-ROW of DISPLAY-GRID from column COL-OFFSET, as SCREEN's terminal draws
   them, in PALETTE-SLOT. Cells that continue a character are passed over, so
   that a row of the screen and a row of history, which keeps none, are built
   alike; a row shorter than the screen, as history leaves it after a resize,
   is filled with empty cells in style 0. A double-width pair whose right half
   would fall past the grid's right edge is clipped to its left half."
  (let* ((styles (screen-styles screen))
         (swatches (screen-swatches screen))
         (palette (screen-palette screen))
         (cols (screen-cols screen))
         (grid-cols (lexter/grid:display-grid-cols display-grid))
         (underline (lexter/atlas:line-glyph-position 0 1))
         (col 0))
    (flet ((put (col glyph style-id &key wide right-half)
             (let ((grid-col (+ col col-offset))
                   (style (table-style styles style-id)))
               (when (< grid-col grid-cols)
                 (lexter/grid:write-text-record
                  display-grid grid-col grid-row
                  :glyph glyph
                  :visible (not (style-invisible style))
                  :swatch (style-swatch styles swatches style-id palette)
                  :palette-slot palette-slot
                  ;; Reverse video exchanges the slots within the swatch
                  :background-slot (if (style-reverse style) 1 0)
                  :ink-slot (if (style-reverse style) 0 1)
                  :underline-glyph (and (style-underline style)
                                        (+ underline (* 8 (style-line-style style))))
                  :wide wide :right-half right-half
                  :blink (style-blink style))))))
      (loop :for i :from start :below (+ start count)
            :while (< col cols)
            :do (multiple-value-bind (content style wide)
                    (read-text-cell text i :content :style :wide)
                  (unless (= content +continuation-marker+)
                    (let ((width (if (and (= wide 1) (< (1+ col) cols)) 2 1)))
                      (multiple-value-bind (glyph wide-entry)
                          (%cell-glyph atlas content width space-glyph)
                        (if (and (= width 2) (< (+ col col-offset 1) grid-cols))
                            (progn
                              (put col glyph style :wide t)
                              (put (1+ col) (if wide-entry (1+ glyph) glyph) style
                                   :wide t :right-half t))
                            (put col glyph style)))
                      (incf col width)))))
      (loop :for c :from col :below cols
            :do (put c space-glyph 0)))))

(defun %check-row-pairs (screen row)
  "Blank either half of a pair in ROW of SCREEN that has lost the other: a left
   half in the last column or before a cell that does not continue it, and a
   continuation after a cell that is no left half. A safety net under the
   operations that keep pairs (LEXTER-D98)."
  (let ((cols (screen-cols screen)))
    (dotimes (col cols)
      (cond ((%wide-left-p screen col row)
             (unless (and (< (1+ col) cols) (cell-continuation-p screen (1+ col) row))
               (%blank-cell screen col row)))
            ((cell-continuation-p screen col row)
             (unless (%wide-left-p screen (1- col) row)
               (%blank-cell screen col row)))))))

(defun flush-to-display (screen display-grid &key (atlas nil)
                                                   (space-glyph lexter/atlas:+empty-glyph-position+)
                                                   (palette-slot 0)
                                                   (cursor-blink-on t)
                                                   (col-offset 0) (row-offset 0))
  "Build SCREEN's rows into the display grid for rendering.
   ATLAS gives each character's glyph, by its codepoint and width.
   SPACE-GLYPH is the atlas position drawn in an empty cell.
   PALETTE-SLOT is the terminal's palette slot, which its records name.
   CURSOR-BLINK-ON controls whether a blinking cursor is currently visible.
   COL-OFFSET and ROW-OFFSET position the screen within the grid (for panes).
   While the screen's scrollback viewport is above 0, the grid shows history
   above the top rows of the screen, every row is repainted, and no cursor is
   drawn."
  (let ((cols (screen-cols screen))
        (rows (screen-rows screen))
        (cc (screen-cursor-col screen))
        (cr (screen-cursor-row screen))
        (grid-cols (lexter/grid:display-grid-cols display-grid))
        (grid-rows (lexter/grid:display-grid-rows display-grid)))
    ;; Always mark cursor row dirty so it gets updated every frame
    ;; This ensures cursor blink and movement are always rendered
    (when (< cr rows)
      (setf (sbit (screen-row-dirty screen) cr) 1))
    ;; Row D of the pane shows, with the viewport V lines back, history line
    ;; V-1-D while that is 0 or more, and otherwise the screen's row D-V. At
    ;; V = 0 that is the screen itself, and only its dirty rows are built;
    ;; above 0 the view is shifted, so every row is built
    ;; (LEXTER-DRAFT-pane-profiles-D5).
    (let ((viewport (screen-scrollback-viewport screen)))
      (loop :for row :from 0 :below rows
            :for grid-row = (+ row row-offset)
            :for history-line = (- viewport 1 row)
            :when (and (or (plusp viewport)
                           (= 1 (sbit (screen-row-dirty screen) row)))
                       (< grid-row grid-rows))
            :do (if (and (plusp viewport) (>= history-line 0))
                    (let* ((history (scrollback-line screen history-line))
                           (text (if history (history-row-text history) (make-text-array 0))))
                      (%build-row screen display-grid text 0 (text-array-count text)
                                  grid-row col-offset atlas space-glyph palette-slot))
                    (let ((source-row (- row viewport)))
                      (%check-row-pairs screen source-row)
                      (%build-row screen display-grid (screen-text screen)
                                  (%idx screen 0 source-row) cols
                                  grid-row col-offset atlas space-glyph palette-slot)))))
    ;; No cursor is drawn while the view is scrolled back into the history.
    (when (plusp (screen-scrollback-viewport screen))
      (fill (screen-row-dirty screen) 0)
      (return-from flush-to-display nil))
    ;; The cursor is drawn by exchanging its cell's background slot with its
    ;; topmost layer's ink slot in the grid, keeping the cell's swatch and both
    ;; halves of a pair, so that it interns no swatch and breaks no pair, until
    ;; the overlay list draws it (LEXTER-D101, LEXTER-D93). The cursor's row is
    ;; built at every flush, which removes it from where it was.
    (let ((cursor-visible (and (screen-cursor-visible screen)
                               (or (not (screen-cursor-blink screen))
                                   cursor-blink-on)))
          (grid-cc (+ cc col-offset))
          (grid-cr (+ cr row-offset)))
      (when (and cursor-visible
                 (< cc cols) (< cr rows)
                 (< grid-cc grid-cols) (< grid-cr grid-rows))
        ;; On the right half of a pair, the cursor covers the pair's left half
        (when (and (> grid-cc col-offset)
                   (lexter/grid:continuation-p display-grid grid-cc grid-cr))
          (decf grid-cc))
        (lexter/grid:exchange-cell-slots display-grid grid-cc grid-cr)))
    ;; Clear model dirty flags
    (fill (screen-row-dirty screen) 0)))
