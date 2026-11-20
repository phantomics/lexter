(in-package #:lexter/vt-handler)

;;; Debug flag
(defvar *debug-vt* nil "Set to T to enable VT debug output.")

;;;; VT Handler: translates cl-vt parser callbacks into terminal model operations.
;;;;
;;;; Medium scope implementation:
;;;; - Print characters
;;;; - C0 controls (CR, LF, BS, HT, BEL)
;;;; - Cursor movement (CUU, CUD, CUF, CUB, CUP, CHA, VPA, CNL, CPL)
;;;; - Erase operations (ED, EL, ECH)
;;;; - Insert/Delete (ICH, DCH, IL, DL)
;;;; - Scrolling (SU, SD, DECSTBM)
;;;; - SGR attributes and colors
;;;; - Mode switching (cursor visibility, alternate screen, autowrap)
;;;; - Cursor save/restore (DECSC/DECRC)
;;;; - Window title (OSC 0/2)

;;; --------------------------------------------------------------------------
;;; cl-vt accessor helpers (these aren't exported, so we define them here)
;;; --------------------------------------------------------------------------

;; (defun parser-get-param (parser index &optional default)
;;   "Get parameter at INDEX, returning DEFAULT if not present or empty."
;;   (if (< index (cl-vt:vt-parser-num-params parser))
;;       (let ((p (aref (cl-vt:vt-parser-params parser) index)))
;;         (if (= p -1) default p))
;;       default))

;; (defun parser-params-list (parser)
;;   "Return the collected parameters as a list."
;;   (loop :for i :below (cl-vt:vt-parser-num-params parser)
;;         :collect (let ((p (aref (cl-vt:vt-parser-params parser) i)))
;;                    (if (= p -1) nil p))))

;; (defun parser-intermediate-chars-list (parser)
;;   "Return the collected intermediate characters as a list of bytes."
;;   (loop :for i :below (cl-vt:vt-parser-num-intermediate-chars parser)
;;         :collect (aref (cl-vt:vt-parser-intermediate-chars parser) i)))

;;; --------------------------------------------------------------------------
;;; VT handler structure
;;; --------------------------------------------------------------------------

(defstruct (vt-handler (:constructor %make-vt-handler))
  "Handler that connects cl-vt parser to terminal model."
  ;; The terminal screen model
  (screen nil :type (or null lexter/model:screen))
  ;; The glyph atlas (for codepoint -> glyph index mapping)
  (atlas nil)
  ;; The cl-vt parser instance  
  (parser nil)
  ;; Current SGR state (for new characters): the style as the host sent it,
  ;; and its id once interned
  (current-style    (make-style) :type style)
  (current-style-id 0 :type (or null fixnum))
  ;; Saved cursor state (DECSC/DECRC -- ESC 7 / ESC 8)
  (saved-col       0  :type fixnum)
  (saved-row       0  :type fixnum)
  (saved-style     (make-style) :type style)
  ;; Alternate screen buffer (DEC private modes 47 / 1047 / 1048 / 1049).
  ;; SCREEN is always the *active* buffer (all write ops use it). PRIMARY-SCREEN
  ;; holds the normal buffer while the alternate is active; ALT-SCREEN is the
  ;; persistent alternate buffer (created lazily, reused so mode 47's no-clear
  ;; semantics work). The renderer must follow VT-HANDLER-SCREEN, not a cached
  ;; reference, so a buffer swap becomes visible.
  (primary-screen  nil)
  (alt-screen      nil)
  (in-alt-screen   nil :type boolean)
  ;; Dedicated cursor save for 1048/1049 (kept separate from DECSC's slots so
  ;; the two save/restore mechanisms never interfere).
  (alt-saved-col   0  :type fixnum)
  (alt-saved-row   0  :type fixnum)
  (alt-saved-style (make-style) :type style)
  ;; Autowrap mode
  (autowrap        t   :type boolean)
  ;; Application callback for actions we can't handle
  (callback        nil :type (or null function))
  ;; Tab stops (bit vector, 1 = tab stop at that column)
  (tab-stops       nil :type (or null simple-bit-vector))
  ;; Window title (set via OSC)
  (window-title    ""  :type string)
  ;; UTF-8 decoding state
  (utf8-bytes-needed 0 :type (integer 0 3))      ; remaining bytes expected
  (utf8-codepoint    0 :type (unsigned-byte 32)) ; accumulated codepoint
  ;; Encoding mode: :utf8 (default) or :cp437 (for BBS/DOS compatibility)
  (encoding        :utf8 :type keyword)
  ;; Bold-as-bright: when T, bold attribute promotes fg colors 0-7 to 8-15
  ;; Classic BBS behavior (ESC[1;31m = bright red, not bold dark red)
  ;; CP437 translation table (nil = use default from lexter/telnet)
  (cp437-table     nil :type (or null (simple-array (unsigned-byte 32) (256))))
  ;; Raw-input recording (test rig). NIL = off; otherwise an adjustable
  ;; (unsigned-byte 8) vector with a fill pointer that accumulates every byte
  ;; fed to PROCESS-OUTPUT. Recording is a pure tap: it never alters parsing.
  (recording       nil :type (or null (array (unsigned-byte 8) (*))))
  ;; Mouse reporting (xterm DEC private modes). MOUSE-TRACKING selects WHICH
  ;; events the application wants reported:
  ;;   NIL      -> off
  ;;   :normal  -> mode 1000: button press/release only
  ;;   :button  -> mode 1002: + motion while a button is held (drag)
  ;;   :any     -> mode 1003: + all motion
  ;; MOUSE-ENCODING selects HOW events are encoded (orthogonal axis):
  ;;   :x10     -> legacy CSI M Cb Cx Cy (default; 223-cell coordinate cap)
  ;;   :sgr     -> mode 1006: CSI < b ; x ; y M/m (no cap, explicit press/release)
  (mouse-tracking  nil :type (member nil :normal :button :any))
  (mouse-encoding  :x10 :type (member :x10 :sgr))
  )

;;; --------------------------------------------------------------------------
;;; Constructor
;;; --------------------------------------------------------------------------

(defun %default-tab-stops (cols)
  "A tab-stop vector for COLS columns, with a stop every eight columns."
  (let ((tabs (make-array cols :element-type 'bit :initial-element 0)))
    (loop :for i :from 0 :below cols :by 8
          :do (setf (sbit tabs i) 1))
    tabs))

(defun vt-handler-bold-as-bright (handler)
  "True when HANDLER's terminal draws bold text of palette colours 0-7 in
   colours 8-15 (LEXTER-D125)."
  (style-table-bold-as-bright (screen-styles (vt-handler-screen handler))))

(defun (setf vt-handler-bold-as-bright) (value handler)
  "Set the bold-as-bright rule of HANDLER's terminal, and mark its screens'
   rows to be built again under it (LEXTER-D125)."
  (setf (style-table-bold-as-bright (screen-styles (vt-handler-screen handler))) value)
  (dolist (screen (list (vt-handler-primary-screen handler) (vt-handler-alt-screen handler)))
    (when screen
      (mark-screen-dirty screen)))
  value)

(defun make-vt-handler (screen atlas &key callback (encoding :utf8) bold-as-bright)
  "Create a VT handler for SCREEN using ATLAS for codepoint mapping.
   CALLBACK is called for unhandled sequences: (funcall callback :type data).
   ENCODING is :utf8 (default) or :cp437 (for BBS/DOS compatibility).
   BOLD-AS-BRIGHT when T draws bold text of palette colours 0-7 in colours
   8-15, a setting of the terminal's that its rows are built under
   (LEXTER-D125)."
  (let* ((cols (screen-cols screen))
         (tab-stops (%default-tab-stops cols))
         (handler (%make-vt-handler :screen screen
                                    :primary-screen screen
                                    :atlas atlas
                                    :callback callback
                                    :tab-stops tab-stops
                                    :encoding encoding)))
    (setf (style-table-bold-as-bright (screen-styles screen)) bold-as-bright)
    ;; Create parser with our dispatch function
    (setf (vt-handler-parser handler)
          (cl-vt:make-vt-parser (lambda (parser action byte)
                                  (dispatch-action handler parser action byte))
                                :user-data handler
                                :utf8 t))
    handler))

;;; --------------------------------------------------------------------------
;;; Main entry point
;;; --------------------------------------------------------------------------

(defun process-output (handler data &key (start 0) end)
  "Process terminal output DATA through the handler.
   DATA should be a (vector (unsigned-byte 8)).

   When recording is active (see START-RECORDING), every byte in the processed
   range is appended to the recording buffer *before* parsing, capturing the
   exact host->terminal stream for later deterministic replay. Recording is a
   pure tap and does not change parsing behavior."
  (let ((rec (vt-handler-recording handler)))
    (when rec
      (loop :for i :from start :below (or end (length data))
            :do (vector-push-extend (aref data i) rec))))
  (cl-vt:vt-parse (vt-handler-parser handler) data start end))

;;; --------------------------------------------------------------------------
;;; Raw-input recording (test rig authoring)
;;; --------------------------------------------------------------------------

(defun start-recording (handler)
  "Begin recording the raw byte stream fed to PROCESS-OUTPUT.
   Allocates a fresh growable buffer, discarding any previous recording.
   Returns HANDLER."
  (setf (vt-handler-recording handler)
        (make-array 4096 :element-type '(unsigned-byte 8)
                         :adjustable t :fill-pointer 0))
  handler)

(defun stop-recording (handler)
  "Stop recording and return the captured bytes as a fresh simple
   (unsigned-byte 8) vector. Returns NIL if recording was not active."
  (let ((rec (vt-handler-recording handler)))
    (setf (vt-handler-recording handler) nil)
    (when rec
      (let ((out (make-array (fill-pointer rec)
                             :element-type '(unsigned-byte 8))))
        (replace out rec)
        out))))

(defun recording-active-p (handler)
  "Return T if HANDLER is currently recording its input stream."
  (and (vt-handler-recording handler) t))

;;; --------------------------------------------------------------------------
;;; Action dispatch
;;; --------------------------------------------------------------------------

(defun dispatch-action (handler parser action byte)
  "Dispatch a parser action to the appropriate handler. An operating-system
   command is read whole when it ends, from the parser's buffer, which holds
   its first 512 bytes (CLVT-D4, LEXTER-D68)."
  (when *debug-vt*
    (format t "~&[DISPATCH] action=~S byte=~D (#x~X)~%" action byte byte))
  (case action
    (:print       (handle-print handler byte))
    (:execute     (handle-execute handler byte))
    (:csi-dispatch (handle-csi-with-final handler byte))
    (:esc-dispatch (handle-esc handler byte))
    (:osc-end     (handle-osc handler (%osc-text handler (cl-vt:vt-parser-osc-bytes parser))))
    (otherwise    nil)))

;;; --------------------------------------------------------------------------
;;; Print handler with UTF-8 decoding
;;; --------------------------------------------------------------------------

(defun %wrap-to-next-line (handler &key soft)
  "Move the cursor to the start of the next row, as autowrap and NEL do: a
   carriage return and a line feed, which applies the scrolling region
   (LEXTER-D69). SOFT, for autowrap, marks the row left as continuing on the
   next (LEXTER-D119)."
  (let ((screen (vt-handler-screen handler)))
    (when soft
      (set-row-soft-wrap screen (cursor-row screen) t))
    (set-cursor-position screen 0 (cursor-row screen))
    (line-feed screen)))

(defun %print-codepoint (handler codepoint)
  "Print a fully-decoded Unicode codepoint at the cursor. Its width comes from
   the width table, through the atlas's width policy (LEXTER-D117): a character
   of width 0 joins the cell of the character before it (LEXTER-D119); a
   character of width 2 is written as a pair and moves the cursor two columns,
   wrapping first when it would begin in the last column (LEXTER-D98). Which
   glyph draws it is decided when its row is built."
  (let* ((screen (vt-handler-screen handler))
         (atlas (vt-handler-atlas handler))
         (width (lexter/width:char-width codepoint
                                         (if atlas
                                             (lexter/atlas:atlas-width-policy atlas)
                                             lexter/width:*default-width-policy*))))
    (when (zerop width)
      (join-character screen codepoint)
      (return-from %print-codepoint))
    (when (and (= width 2) (< (screen-cols screen) 2))
      (setf width 1))
    ;; A pair cannot begin in the last column: blank it and wrap first, or,
    ;; without autowrap, write the pair in the last two columns.
    (when (and (= width 2) (= (cursor-col screen) (1- (screen-cols screen))))
      (if (vt-handler-autowrap handler)
          (progn
            (erase-chars screen 1)
            (%wrap-to-next-line handler :soft t))
          (set-cursor-position screen (- (screen-cols screen) 2) (cursor-row screen))))
    (%write-printed-char handler codepoint width)))

(defun %write-printed-char (handler codepoint width)
  "Write CODEPOINT, of WIDTH 1 or 2, at the cursor in the current style, where
   it has room, and advance the cursor by WIDTH. A character that reaches the
   last column wraps the row when autowrap is on, and otherwise leaves it
   unwrapped (LEXTER-D119)."
  (let* ((screen (vt-handler-screen handler))
         (cols (screen-cols screen))
         (col (cursor-col screen))
         (row (cursor-row screen)))
    (when *debug-vt*
      (format t "~&[PRINT] codepoint=~D (#x~X) width=~D~%" codepoint codepoint width))
    (write-char-at screen col row codepoint
                   :style (%current-style-id handler)
                   :wide (= width 2))
    (let ((new-col (+ col width)))
      (cond
        ((< new-col cols)
         (set-cursor-position screen new-col row))
        ((vt-handler-autowrap handler)
         (%wrap-to-next-line handler :soft t))
        (t
         ;; Stay at right edge
         (set-row-soft-wrap screen row nil)
         (set-cursor-position screen (1- cols) row))))))

(defun %utf8-step (byte needed codepoint)
  "Take BYTE into a UTF-8 decoder whose state is NEEDED, the continuation
   bytes still expected, and CODEPOINT, the value so far. Return three values:
   the codepoint BYTE completes, or NIL; and the new NEEDED and CODEPOINT. A
   continuation byte that no lead byte expects, and a byte that cannot begin a
   sequence, are passed over; a new lead byte or an ASCII byte abandons a
   sequence left incomplete. A value beyond Unicode, or a surrogate, completes
   as U+FFFD, so that no host reaches the values above U+10FFFF where Lexter
   names its generated glyphs (LEXTER-D68, LEXTER-D89). Printed text and
   operating-system commands are decoded alike (CLVT-D3)."
  (cond
    ;; Continuation byte (10xxxxxx)
    ((= (logand byte #xC0) #x80)
     (if (plusp needed)
         (let ((value (logior (ash codepoint 6) (logand byte #x3F)))
               (needed (1- needed)))
           (if (zerop needed)
               (values (if (or (> value #x10FFFF) (<= #xD800 value #xDFFF))
                           #xFFFD
                           value)
                       0 0)
               (values nil needed value)))
         (values nil needed codepoint)))
    ;; ASCII (0xxxxxxx)
    ((< byte #x80) (values byte 0 0))
    ;; Lead bytes of 2, 3, and 4 bytes
    ((= (logand byte #xE0) #xC0) (values nil 1 (logand byte #x1F)))
    ((= (logand byte #xF0) #xE0) (values nil 2 (logand byte #x0F)))
    ((= (logand byte #xF8) #xF0) (values nil 3 (logand byte #x07)))
    ;; A byte that cannot begin a sequence
    (t (values nil needed codepoint))))

(defun %osc-text (handler bytes)
  "Decode BYTES, an operating-system command's data, as HANDLER decodes
   printed text: through the CP437 table in CP437 mode, and otherwise as UTF-8,
   dropping a character that the parser's limit cut short."
  (if (eq (vt-handler-encoding handler) :cp437)
      (let ((table (or (vt-handler-cp437-table handler)
                       lexter/telnet:+cp437-to-unicode+)))
        (map 'string (lambda (byte) (code-char (aref table byte))) bytes))
      (let ((out (make-string-output-stream))
            (needed 0)
            (codepoint 0))
        (loop :for byte :across bytes
              :do (multiple-value-bind (done next value) (%utf8-step byte needed codepoint)
                    (setf needed next codepoint value)
                    (when done
                      (write-char (code-char done) out))))
        (get-output-stream-string out))))

(defun handle-print (handler byte)
  "Handle a printable byte, decoding UTF-8 sequences into codepoints.
   In CP437 mode, bytes are translated directly via the CP437 table."
  (when *debug-vt*
    (format t "~&[PRINT-BYTE] byte=~D (#x~X) encoding=~S~%" 
            byte byte (vt-handler-encoding handler)))
  ;; CP437 mode: direct byte-to-codepoint translation (no UTF-8 decoding)
  (when (eq (vt-handler-encoding handler) :cp437)
    (let* ((table (or (vt-handler-cp437-table handler)
                      lexter/telnet:+cp437-to-unicode+))
           (codepoint (aref table byte)))
      (%print-codepoint handler codepoint))
    (return-from handle-print))
  ;; UTF-8 mode below
  ;; Ignore DEL (0x7F) - it should not reach here but just in case
  (when (= byte #x7F)
    (return-from handle-print))
  (multiple-value-bind (codepoint needed value)
      (%utf8-step byte
                  (vt-handler-utf8-bytes-needed handler)
                  (vt-handler-utf8-codepoint handler))
    (setf (vt-handler-utf8-bytes-needed handler) needed
          (vt-handler-utf8-codepoint handler) value)
    (when codepoint
      (%print-codepoint handler codepoint))))

;;; --------------------------------------------------------------------------
;;; C0 control handlers
;;; --------------------------------------------------------------------------

(defun handle-execute (handler byte)
  "Handle C0 control characters."
  (when *debug-vt*
    (format t "~&[EXECUTE] byte=~D (#x~X)~%" byte byte))
  (let ((screen (vt-handler-screen handler)))
    (case byte
      (#x07 ; BEL - bell
       (when (vt-handler-callback handler)
         (funcall (vt-handler-callback handler) :bell nil)))
      (#x08 ; BS - backspace
       (when *debug-vt*
         (format t "~&[EXECUTE] BS: moving cursor left~%"))
       (let ((col (cursor-col screen)))
         (when (> col 0)
           (set-cursor-position screen (1- col) (cursor-row screen)))))
      (#x09 ; HT - horizontal tab
       (let* ((col (cursor-col screen))
              (cols (screen-cols screen))
              (tabs (vt-handler-tab-stops handler))
              (next-tab (loop :for i :from (1+ col) :below (min cols (length tabs))
                              :when (= 1 (sbit tabs i))
                              :return i
                              :finally (return (1- cols)))))
         (set-cursor-position screen next-tab (cursor-row screen))))
      ((#x0A #x0B #x0C) ; LF, VT, FF - line feed
       (line-feed screen))
      (#x0D ; CR - carriage return
       (set-cursor-position screen 0 (cursor-row screen)))
      (otherwise nil))))

;;; --------------------------------------------------------------------------
;;; CSI sequence handlers
;;; --------------------------------------------------------------------------

;;; Note: The old handle-csi was replaced by handle-csi-with-final which receives
;;; the final byte directly from the parser callback.

(defun handle-csi-with-final (handler byte)
  "Handle CSI sequence with final BYTE."
  (let* ((parser (vt-handler-parser handler))
         (screen (vt-handler-screen handler))
         (intermediates (vt-parser-intermediate-chars-list parser))
         (private-p (and intermediates (= (first intermediates) #x3F))))  ; '?'
    (flet ((param (n &optional (default 1))
             (or (vt-parser-get-param parser n) default)))
      (cond
        ;; Private mode sequences (CSI ? ... h/l)
        (private-p
         (case byte
           (#x68 (handle-decset handler (param 0)))   ; h - DECSET
           (#x6C (handle-decrst handler (param 0))))) ; l - DECRST
        ;; Standard CSI sequences
        (t
         (case byte
           ;; Cursor movement
           (#x41 ; A - CUU (Cursor Up)
            (let ((n (param 0)))
              (set-cursor-position screen (cursor-col screen)
                                   (max 0 (- (cursor-row screen) n)))))
           (#x42 ; B - CUD (Cursor Down)
            (let ((n (param 0)))
              (set-cursor-position screen (cursor-col screen)
                                   (min (1- (screen-rows screen))
                                        (+ (cursor-row screen) n)))))
           (#x43 ; C - CUF (Cursor Forward)
            (let ((n (param 0)))
              (set-cursor-position screen
                                   (min (1- (screen-cols screen))
                                        (+ (cursor-col screen) n))
                                   (cursor-row screen))))
           (#x44 ; D - CUB (Cursor Back)
            (let ((n (param 0)))
              (set-cursor-position screen
                                   (max 0 (- (cursor-col screen) n))
                                   (cursor-row screen))))
           (#x45 ; E - CNL (Cursor Next Line)
            (let ((n (param 0)))
              (set-cursor-position screen 0
                                   (min (1- (screen-rows screen))
                                        (+ (cursor-row screen) n)))))
           (#x46 ; F - CPL (Cursor Previous Line)
            (let ((n (param 0)))
              (set-cursor-position screen 0
                                   (max 0 (- (cursor-row screen) n)))))
           (#x47 ; G - CHA (Cursor Horizontal Absolute)
            (let ((n (param 0)))
              (set-cursor-position screen (max 0 (min (1- (screen-cols screen)) (1- n)))
                                   (cursor-row screen))))
           ((#x48 #x66) ; H/f - CUP (Cursor Position)
            (let ((row (1- (param 0)))
                  (col (1- (param 1))))
              (set-cursor-position screen
                                   (max 0 (min (1- (screen-cols screen)) col))
                                   (max 0 (min (1- (screen-rows screen)) row)))))
           (#x64 ; d - VPA (Vertical Position Absolute)
            (let ((n (param 0)))
              (set-cursor-position screen (cursor-col screen)
                                   (max 0 (min (1- (screen-rows screen)) (1- n))))))
           ;; Erase operations
           ;; A mode xterm does not define is ignored (LEXTER-D68)
           (#x4A ; J - ED (Erase in Display)
            (let ((mode (param 0 0)))
              (when (<= 0 mode 3)
                (erase-in-display screen mode))))
           (#x4B ; K - EL (Erase in Line)
            (let ((mode (param 0 0)))
              (when (<= 0 mode 2)
                (erase-in-line screen mode))))
           (#x58 ; X - ECH (Erase Characters)
            (erase-chars screen (param 0)))
           ;; Insert/Delete
           (#x40 ; @ - ICH (Insert Characters)
            (insert-chars screen (param 0)))
           (#x50 ; P - DCH (Delete Characters)
            (delete-chars screen (param 0)))
           (#x4C ; L - IL (Insert Lines)
            (insert-lines screen (param 0)))
           (#x4D ; M - DL (Delete Lines)
            (delete-lines screen (param 0)))
           ;; Scrolling
           (#x53 ; S - SU (Scroll Up)
            (scroll-up screen (param 0)))
           (#x54 ; T - SD (Scroll Down)
            (scroll-down screen (param 0)))
           (#x72 ; r - DECSTBM (Set Top and Bottom Margins)
            ;; A margin given as 0 takes its default, the window's edge; a
            ;; region whose top is not above its bottom is ignored, as the
            ;; VT100 requires the top margin to be less than the bottom
            ;; (LEXTER-D68)
            (let* ((rows (screen-rows screen))
                   (top (let ((p (param 0 1))) (if (zerop p) 1 p)))
                   (bottom (let ((p (param 1 rows))) (if (zerop p) rows (min p rows)))))
              (when (< top bottom)
                (set-scrolling-region screen (1- top) (1- bottom))
                (set-cursor-position screen 0 0))))
           ;; SGR (Select Graphic Rendition)
           (#x6D ; m - SGR
            (handle-sgr handler))
           ;; Device Status Report
           (#x6E ; n - DSR
            (when (= (param 0) 6)  ; Report cursor position
              (when (vt-handler-callback handler)
                (funcall (vt-handler-callback handler) :report-cursor
                         (format nil "~c[~d;~dR" #\Escape
                                 (1+ (cursor-row screen))
                                 (1+ (cursor-col screen)))
                         ;; (list (cursor-row screen)
                         ;;       (cursor-col screen))
                         ))))
           ;; Modes
           (#x68 ; h - SM (Set Mode)
            nil) ; Standard modes not commonly used
           (#x6C ; l - RM (Reset Mode)
            nil)
           (otherwise
            (when (vt-handler-callback handler)
              (funcall (vt-handler-callback handler) :unknown-csi
                       (list :final byte :params (vt-parser-params-list parser)))))))))))

;;; --------------------------------------------------------------------------
;;; SGR (Select Graphic Rendition) handler
;;; --------------------------------------------------------------------------

(defun handle-sgr (handler)
  "Handle an SGR sequence, which sets the attributes of the text that follows.
   The current style is recorded as the host sent it: colours as the default,
   a palette index, or 24-bit values, and the other attributes as flags; how
   they are drawn is decided when rows are built (LEXTER-D125)."
  (let* ((parser (vt-handler-parser handler))
         (params (or (vt-parser-params-list parser) '(0)))
         ;; A new style: an interned one is never changed
         (style (copy-style (vt-handler-current-style handler))))
    (let ((i 0))
      (loop :while (< i (length params))
            :for p = (or (nth i params) 0)
            :do (cond
                  ((= p 0) (setf style (make-style)))
                  ((= p 1) (setf (style-bold style) t))
                  ;; Dim/faint and italic are not kept
                  ((= p 2) nil)
                  ((= p 3) nil)
                  ((= p 4) (setf (style-underline style) t))
                  ((= p 5) (setf (style-blink style) t))
                  ((= p 7) (setf (style-reverse style) t))
                  ((= p 8) (setf (style-invisible style) t))
                  ((= p 9) (setf (style-strikethrough style) t))
                  ;; 21 resets bold, as the first edition had it
                  ((member p '(21 22)) (setf (style-bold style) nil))
                  ((= p 24) (setf (style-underline style) nil))
                  ((= p 25) (setf (style-blink style) nil))
                  ((= p 27) (setf (style-reverse style) nil))
                  ((= p 28) (setf (style-invisible style) nil))
                  ((= p 29) (setf (style-strikethrough style) nil))
                  ((<= 30 p 37) (setf (style-foreground style) (palette-colour (- p 30))))
                  ((= p 39) (setf (style-foreground style) +default-colour+))
                  ((<= 40 p 47) (setf (style-background style) (palette-colour (- p 40))))
                  ((= p 49) (setf (style-background style) +default-colour+))
                  ((= p 53) (setf (style-overline style) t))
                  ((= p 55) (setf (style-overline style) nil))
                  ((= p 59) (setf (style-underline-colour style) +default-colour+))
                  ((<= 90 p 97) (setf (style-foreground style) (palette-colour (+ 8 (- p 90)))))
                  ((<= 100 p 107) (setf (style-background style) (palette-colour (+ 8 (- p 100)))))
                  ;; Extended colours: 38 foreground, 48 background, 58 lines
                  ((member p '(38 48 58))
                   (multiple-value-bind (colour consumed) (%sgr-extended-colour params i)
                     (when colour
                       (case p
                         (38 (setf (style-foreground style) colour))
                         (48 (setf (style-background style) colour))
                         (58 (setf (style-underline-colour style) colour))))
                     (incf i consumed))))
                (incf i)))
    (%set-current-style handler style)))

(defun %sgr-extended-colour (params i)
  "Read the extended colour whose 38, 48, or 58 is element I of the SGR
   PARAMS: 5;n, an index of the 256-colour palette, or 2;r;g;b, a 24-bit
   colour, kept as the host sent it (LEXTER-D125). Return the colour, or NIL
   when it is incomplete or out of range, and so is ignored (LEXTER-D68): an
   index above 255, or a component above 255, outside the range xterm
   documents. The second value is how many parameters after I the colour
   took."
  (let* ((remaining (- (length params) i 1))
         (kind (and (plusp remaining) (nth (1+ i) params))))
    (flet ((arg (k) (nth (+ i 1 k) params)))
      (case kind
        (5 (if (>= remaining 2)
               (let ((n (arg 1)))
                 (values (and n (<= 0 n 255) (palette-colour n)) 2))
               (values nil remaining)))
        (2 (if (>= remaining 4)
               (let ((r (arg 1)) (g (arg 2)) (b (arg 3)))
                 (values (and r g b (<= 0 r 255) (<= 0 g 255) (<= 0 b 255)
                              (rgb-colour r g b))
                         4))
               (values nil remaining)))
        (otherwise (values nil 0))))))

(defun %set-current-style (handler style)
  "Make STYLE the style of the text HANDLER writes next; it is interned when
   the first character is written in it."
  (setf (vt-handler-current-style handler) style
        (vt-handler-current-style-id handler) nil))

(defun %current-style-id (handler)
  "The id, in the terminal's style table, of the current style."
  (or (vt-handler-current-style-id handler)
      (setf (vt-handler-current-style-id handler)
            (intern-style (screen-styles (vt-handler-screen handler))
                          (vt-handler-current-style handler)))))

;;; --------------------------------------------------------------------------
;;; DEC Private Mode handlers (DECSET/DECRST)
;;; --------------------------------------------------------------------------

;;; --------------------------------------------------------------------------
;;; Alternate screen buffer support (DEC private modes 47/1047/1048/1049)
;;; --------------------------------------------------------------------------

(defun %save-alt-cursor (handler)
  "Save the active screen's cursor and SGR state into the dedicated 1048/1049
   save slots."
  (let ((screen (vt-handler-screen handler)))
    (setf (vt-handler-alt-saved-col   handler) (cursor-col screen)
          (vt-handler-alt-saved-row   handler) (cursor-row screen)
          (vt-handler-alt-saved-style handler) (vt-handler-current-style handler))))

(defun %restore-alt-cursor (handler)
  "Restore the cursor and SGR state saved by %SAVE-ALT-CURSOR onto the (now
   active) screen."
  (let ((screen (vt-handler-screen handler)))
    (%set-current-style handler (vt-handler-alt-saved-style handler))
    (set-cursor-position screen
                         (min (vt-handler-alt-saved-col handler) (1- (screen-cols screen)))
                         (min (vt-handler-alt-saved-row handler) (1- (screen-rows screen))))))

(defun %ensure-alt-screen (handler)
  "Lazily create the persistent alternate buffer, matching the primary's
   dimensions. It shares the primary's style and swatch tables
   (LEXTER-DRAFT-cell-model-revision-D24) and starts from a copy of the
   primary's palette, so that colours the host redefined before it existed
   hold in it too (LEXTER-D70). The alternate buffer carries no scrollback."
  (or (vt-handler-alt-screen handler)
      (let* ((primary (vt-handler-primary-screen handler))
             (alt (make-screen :cols (screen-cols primary)
                               :rows (screen-rows primary)
                               :mode (screen-mode primary)
                               :styles (screen-styles primary)
                               :swatches (screen-swatches primary)
                               :palette (screen-palette primary))))
        ;; Alternate screen has no scrollback (it is exactly viewport-sized).
        (setf (lexter/model::screen-scrollback-enabled alt) nil)
        (setf (vt-handler-alt-screen handler) alt))))

(defun %clear-screen-buffer (screen)
  "Erase the entire SCREEN and home the cursor."
  (erase-in-display screen 2)
  (set-cursor-position screen 0 0))

(defun %enter-alt-screen (handler &key clear)
  "Switch the active buffer to the alternate screen. When CLEAR, erase it first.
   No-op if already on the alternate screen."
  (unless (vt-handler-in-alt-screen handler)
    (let ((alt (%ensure-alt-screen handler)))
      (when clear
        (%clear-screen-buffer alt))
      (setf (vt-handler-primary-screen handler) (vt-handler-screen handler)
            (vt-handler-screen handler) alt
            (vt-handler-in-alt-screen handler) t)
      ;; The display grid is shared between buffers; force a full repaint from
      ;; the now-active screen so its clean rows overwrite the old buffer's.
      (mark-screen-dirty alt))))

(defun %exit-alt-screen (handler &key clear)
  "Switch the active buffer back to the primary screen. When CLEAR, erase the
   alternate buffer (mode 1047 semantics) before switching away.
   No-op if not on the alternate screen."
  (when (vt-handler-in-alt-screen handler)
    (when clear
      (%clear-screen-buffer (vt-handler-screen handler)))
    (setf (vt-handler-screen handler) (vt-handler-primary-screen handler)
          (vt-handler-in-alt-screen handler) nil)
    ;; The display grid is shared between buffers; force a full repaint from
    ;; the restored primary so its clean rows overwrite the alternate's content.
    (mark-screen-dirty (vt-handler-screen handler))))

(defun vt-handler-resize-all (handler new-cols new-rows)
  "Resize every screen buffer owned by HANDLER (primary and, if present, the
   alternate) so that returning from the alternate screen after a resize shows
   a correctly-sized primary."
  (let ((primary (vt-handler-primary-screen handler))
        (alt (vt-handler-alt-screen handler)))
    (when primary (resize-screen primary new-cols new-rows))
    (when alt (resize-screen alt new-cols new-rows))
    ;; The tab stops are rebuilt for the new width (LEXTER-D68)
    (setf (vt-handler-tab-stops handler) (%default-tab-stops new-cols))))

(defun handle-decset (handler mode)
  "Handle DECSET (CSI ? n h)."
  (let ((screen (vt-handler-screen handler)))
    (case mode
      (7    ; Autowrap
       (setf (vt-handler-autowrap handler) t))
      (25   ; Cursor visible
       (when *debug-vt*
         (format t "~&[DECSET] Cursor SHOWN~%"))
       (set-cursor-visible screen t))
      (47   ; Switch to alternate screen (no clear)
       (%enter-alt-screen handler))
      (1047 ; Switch to alternate screen (cleared on exit, not entry)
       (%enter-alt-screen handler))
      (1048 ; Save cursor
       (%save-alt-cursor handler))
      (1049 ; Save cursor, switch to a freshly-cleared alternate screen
       (%save-alt-cursor handler)
       (%enter-alt-screen handler :clear t))
      ;; Mouse tracking modes (1000/1002/1003 select the tracking level;
      ;; 1006 selects SGR encoding -- an orthogonal axis).
      (1000 (setf (vt-handler-mouse-tracking handler) :normal))
      (1002 (setf (vt-handler-mouse-tracking handler) :button))
      (1003 (setf (vt-handler-mouse-tracking handler) :any))
      (1006 (setf (vt-handler-mouse-encoding handler) :sgr))
      (otherwise
       (when (vt-handler-callback handler)
         (funcall (vt-handler-callback handler) :unknown-decset mode))))))

(defun handle-decrst (handler mode)
  "Handle DECRST (CSI ? n l)."
  (let ((screen (vt-handler-screen handler)))
    (case mode
      (7    ; Autowrap off
       (setf (vt-handler-autowrap handler) nil))
      (25   ; Cursor invisible
       (when *debug-vt*
         (format t "~&[DECRST] Cursor HIDDEN~%"))
       (set-cursor-visible screen nil))
      (47   ; Switch back to primary screen (no clear)
       (%exit-alt-screen handler))
      (1047 ; Clear the alternate screen, then switch back to primary
       (%exit-alt-screen handler :clear t))
      (1048 ; Restore cursor
       (%restore-alt-cursor handler))
      (1049 ; Switch back to primary screen and restore cursor
       (%exit-alt-screen handler)
       (%restore-alt-cursor handler))
      ;; Mouse tracking off. The three tracking levels collapse to one slot, so
      ;; resetting any of them turns reporting off (apps reset symmetrically).
      ((1000 1002 1003) (setf (vt-handler-mouse-tracking handler) nil))
      (1006 (setf (vt-handler-mouse-encoding handler) :x10))
      (otherwise
       (when (vt-handler-callback handler)
         (funcall (vt-handler-callback handler) :unknown-decrst mode))))))

;;; --------------------------------------------------------------------------
;;; Mouse event encoding (xterm reporting modes 1000/1002/1003 + 1006)
;;; --------------------------------------------------------------------------
;;;
;;; xterm button codes (the low value passed as BUTTON here):
;;;   0 left, 1 middle, 2 right, 3 "no button" (used for bare motion in 1003),
;;;   64 wheel-up, 65 wheel-down, 66 wheel-left, 67 wheel-right.
;;; Modifier bits OR'd in: shift 4, meta/alt 8, control 16. Motion bit: 32.

(defun %ascii-bytes (string)
  "Convert an all-ASCII STRING to a simple (unsigned-byte 8) vector."
  (let ((out (make-array (length string) :element-type '(unsigned-byte 8))))
    (dotimes (i (length string) out)
      (setf (aref out i) (char-code (char string i))))))

(defun %mouse-modifier-bits (mods)
  "Sum the xterm modifier bits for the GLFW MODS list (:shift :control :alt)."
  (logior (if (member :shift   mods) 4  0)
          (if (member :alt     mods) 8  0)
          (if (member :control mods) 16 0)))

(defun encode-mouse-sgr (cb col row press-p)
  "Pure SGR (1006) encoder. CB is the full button code (button + modifier +
   motion bits). COL/ROW are 0-based; emitted 1-based. PRESS-P selects the
   final 'M' (press/motion) vs 'm' (release). Returns an (unsigned-byte 8)
   vector. No coordinate limit."
  (%ascii-bytes (format nil "~C[<~D;~D;~D~C"
                        (code-char 27) cb (1+ col) (1+ row)
                        (if press-p #\M #\m))))

(defun encode-mouse-x10 (cb col row)
  "Pure X10/normal encoder: CSI M (32+cb) (32+col+1) (32+row+1). Returns an
   (unsigned-byte 8) vector, or NIL when a coordinate exceeds the 223-cell
   limit the encoding cannot represent."
  (when (and (<= 0 col 222) (<= 0 row 222))
    (make-array 6 :element-type '(unsigned-byte 8)
                  :initial-contents (list 27 #x5B #x4D
                                          (logand (+ 32 cb) #xFF)
                                          (+ 33 col) (+ 33 row)))))

(defun mouse-report-bytes (handler col row button action mods &key motion)
  "Return the byte sequence reporting a mouse event for HANDLER's active mouse
   mode, or NIL when the event is not reported (tracking off, or a motion event
   the current tracking level ignores). COL/ROW are 0-based pane-relative cells.
   BUTTON is an xterm button code (see above). ACTION is :press or :release
   (wheel events use :press). MOTION non-NIL marks a motion event.

   Gating by tracking level:
     :normal -> motion never reported
     :button -> motion reported only while a button is held (BUTTON /= 3)
     :any    -> all motion reported"
  (let ((mode (vt-handler-mouse-tracking handler)))
    (cond
      ((null mode) nil)
      ((and motion (eq mode :normal)) nil)
      ((and motion (eq mode :button) (= button 3)) nil)
      (t
       (let ((mod+motion (logior (%mouse-modifier-bits mods) (if motion 32 0))))
         (ecase (vt-handler-mouse-encoding handler)
           (:sgr (encode-mouse-sgr (logior button mod+motion) col row
                                   (eq action :press)))
           ;; X10 release reports the ambiguous "button 3"; press/wheel keep
           ;; their button. (Default path until an app requests 1006.)
           (:x10 (encode-mouse-x10
                  (logior (if (eq action :release) 3 button) mod+motion)
                  col row))))))))

;;; --------------------------------------------------------------------------
;;; ESC sequence handlers
;;; --------------------------------------------------------------------------

(defun handle-esc (handler byte)
  "Handle ESC sequence with final BYTE."
  (let* ((parser (vt-handler-parser handler))
         (intermediates (vt-parser-intermediate-chars-list parser))
         (screen (vt-handler-screen handler)))
    (cond
      ;; No intermediates
      ((null intermediates)
       (case byte
         (#x37 ; ESC 7 - DECSC (Save Cursor)
          (setf (vt-handler-saved-col handler) (cursor-col screen)
                (vt-handler-saved-row handler) (cursor-row screen)
                (vt-handler-saved-style handler) (vt-handler-current-style handler)))
         (#x38 ; ESC 8 - DECRC (Restore Cursor)
          (set-cursor-position screen
                               (vt-handler-saved-col handler)
                               (vt-handler-saved-row handler))
          (%set-current-style handler (vt-handler-saved-style handler)))
         (#x44 ; ESC D - IND (Index, line feed)
          (line-feed screen))
         (#x45 ; ESC E - NEL (Next Line)
          (%wrap-to-next-line handler))
         (#x4D ; ESC M - RI (Reverse Index)
          (reverse-line-feed screen))
         (#x63 ; ESC c - RIS (Reset to Initial State)
          (reset-handler handler))
         (otherwise
          (when (vt-handler-callback handler)
            (funcall (vt-handler-callback handler) :unknown-esc byte)))))
      ;; With intermediates
      (t
       (when (vt-handler-callback handler)
         (funcall (vt-handler-callback handler) :unknown-esc-seq
                  (list :final byte :intermediates intermediates)))))))

;;; --------------------------------------------------------------------------
;;; OSC sequence handlers
;;; --------------------------------------------------------------------------

;;; --- OSC palette control (OSC 4/104 and OSC 10/11/12) ------------------------

(defun %split-on-char (string char)
  "Split STRING into a list of substrings on CHAR (no empty-trimming)."
  (loop :with start = 0
        :for pos = (position char string :start start)
        :collect (subseq string start (or pos (length string)))
        :while pos
        :do (setf start (1+ pos))))

(defun %scale-hex-component (str)
  "Parse a 1-4 digit hex STR and scale it to an 8-bit value (0-255), or NIL."
  (let ((digits (length str)))
    (when (<= 1 digits 4)
      (let ((v (parse-integer str :radix 16 :junk-allowed t)))
        (when v
          (let ((maxv (1- (expt 16 digits))))
            (if (zerop maxv) 0 (round (* v 255) maxv))))))))

(defun %parse-osc-color (spec)
  "Parse an OSC color SPEC into (VALUES R G B) in 0-255, or NIL if unparseable.
   Accepts the X color formats ncurses/xterm emit: rgb:R/G/B (1-4 hex digits per
   channel) and #RGB / #RRGGBB / #RRRRGGGGBBBB. A query (?) returns NIL."
  (cond
    ((and (>= (length spec) 4) (string-equal "rgb:" spec :end2 4))
     (let ((parts (%split-on-char (subseq spec 4) #\/)))
       (when (= (length parts) 3)
         (let ((r (%scale-hex-component (first parts)))
               (g (%scale-hex-component (second parts)))
               (b (%scale-hex-component (third parts))))
           (when (and r g b) (values r g b))))))
    ((and (> (length spec) 1) (char= (char spec 0) #\#))
     (let* ((hex (subseq spec 1)) (n (length hex)))
       (when (and (plusp n) (zerop (mod n 3)))
         (let ((d (floor n 3)))
           (let ((r (%scale-hex-component (subseq hex 0 d)))
                 (g (%scale-hex-component (subseq hex d (* 2 d))))
                 (b (%scale-hex-component (subseq hex (* 2 d) (* 3 d)))))
             (when (and r g b) (values r g b)))))))
    (t nil)))

(defun %handler-screens (handler)
  "Return the distinct, non-NIL screen buffers owned by HANDLER (active, primary,
   and alternate). Palette changes are applied to all of them so OSC color
   redefinitions are shared across the normal and alternate screens."
  (remove-duplicates
   (remove nil (list (vt-handler-screen handler)
                     (vt-handler-primary-screen handler)
                     (vt-handler-alt-screen handler)))))

(defun %osc-set-palette-entry (handler idx r g b)
  "Set palette index IDX to R/G/B (0-255) on every buffer of HANDLER."
  (when (<= 0 idx 255)
    (dolist (sc (%handler-screens handler))
      (set-palette-entry-rgb8 sc idx r g b))))

(defun %osc-set-color-4 (handler data)
  "Handle OSC 4 data: idx;spec[;idx;spec]... -- set palette colors."
  (loop :for (idx-str spec) :on (%split-on-char data #\;) :by #'cddr
        :do (let ((idx (and idx-str (parse-integer idx-str :junk-allowed t))))
              (when (and idx spec)
                (multiple-value-bind (r g b) (%parse-osc-color spec)
                  (when r (%osc-set-palette-entry handler idx r g b)))))))

(defun %osc-reset-color-104 (handler data)
  "Handle OSC 104 data: empty -> reset the whole palette; otherwise reset the
   listed indices to their default values."
  (if (zerop (length data))
      (dolist (sc (%handler-screens handler)) (reset-palette sc))
      (let ((def (make-default-palette)))
        (dolist (idx-str (%split-on-char data #\;))
          (let ((idx (parse-integer idx-str :junk-allowed t)))
            (when (and idx (<= 0 idx 255))
              (multiple-value-bind (r g b) (lexter/manifests:read-palette-texel def idx)
                (dolist (sc (%handler-screens handler))
                  (set-palette-entry sc idx r g b)))))))))

(defun %osc-set-default-color (handler data palette-index)
  "Handle OSC 10/11 (default fg/bg): set PALETTE-INDEX from the first spec in
   DATA. This is an approximation -- Lexter has no separate default-fg/bg color,
   so OSC 10 maps to palette index 7 and OSC 11 to index 0 (the SGR 39/49
   defaults)."
  (let ((spec (first (%split-on-char data #\;))))
    (when spec
      (multiple-value-bind (r g b) (%parse-osc-color spec)
        (when r (%osc-set-palette-entry handler palette-index r g b))))))

(defun handle-osc (handler str)
  "Handle the operating-system command STR, decoded (window title and palette
   control)."
  (let* ((semi-pos (position #\; str))
         (ps (parse-integer str :end (or semi-pos (length str)) :junk-allowed t))
         (data (if semi-pos (subseq str (1+ semi-pos)) "")))
    (when ps
      (case ps
        ((0 2) ; Set window title
         (setf (vt-handler-window-title handler) data)
         (when (vt-handler-callback handler)
           (funcall (vt-handler-callback handler) :set-title data)))
        (4   (%osc-set-color-4 handler data))     ; set palette color(s)
        (104 (%osc-reset-color-104 handler data)) ; reset palette color(s)
        (10  (%osc-set-default-color handler data 7))  ; default foreground
        (11  (%osc-set-default-color handler data 0))  ; default background
        (12  nil)  ; cursor color: parsed but unsupported (no cursor-colour model)
        (otherwise
         (when (vt-handler-callback handler)
           (funcall (vt-handler-callback handler) :unknown-osc
                    (list :ps ps :data data))))))))

;;; --------------------------------------------------------------------------
;;; Reset
;;; --------------------------------------------------------------------------

(defun reset-handler (handler)
  "Reset handler to initial state."
  (let ((screen (vt-handler-screen handler)))
    ;; Reset SGR
    (%set-current-style handler (make-style))
    ;; Reset modes
    (setf (vt-handler-autowrap handler) t)
    ;; Reset mouse reporting (RIS must release any application mouse grab)
    (setf (vt-handler-mouse-tracking handler) nil
          (vt-handler-mouse-encoding handler) :x10)
    ;; Clear screen
    (erase-in-display screen 2)
    ;; Home cursor
    (set-cursor-position screen 0 0)
    ;; Reset scrolling region
    (set-scrolling-region screen 0 (1- (screen-rows screen)))
    ;; Show cursor
    (set-cursor-visible screen t)
    ;; Reset tab stops
    (setf (vt-handler-tab-stops handler) (%default-tab-stops (screen-cols screen)))
    ;; Reset parser
    (cl-vt:vt-parser-reset (vt-handler-parser handler))))


