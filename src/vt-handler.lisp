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
  ;; Current SGR state (for new characters)
  (current-fg      7  :type (unsigned-byte 8))   ; default white
  (current-bg      0  :type (unsigned-byte 8))   ; default black
  (current-attrs   0  :type (unsigned-byte 32))
  ;; Saved cursor state (DECSC/DECRC -- ESC 7 / ESC 8)
  (saved-col       0  :type fixnum)
  (saved-row       0  :type fixnum)
  (saved-fg        7  :type (unsigned-byte 8))
  (saved-bg        0  :type (unsigned-byte 8))
  (saved-attrs     0  :type (unsigned-byte 32))
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
  (alt-saved-fg    7  :type (unsigned-byte 8))
  (alt-saved-bg    0  :type (unsigned-byte 8))
  (alt-saved-attrs 0  :type (unsigned-byte 32))
  ;; Autowrap mode
  (autowrap        t   :type boolean)
  ;; Application callback for actions we can't handle
  (callback        nil :type (or null function))
  ;; Tab stops (bit vector, 1 = tab stop at that column)
  (tab-stops       nil :type (or null simple-bit-vector))
  ;; OSC string accumulator
  (osc-string      ""  :type string)
  ;; Window title (set via OSC)
  (window-title    ""  :type string)
  ;; UTF-8 decoding state
  (utf8-bytes-needed 0 :type (integer 0 3))      ; remaining bytes expected
  (utf8-codepoint    0 :type (unsigned-byte 32)) ; accumulated codepoint
  ;; Encoding mode: :utf8 (default) or :cp437 (for BBS/DOS compatibility)
  (encoding        :utf8 :type keyword)
  ;; Bold-as-bright: when T, bold attribute promotes fg colors 0-7 to 8-15
  ;; Classic BBS behavior (ESC[1;31m = bright red, not bold dark red)
  (bold-as-bright  nil :type boolean)
  ;; CP437 translation table (nil = use default from lexter/telnet)
  (cp437-table     nil :type (or null (simple-array (unsigned-byte 32) (256))))
  )

;;; --------------------------------------------------------------------------
;;; Constructor
;;; --------------------------------------------------------------------------

(defun make-vt-handler (screen atlas &key callback (encoding :utf8) bold-as-bright)
  "Create a VT handler for SCREEN using ATLAS for codepoint mapping.
   CALLBACK is called for unhandled sequences: (funcall callback :type data).
   ENCODING is :utf8 (default) or :cp437 (for BBS/DOS compatibility).
   BOLD-AS-BRIGHT when T promotes fg colors 0-7 to 8-15 when bold is set."
  (let* ((cols (screen-cols screen))
         (tab-stops (make-array cols :element-type 'bit :initial-element 0))
         (handler (%make-vt-handler :screen screen
                                    :primary-screen screen
                                    :atlas atlas
                                    :callback callback
                                    :tab-stops tab-stops
                                    :encoding encoding
                                    :bold-as-bright bold-as-bright)))
    ;; Set the blank glyph on the screen (atlas index for space character)
    ;; and fill the screen with blank glyphs
    (when atlas
      (let ((space-glyph (lexter/atlas:atlas-glyph-index atlas 32)))
        (when space-glyph
          (setf (screen-blank-glyph screen) space-glyph)
          ;; Fill screen with proper blank glyph (not codepoint 32)
          (fill (lexter/model::screen-glyphs screen) space-glyph))))
    ;; Set default tab stops every 8 columns
    (loop :for i :from 0 :below cols :by 8
          :do (setf (sbit tab-stops i) 1))
    ;; Create parser with our dispatch function
    (setf (vt-handler-parser handler)
          (cl-vt:make-vt-parser (lambda (parser action byte)
                                  (dispatch-action handler parser action byte))
                                handler))
    handler))

;;; --------------------------------------------------------------------------
;;; Main entry point
;;; --------------------------------------------------------------------------

(defun process-output (handler data &key (start 0) end)
  "Process terminal output DATA through the handler.
   DATA should be a (vector (unsigned-byte 8))."
  (cl-vt:vt-parse (vt-handler-parser handler) data start end))

;;; --------------------------------------------------------------------------
;;; Action dispatch
;;; --------------------------------------------------------------------------

(defun dispatch-action (handler parser action byte)
  "Dispatch a parser action to the appropriate handler."
  (declare (ignore parser))
  (when *debug-vt*
    (format t "~&[DISPATCH] action=~S byte=~D (#x~X)~%" action byte byte))
  (case action
    (:print       (handle-print handler byte))
    (:execute     (handle-execute handler byte))
    (:csi-dispatch (handle-csi-with-final handler byte))
    (:esc-dispatch (handle-esc handler byte))
    (:osc-start   (setf (vt-handler-osc-string handler) ""))
    (:osc-put     (setf (vt-handler-osc-string handler)
                        (concatenate 'string (vt-handler-osc-string handler)
                                     (string (code-char byte)))))
    (:osc-end     (handle-osc handler))
    (otherwise    nil)))

;;; --------------------------------------------------------------------------
;;; Print handler with UTF-8 decoding
;;; --------------------------------------------------------------------------

(defun %print-codepoint (handler codepoint)
  "Actually print a fully-decoded Unicode codepoint to the screen."
  (let* ((screen (vt-handler-screen handler))
         (atlas (vt-handler-atlas handler))
         (cols (screen-cols screen))
         (col (cursor-col screen))
         (row (cursor-row screen))
         ;; Look up glyph index from codepoint
         (glyph-idx (when atlas
                      (lexter/atlas:atlas-glyph-index atlas codepoint))))
    (when *debug-vt*
      (format t "~&[PRINT] codepoint=~D (#x~X) glyph-idx=~S~%" 
              codepoint codepoint glyph-idx))
    ;; Only print if we have a valid glyph
    (unless glyph-idx
      (when *debug-vt*
        (format t "~&[PRINT] SKIPPED (no glyph for U+~4,'0X)~%" codepoint))
      (return-from %print-codepoint))
    ;; Calculate effective foreground color
    ;; Bold-as-bright: promote fg 0-7 to 8-15 when bold is active
    (let* ((attrs (vt-handler-current-attrs handler))
           (base-fg (vt-handler-current-fg handler))
           (effective-fg (if (and (vt-handler-bold-as-bright handler)
                                  (logtest attrs +attr-bold+)
                                  (<= 0 base-fg 7))
                             (+ base-fg 8)
                             base-fg))
           ;; Create swatch from current colors
           (swatch-idx (intern-swatch (lexter/model::screen-swatches screen)
                                      (vt-handler-current-bg handler)
                                      effective-fg
                                      effective-fg
                                      0)))
      ;; Write character at cursor position
      (write-char-at screen col row glyph-idx
                   :swatch swatch-idx
                   :attrs attrs)
      ;; Advance cursor
      (let ((new-col (1+ col)))
        (cond
          ((< new-col cols)
           (set-cursor-position screen new-col row))
          ((vt-handler-autowrap handler)
           ;; Wrap to next line
           (if (< row (1- (screen-rows screen)))
               (set-cursor-position screen 0 (1+ row))
               (progn
                 (scroll-up screen)
                 (set-cursor-position screen 0 row))))
          (t
           ;; Stay at right edge
           (set-cursor-position screen (1- cols) row)))))))

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
  (cond
    ;; Continuation byte (10xxxxxx)?
    ((= (logand byte #xC0) #x80)
     (if (> (vt-handler-utf8-bytes-needed handler) 0)
         ;; Expected continuation: accumulate
         (progn
           (setf (vt-handler-utf8-codepoint handler)
                 (logior (ash (vt-handler-utf8-codepoint handler) 6)
                         (logand byte #x3F)))
           (decf (vt-handler-utf8-bytes-needed handler))
           ;; If complete, print it
           (when (zerop (vt-handler-utf8-bytes-needed handler))
             (%print-codepoint handler (vt-handler-utf8-codepoint handler))))
         ;; Unexpected continuation byte - skip it
         (when *debug-vt*
           (format t "~&[PRINT] Unexpected UTF-8 continuation byte~%"))))
    ;; ASCII (0xxxxxxx)?
    ((< byte #x80)
     ;; Reset any pending UTF-8 state and print directly
     (setf (vt-handler-utf8-bytes-needed handler) 0)
     (%print-codepoint handler byte))
    ;; 2-byte sequence start (110xxxxx)?
    ((= (logand byte #xE0) #xC0)
     (setf (vt-handler-utf8-codepoint handler) (logand byte #x1F)
           (vt-handler-utf8-bytes-needed handler) 1))
    ;; 3-byte sequence start (1110xxxx)?
    ((= (logand byte #xF0) #xE0)
     (setf (vt-handler-utf8-codepoint handler) (logand byte #x0F)
           (vt-handler-utf8-bytes-needed handler) 2))
    ;; 4-byte sequence start (11110xxx)?
    ((= (logand byte #xF8) #xF0)
     (setf (vt-handler-utf8-codepoint handler) (logand byte #x07)
           (vt-handler-utf8-bytes-needed handler) 3))
    ;; Invalid UTF-8 lead byte - ignore
    (t
     (when *debug-vt*
       (format t "~&[PRINT] Invalid UTF-8 lead byte: ~D~%" byte)))))

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
              (next-tab (loop :for i :from (1+ col) :below cols
                              :when (= 1 (sbit tabs i))
                              :return i
                              :finally (return (1- cols)))))
         (set-cursor-position screen next-tab (cursor-row screen))))
      ((#x0A #x0B #x0C) ; LF, VT, FF - line feed
       (let ((row (cursor-row screen)))
         (if (< row (lexter/model::screen-scroll-bottom screen))
             (set-cursor-position screen (cursor-col screen) (1+ row))
             (scroll-up screen))))
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
           (#x4A ; J - ED (Erase in Display)
            (erase-in-display screen (param 0 0)))
           (#x4B ; K - EL (Erase in Line)
            (erase-in-line screen (param 0 0)))
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
            (let ((top (1- (param 0)))
                  (bottom (1- (param 1 (screen-rows screen)))))
              (set-scrolling-region screen top bottom)
              (set-cursor-position screen 0 0)))
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
  "Handle SGR sequence for text attributes and colors."
  (let* ((parser (vt-handler-parser handler))
         (params (vt-parser-params-list parser)))
    ;; Empty SGR = reset
    (when (null params)
      (setf params '(0)))
    (let ((i 0))
      (loop :while (< i (length params))
            :for p = (or (nth i params) 0)
            :do (cond
                  ;; Reset
                  ((= p 0)
                   (setf (vt-handler-current-fg handler) 7
                         (vt-handler-current-bg handler) 0
                         (vt-handler-current-attrs handler) 0))
                  ;; Bold
                  ((= p 1)
                   (setf (vt-handler-current-attrs handler)
                         (logior (vt-handler-current-attrs handler) +attr-bold+)))
                  ;; Dim/faint (we treat as normal)
                  ((= p 2) nil)
                  ;; Italic (store in attrs, not rendered distinctly)
                  ((= p 3) nil)
                  ;; Underline
                  ((= p 4)
                   (setf (vt-handler-current-attrs handler)
                         (logior (vt-handler-current-attrs handler) +attr-underline+)))
                  ;; Blink
                  ((= p 5)
                   (setf (vt-handler-current-attrs handler)
                         (logior (vt-handler-current-attrs handler) +attr-blink+)))
                  ;; Reverse
                  ((= p 7)
                   (setf (vt-handler-current-attrs handler)
                         (logior (vt-handler-current-attrs handler) +attr-reverse+)))
                  ;; Hidden/invisible
                  ((= p 8)
                   (setf (vt-handler-current-attrs handler)
                         (logior (vt-handler-current-attrs handler) +attr-invisible+)))
                  ;; Reset bold
                  ((= p 21)
                   (setf (vt-handler-current-attrs handler)
                         (logandc2 (vt-handler-current-attrs handler) +attr-bold+)))
                  ;; Reset bold/dim
                  ((= p 22)
                   (setf (vt-handler-current-attrs handler)
                         (logandc2 (vt-handler-current-attrs handler) +attr-bold+)))
                  ;; Reset underline
                  ((= p 24)
                   (setf (vt-handler-current-attrs handler)
                         (logandc2 (vt-handler-current-attrs handler) +attr-underline+)))
                  ;; Reset blink
                  ((= p 25)
                   (setf (vt-handler-current-attrs handler)
                         (logandc2 (vt-handler-current-attrs handler) +attr-blink+)))
                  ;; Reset reverse
                  ((= p 27)
                   (setf (vt-handler-current-attrs handler)
                         (logandc2 (vt-handler-current-attrs handler) +attr-reverse+)))
                  ;; Reset hidden
                  ((= p 28)
                   (setf (vt-handler-current-attrs handler)
                         (logandc2 (vt-handler-current-attrs handler) +attr-invisible+)))
                  ;; Foreground colors 30-37
                  ((<= 30 p 37)
                   (setf (vt-handler-current-fg handler) (- p 30)))
                  ;; Extended foreground (38;5;n or 38;2;r;g;b)
                  ((= p 38)
                   (cond
                     ((and (< (1+ i) (length params))
                           (= (nth (1+ i) params) 5))
                      ;; 256-color: 38;5;n
                      (when (< (+ i 2) (length params))
                        (setf (vt-handler-current-fg handler)
                              (nth (+ i 2) params))
                        (incf i 2)))
                     ((and (< (1+ i) (length params))
                           (= (nth (1+ i) params) 2))
                      ;; 24-bit: 38;2;r;g;b - map to nearest 256 color
                      (when (< (+ i 4) (length params))
                        (let ((r (nth (+ i 2) params))
                              (g (nth (+ i 3) params))
                              (b (nth (+ i 4) params)))
                          (setf (vt-handler-current-fg handler)
                                (rgb-to-256 r g b))
                          (incf i 4))))))
                  ;; Default foreground
                  ((= p 39)
                   (setf (vt-handler-current-fg handler) 7))
                  ;; Background colors 40-47
                  ((<= 40 p 47)
                   (setf (vt-handler-current-bg handler) (- p 40)))
                  ;; Extended background (48;5;n or 48;2;r;g;b)
                  ((= p 48)
                   (cond
                     ((and (< (1+ i) (length params))
                           (= (nth (1+ i) params) 5))
                      (when (< (+ i 2) (length params))
                        (setf (vt-handler-current-bg handler)
                              (nth (+ i 2) params))
                        (incf i 2)))
                     ((and (< (1+ i) (length params))
                           (= (nth (1+ i) params) 2))
                      (when (< (+ i 4) (length params))
                        (let ((r (nth (+ i 2) params))
                              (g (nth (+ i 3) params))
                              (b (nth (+ i 4) params)))
                          (setf (vt-handler-current-bg handler)
                                (rgb-to-256 r g b))
                          (incf i 4))))))
                  ;; Default background
                  ((= p 49)
                   (setf (vt-handler-current-bg handler) 0))
                  ;; Bright foreground colors 90-97
                  ((<= 90 p 97)
                   (setf (vt-handler-current-fg handler) (+ 8 (- p 90))))
                  ;; Bright background colors 100-107
                  ((<= 100 p 107)
                   (setf (vt-handler-current-bg handler) (+ 8 (- p 100)))))
                (incf i)))))

(defun rgb-to-256 (r g b)
  "Convert 24-bit RGB to nearest xterm 256-color index."
  ;; Check if it's a grayscale value
  (if (and (= r g) (= g b))
      (cond
        ((< r 8) 16)        ; black
        ((> r 248) 231)     ; white  
        (t (+ 232 (floor (- r 8) 10)))) ; grayscale ramp
      ;; Map to 6x6x6 color cube
      (let ((ri (floor r 51))
            (gi (floor g 51))
            (bi (floor b 51)))
        (+ 16 (* 36 ri) (* 6 gi) bi))))

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
          (vt-handler-alt-saved-fg    handler) (vt-handler-current-fg handler)
          (vt-handler-alt-saved-bg    handler) (vt-handler-current-bg handler)
          (vt-handler-alt-saved-attrs handler) (vt-handler-current-attrs handler))))

(defun %restore-alt-cursor (handler)
  "Restore the cursor and SGR state saved by %SAVE-ALT-CURSOR onto the (now
   active) screen."
  (let ((screen (vt-handler-screen handler)))
    (setf (vt-handler-current-fg handler)    (vt-handler-alt-saved-fg handler)
          (vt-handler-current-bg handler)    (vt-handler-alt-saved-bg handler)
          (vt-handler-current-attrs handler) (vt-handler-alt-saved-attrs handler))
    (set-cursor-position screen
                         (min (vt-handler-alt-saved-col handler) (1- (screen-cols screen)))
                         (min (vt-handler-alt-saved-row handler) (1- (screen-rows screen))))))

(defun %ensure-alt-screen (handler)
  "Lazily create the persistent alternate buffer, matching the primary's
   dimensions and blank glyph. The alternate buffer carries no scrollback."
  (or (vt-handler-alt-screen handler)
      (let* ((primary (vt-handler-primary-screen handler))
             (alt (make-screen :cols (screen-cols primary)
                               :rows (screen-rows primary)
                               :mode (screen-mode primary))))
        (setf (screen-blank-glyph alt) (screen-blank-glyph primary))
        (fill (lexter/model::screen-glyphs alt) (screen-blank-glyph primary))
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
    (when alt (resize-screen alt new-cols new-rows))))

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
      (otherwise
       (when (vt-handler-callback handler)
         (funcall (vt-handler-callback handler) :unknown-decrst mode))))))

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
                (vt-handler-saved-fg handler) (vt-handler-current-fg handler)
                (vt-handler-saved-bg handler) (vt-handler-current-bg handler)
                (vt-handler-saved-attrs handler) (vt-handler-current-attrs handler)))
         (#x38 ; ESC 8 - DECRC (Restore Cursor)
          (set-cursor-position screen
                               (vt-handler-saved-col handler)
                               (vt-handler-saved-row handler))
          (setf (vt-handler-current-fg handler) (vt-handler-saved-fg handler)
                (vt-handler-current-bg handler) (vt-handler-saved-bg handler)
                (vt-handler-current-attrs handler) (vt-handler-saved-attrs handler)))
         (#x44 ; ESC D - IND (Index, line feed)
          (let ((row (cursor-row screen)))
            (if (< row (lexter/model::screen-scroll-bottom screen))
                (set-cursor-position screen (cursor-col screen) (1+ row))
                (scroll-up screen))))
         (#x45 ; ESC E - NEL (Next Line)
          (let ((row (cursor-row screen)))
            (if (< row (lexter/model::screen-scroll-bottom screen))
                (set-cursor-position screen 0 (1+ row))
                (progn
                  (scroll-up screen)
                  (set-cursor-position screen 0 row)))))
         (#x4D ; ESC M - RI (Reverse Index)
          (let ((row (cursor-row screen)))
            (if (> row (lexter/model::screen-scroll-top screen))
                (set-cursor-position screen (cursor-col screen) (1- row))
                (scroll-down screen))))
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
              (let ((base (* idx 4)))
                (dolist (sc (%handler-screens handler))
                  (set-palette-entry sc idx
                                     (aref def base) (aref def (+ base 1))
                                     (aref def (+ base 2)))))))))))

(defun %osc-set-default-color (handler data palette-index)
  "Handle OSC 10/11 (default fg/bg): set PALETTE-INDEX from the first spec in
   DATA. This is an approximation -- Lexter has no separate default-fg/bg color,
   so OSC 10 maps to palette index 7 and OSC 11 to index 0 (the SGR 39/49
   defaults)."
  (let ((spec (first (%split-on-char data #\;))))
    (when spec
      (multiple-value-bind (r g b) (%parse-osc-color spec)
        (when r (%osc-set-palette-entry handler palette-index r g b))))))

(defun handle-osc (handler)
  "Handle an OSC sequence (window title and palette control)."
  (let* ((str (vt-handler-osc-string handler))
         (semi-pos (position #\; str))
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
    (setf (vt-handler-current-fg handler) 7
          (vt-handler-current-bg handler) 0
          (vt-handler-current-attrs handler) 0)
    ;; Reset modes
    (setf (vt-handler-autowrap handler) t)
    ;; Clear screen
    (erase-in-display screen 2)
    ;; Home cursor
    (set-cursor-position screen 0 0)
    ;; Reset scrolling region
    (set-scrolling-region screen 0 (1- (screen-rows screen)))
    ;; Show cursor
    (set-cursor-visible screen t)
    ;; Reset tab stops
    (let ((tabs (vt-handler-tab-stops handler)))
      (fill tabs 0)
      (loop :for i :from 0 :below (length tabs) :by 8
            :do (setf (sbit tabs i) 1)))
    ;; Reset parser
    (cl-vt:vt-parser-reset (vt-handler-parser handler))))


