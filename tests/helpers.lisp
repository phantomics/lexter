;;;; tests/helpers.lisp — Suite hierarchy, runners, and fixtures for Lexter.
;;;;
;;;; Square-conforming (see Square.md §6, §7, §11). This file defines the whole
;;;; suite hierarchy in one place, the two exported runner functions, and the
;;;; fixtures every test file draws on. It loads after package.lisp and before
;;;; any test-*.lisp file.
;;;;
;;;; Everything here runs headless: fonts are built in memory, atlases are
;;;; packed with PACK-ATLAS and never uploaded, and the GPU's copy of the swatch
;;;; table is a stand-in (LEXTER-DRAFT-cell-model-revision-D21, -D22).

(in-package #:lexter-tests)

;;; ============================================================
;;; Suite hierarchy  (Square.md §6)
;;; ============================================================

(def-suite lexter
  :description "Root suite for all Lexter tests")

(def-suite atlas
  :description "Packing the glyph atlas from a font chain, and its reserved positions, without GL"
  :in lexter)

(def-suite handler
  :description "The VT handler: bytes from a host made into cells of a screen"
  :in lexter)

(def-suite model
  :description "The screen model's cell, range, and row operations"
  :in lexter)

(def-suite grid
  :description "The display grid: the flush from a screen, resizing, and the instance buffers"
  :in lexter)

(def-suite swatches
  :description "Swatch tables, their copy in the grid, and the copy that reaches the GPU"
  :in lexter)

(def-suite structure
  :description "How the code is arranged: shared definitions have one home, and no claim outruns the code"
  :in lexter)

(def-suite tn3270
  :description "The TN3270 client's negotiation and record framing, and its screen's geometry, over a loopback socket"
  :in lexter)

(def-suite telnet
  :description "What a telnet pane sends: encoded characters, escaped IAC, and option replies, over a loopback socket"
  :in lexter)

(def-suite pty
  :description "Terminals without a PTY: input events that have no backend to reach"
  :in lexter)

(def-suite pty-slow
  :description "The PTY's descriptor and child after the child exits; spawns a process (excluded by :skip-slow)"
  :in lexter)

;;; ============================================================
;;; Test runners  (Square.md §11)
;;; ============================================================

(defparameter *fast-suites*
  '(atlas handler model grid swatches structure tn3270 telnet pty)
  "The child suites run when slow tests are skipped.")

(defun run-all-tests (&key skip-slow)
  "Run all Lexter test suites. Return T if all pass.
When SKIP-SLOW is true, omit the *-slow suites."
  (let ((results (if skip-slow
                     (loop :for suite :in *fast-suites* :nconc (run suite))
                     (run 'lexter))))
    (explain! results)
    (results-status results)))

(defun %resolve-suite-name (name)
  "Resolve a suite NAME (keyword, string, or symbol) to the interned symbol."
  (etypecase name
    (keyword (find-symbol (symbol-name name) :lexter-tests))
    (string  (find-symbol (string-upcase name) :lexter-tests))
    (symbol  name)))

(defun run-suite (suite-name)
  "Run a single named suite. Accept a keyword, string, or symbol.
Return T if all pass."
  (let ((results (run (%resolve-suite-name suite-name))))
    (explain! results)
    (results-status results)))

;;; ============================================================
;;; Domain builders  (Square.md §7)
;;; ============================================================

(defun octets (&rest parts)
  "Build an (unsigned-byte 8) vector from PARTS, each a byte, a vector of
bytes, or a string, which is encoded as UTF-8."
  (let ((bytes '()))
    (dolist (part parts)
      (etypecase part
        ((unsigned-byte 8) (push part bytes))
        ((vector (unsigned-byte 8)) (loop :for b :across part :do (push b bytes)))
        (string (loop :for b :across (babel:string-to-octets part :encoding :utf-8)
                      :do (push b bytes)))))
    (make-array (length bytes) :element-type '(unsigned-byte 8)
                               :initial-contents (nreverse bytes))))

(defun csi (&rest parts)
  "Build the bytes of a control sequence: ESC [ followed by PARTS, each a
string or a number written in decimal."
  (apply #'octets #x1B "["
         (mapcar (lambda (p) (if (stringp p) p (princ-to-string p))) parts)))

;;; ============================================================
;;; Factories  (Square.md §7)
;;; ============================================================

(defparameter *test-cell-width* 4
  "Cell width, in pixels, of the fonts that MAKE-TEST-FONT builds.")

(defparameter *test-cell-height* 6
  "Cell height, in pixels, of the fonts that MAKE-TEST-FONT builds.")

(defun %test-glyph-pixels (codepoint width height)
  "A WIDTH-by-HEIGHT bitmap for CODEPOINT, 0 or 255 per pixel: blank for the
space, and otherwise a pattern that differs between codepoints."
  (let ((pixels (make-array (* width height) :element-type '(unsigned-byte 8)
                                             :initial-element 0)))
    (unless (= codepoint #x20)
      (dotimes (i (length pixels))
        (when (zerop (mod (+ i codepoint) 3))
          (setf (aref pixels i) 255))))
    pixels))

(defun make-test-font (&key (narrow '(#x41 #x42 #x20)) (wide '(#x4E00))
                            (cell-width *test-cell-width*)
                            (cell-height *test-cell-height*))
  "Build a BITMAP-FONT in memory, with no font file: a narrow glyph for each
codepoint of NARROW and a double-width glyph for each of WIDE, in that order.
The default holds A, B, the space, and U+4E00, with the space not first, so
that no test passes because the space happens to take atlas position 0."
  (let* ((codepoints (append narrow wide))
         (bitmaps (make-array (length codepoints)))
         (encoding (make-hash-table))
         (wide-glyphs (when wide (make-hash-table))))
    (loop :for cp :in codepoints
          :for index :from 0
          :for wide-p = (member cp wide)
          :do (setf (aref bitmaps index)
                    (%test-glyph-pixels cp (if wide-p (* 2 cell-width) cell-width)
                                        cell-height)
                    (gethash cp encoding) index)
              (when wide-p
                (setf (gethash index wide-glyphs) t)))
    (lexter/pcf::make-bitmap-font :cell-width cell-width
                                  :cell-height cell-height
                                  :ascent (1- cell-height)
                                  :glyph-count (length codepoints)
                                  :bitmaps bitmaps
                                  :encoding encoding
                                  :wide-glyphs wide-glyphs)))

(defun make-test-atlas (&key (fonts (list (make-test-font))) (cols 16)
                             (cursor-glyphs t))
  "Pack an atlas from FONTS with COLS columns, without GL, and add the cursor
glyphs as the production path does when CURSOR-GLYPHS is true."
  (let ((atlas (lexter/atlas:pack-atlas fonts :cols cols)))
    (when cursor-glyphs
      (lexter/atlas:add-cursor-glyphs atlas))
    atlas))

(defun glyph (atlas codepoint)
  "The atlas position of CODEPOINT in ATLAS; signals an error if it has none."
  (or (lexter/atlas:atlas-glyph-index atlas codepoint)
      (error "The test atlas has no glyph for U+~4,'0X" codepoint)))

(defun make-test-screen (&key (cols 10) (rows 3) atlas)
  "A fresh screen of COLS by ROWS, whose blank glyph comes from ATLAS as a
VT pane's does (src/panes/vt-pane.lisp:vt-pane-init-screen)."
  (let ((screen (lexter/model:make-screen :cols cols :rows rows)))
    (when atlas
      (let ((space (lexter/atlas:atlas-glyph-index atlas #x20)))
        (when space
          (setf (lexter/model:screen-blank-glyph screen) space))))
    screen))

(defun make-test-grid (&key (cols 10) (rows 3))
  "A fresh display grid of COLS by ROWS."
  (lexter/grid:make-display-grid :cols cols :rows rows))

;;; ============================================================
;;; State fixtures  (Square.md §7)
;;; ============================================================
;;;
;;; Lexter's model holds no global state the tests touch; each test works on
;;; fresh objects, bound by WITH-CLEAN-TERMINAL.

(defvar *atlas* nil "The atlas of the terminal WITH-CLEAN-TERMINAL makes.")
(defvar *screen* nil "The screen of the terminal WITH-CLEAN-TERMINAL makes.")
(defvar *handler* nil "The VT handler of the terminal WITH-CLEAN-TERMINAL makes.")
(defvar *grid* nil "The display grid of the terminal WITH-CLEAN-TERMINAL makes.")

(defmacro with-clean-terminal ((&key (cols 10) (rows 3)) &body body)
  "Run BODY with *ATLAS*, *SCREEN*, *HANDLER*, and *GRID* bound to a fresh
packed atlas, and a screen, VT handler, and display grid of COLS by ROWS, as a
VT pane assembles them."
  `(let* ((*atlas*   (make-test-atlas))
          (*screen*  (make-test-screen :cols ,cols :rows ,rows :atlas *atlas*))
          (*handler* (lexter/vt-handler:make-vt-handler *screen* *atlas*))
          (*grid*    (make-test-grid :cols ,cols :rows ,rows)))
     ,@body))

(defun feed (&rest parts)
  "Process PARTS, bytes or strings, through *HANDLER* as output from a host."
  (lexter/vt-handler:process-output *handler* (apply #'octets parts)))

(defun flush (&key (screen *screen*) (grid *grid*) (col-offset 0) (row-offset 0)
                   (cursor-visible nil))
  "Flush SCREEN into GRID as a VT pane does, with the cursor shown only when
CURSOR-VISIBLE is true, so that tests of cells are not disturbed by it."
  (lexter/model:set-cursor-visible screen cursor-visible)
  (lexter/model:flush-to-display screen grid
                                 :col-offset col-offset
                                 :row-offset row-offset
                                 :space-glyph (lexter/model:screen-blank-glyph screen)))

;;; ============================================================
;;; Writing cells
;;; ============================================================

(defun write-wide (col row)
  "Write U+4E00 as a double-width character at COL, ROW of *SCREEN*."
  (lexter/model:write-char-at *screen* col row (glyph *atlas* #x4E00) :wide t))

;;; ============================================================
;;; Inspecting first-edition state  (LEXTER-D106)
;;; ============================================================
;;;
;;; These read the first edition's internal arrays; Phase 3 rewrites them for
;;; the dense record, and Phase 2 rewrites the swatch readers for the store.

(defun screen-wide-p (screen col row)
  "True when the cell at COL, ROW of SCREEN is marked as the left half of a
double-width character."
  (= 1 (sbit (lexter/model::screen-wide-flags screen)
             (+ (* row (lexter/model:screen-cols screen)) col))))

(defun screen-glyph (screen col row)
  "The glyph stored at COL, ROW of SCREEN's simple cells."
  (aref (lexter/model::screen-glyphs screen)
        (+ (* row (lexter/model:screen-cols screen)) col)))

(defun grid-index (grid col row)
  "The index of the cell at COL, ROW in GRID's per-cell arrays."
  (+ (* row (lexter/grid:display-grid-cols grid)) col))

(defun grid-glyph (grid col row)
  "The glyph of the simple cell at COL, ROW of GRID."
  (aref (lexter/grid::display-grid-glyphs grid) (grid-index grid col row)))

(defun grid-wide-p (grid col row)
  "True when the cell at COL, ROW of GRID is the left half of a wide glyph."
  (= 1 (sbit (lexter/grid::display-grid-wide-flags grid) (grid-index grid col row))))

(defun grid-continuation-p (grid col row)
  "True when the cell at COL, ROW of GRID is the right half of a wide glyph."
  (= 1 (sbit (lexter/grid::display-grid-continuation-flags grid)
             (grid-index grid col row))))

(defun grid-layer (grid col row layer)
  "The CELL-LAYER at LAYER of the layered cell at COL, ROW of GRID, or NIL."
  (let ((loc (gethash (cons col row) (lexter/grid::display-grid-layered-cells grid))))
    (and loc (aref (lexter/grid::cell-location-layers loc) layer))))

(defun grid-layered-swatch (grid col row)
  "The swatch index of the layered cell at COL, ROW of GRID, or NIL."
  (let ((loc (gethash (cons col row) (lexter/grid::display-grid-layered-cells grid))))
    (and loc (lexter/grid::cell-location-swatch-idx loc))))

(defun grid-cell-colours (grid col row)
  "The four palette indices that the simple cell at COL, ROW of GRID is drawn
in, read through the grid's swatch table."
  (multiple-value-list
   (lexter/grid:get-swatch grid (aref (lexter/grid::display-grid-swatch-indices grid)
                                      (grid-index grid col row)))))

;;; ============================================================
;;; The GPU's copy of the swatch table, a stand-in  (LEXTER-D106)
;;; ============================================================
;;;
;;; The renderer's upload rule needs a GL context, so the swatch tests use a
;;; stand-in for it, as the critique did: it uploads the grid's whole table
;;; when the grid's generation differs from the one it recorded, as
;;; src/renderer.lisp:upload-swatch-table does at 2d4d743. Phase 2 replaces
;;; the rule with records that name their table (LEXTER-D99); the stand-in is
;;; then replaced by the renderer's own decision, made callable without GL.

(defstruct test-gpu
  "The GPU's copy of a swatch table, and the generation it last recorded."
  (generation 0 :type fixnum)
  (swatch-data (make-array 0 :element-type '(unsigned-byte 8))))

(defun gpu-upload (gpu grid)
  "Upload GRID's swatch table to GPU by the renderer's rule. Return T if it
uploaded."
  (let ((generation (lexter/grid:swatch-generation grid)))
    (when (/= generation (test-gpu-generation gpu))
      (setf (test-gpu-swatch-data gpu) (copy-seq (lexter/grid:display-grid-swatch-data grid))
            (test-gpu-generation gpu) generation)
      t)))

(defun gpu-swatch (gpu index)
  "The four palette indices of swatch INDEX in GPU's copy, or zeros if the copy
does not reach it."
  (let ((data (test-gpu-swatch-data gpu)))
    (loop :for slot :below 4
          :for i = (+ (* index 4) slot)
          :collect (if (< i (length data)) (aref data i) 0))))

;;; ============================================================
;;; Async polling  (Square.md §7)
;;; ============================================================

(defun wait-for-predicate (predicate &key (timeout 2) (interval 0.01))
  "Poll PREDICATE until it returns true or TIMEOUT seconds elapse.
Return T on success, NIL on timeout."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (when (funcall predicate) (return t))
      (when (>= (get-internal-real-time) deadline) (return nil))
      (sleep interval))))

;;; ============================================================
;;; Loopback sockets  (Square.md §7, §13)
;;; ============================================================
;;;
;;; The protocol tests connect a real client to a peer in the same image, on
;;; an ephemeral port of the loopback interface: hermetic, with no server
;;; outside the test.

(defmacro with-loopback-listener ((listener port) &body body)
  "Run BODY with LISTENER bound to a socket listening on an ephemeral loopback
port, and PORT to that port; close the listener afterwards."
  `(let ((,listener (usocket:socket-listen "127.0.0.1" 0
                                           :reuse-address t
                                           :element-type '(unsigned-byte 8))))
     (unwind-protect
          (let ((,port (usocket:get-local-port ,listener)))
            ,@body)
       (usocket:socket-close ,listener))))

(defun accept-peer (listener &key (timeout 2))
  "Accept one connection on LISTENER within TIMEOUT seconds, and return its
socket; signal an error if none arrives."
  (or (and (usocket:wait-for-input listener :timeout timeout :ready-only t)
           (usocket:socket-accept listener :element-type '(unsigned-byte 8)))
      (error "No connection arrived at the loopback listener.")))

(defun peer-send (peer &rest parts)
  "Send PARTS, bytes or strings, from the PEER socket."
  (let ((stream (usocket:socket-stream peer)))
    (write-sequence (apply #'octets parts) stream)
    (force-output stream)))

(defun peer-receive (peer)
  "Read every byte now available on the PEER socket, without blocking."
  (let ((stream (usocket:socket-stream peer))
        (bytes '()))
    (loop :while (listen stream)
          :do (let ((b (read-byte stream nil nil)))
                (if b (push b bytes) (return))))
    (coerce (nreverse bytes) '(vector (unsigned-byte 8)))))

(defun exchange (peer poll &key (until (constantly nil)) (timeout 1))
  "Collect what reaches PEER while calling POLL, the client's side, until UNTIL
returns true of the bytes collected, or TIMEOUT seconds pass. Return the
bytes collected."
  (let ((received (make-array 0 :element-type '(unsigned-byte 8)
                                :adjustable t :fill-pointer 0)))
    (wait-for-predicate (lambda ()
                          (funcall poll)
                          (loop :for b :across (peer-receive peer)
                                :do (vector-push-extend b received))
                          (funcall until received))
                        :timeout timeout)
    (coerce received '(vector (unsigned-byte 8)))))

(defun bytes-contain-p (bytes &rest sequence)
  "True when BYTES contain SEQUENCE, a list of bytes and strings, in order."
  (search (apply #'octets sequence) bytes))

(defun count-occurrences (bytes &rest sequence)
  "The number of places at which SEQUENCE, bytes and strings, occurs in BYTES."
  (let ((pattern (apply #'octets sequence)))
    (loop :with start = 0
          :for pos = (search pattern bytes :start2 start)
          :while pos
          :count t
          :do (setf start (1+ pos)))))

;;; ============================================================
;;; Reading Lexter's source  (structural tests)
;;; ============================================================

(defun source-path (relative)
  "The path of RELATIVE within Lexter's source tree."
  (merge-pathnames relative (asdf:system-source-directory :lexter)))

(defun source-forms-named (operator relative-paths)
  "Return a list of (name . file) for each top-level form (OPERATOR name ...)
in the files RELATIVE-PATHS, read as text: a line that begins with
\"(OPERATOR \" gives the token that follows it."
  (let ((prefix (format nil "(~(~a~) " operator))
        (found '()))
    (dolist (relative relative-paths (nreverse found))
      (with-open-file (in (source-path relative))
        (loop :for line = (read-line in nil)
              :while line
              :when (and (>= (length line) (length prefix))
                         (string-equal prefix line :end2 (length prefix)))
                :do (let* ((start (length prefix))
                           (end (or (position-if (lambda (c) (member c '(#\Space #\) #\Tab)))
                                                 line :start start)
                                    (length line))))
                      (push (cons (string-downcase (subseq line start end)) relative)
                            found)))))))
