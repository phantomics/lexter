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
  ;; Saved cursor state (DECSC/DECRC)
  (saved-col       0  :type fixnum)
  (saved-row       0  :type fixnum)
  (saved-fg        7  :type (unsigned-byte 8))
  (saved-bg        0  :type (unsigned-byte 8))
  (saved-attrs     0  :type (unsigned-byte 32))
  ;; Alternate screen buffer (for ?1049)
  (alt-screen      nil)
  (in-alt-screen   nil :type boolean)
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
  )

;;; --------------------------------------------------------------------------
;;; Constructor
;;; --------------------------------------------------------------------------

(defun make-vt-handler (screen atlas &key callback)
  "Create a VT handler for SCREEN using ATLAS for codepoint mapping.
   CALLBACK is called for unhandled sequences: (funcall callback :type data)."
  (let* ((cols (screen-cols screen))
         (tab-stops (make-array cols :element-type 'bit :initial-element 0))
         (handler (%make-vt-handler :screen screen
                                    :atlas atlas
                                    :callback callback
                                    :tab-stops tab-stops)))
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
    (let (;; Create swatch from current colors
          (swatch-idx (intern-swatch (lexter/model::screen-swatches screen)
                                     (vt-handler-current-bg handler)
                                     (vt-handler-current-fg handler)
                                     (vt-handler-current-fg handler)
                                     0)))
      ;; Write character at cursor position
      (write-char-at screen col row glyph-idx
                   :swatch swatch-idx
                   :attrs (vt-handler-current-attrs handler))
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
  "Handle a printable byte, decoding UTF-8 sequences into codepoints."
  (when *debug-vt*
    (format t "~&[PRINT-BYTE] byte=~D (#x~X)~%" byte byte))
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
      (1049 ; Alternate screen buffer
       (unless (vt-handler-in-alt-screen handler)
         ;; Save main screen and create alternate
         (setf (vt-handler-alt-screen handler) screen
               (vt-handler-in-alt-screen handler) t)
         ;; TODO: create new screen buffer
         ))
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
      (1049 ; Restore main screen buffer
       (when (vt-handler-in-alt-screen handler)
         (setf (vt-handler-in-alt-screen handler) nil)
         ;; TODO: restore main screen
         ))
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

(defun handle-osc (handler)
  "Handle OSC sequence."
  (let* ((str (vt-handler-osc-string handler))
         (semi-pos (position #\; str)))
    (when semi-pos
      (let ((ps (parse-integer str :end semi-pos :junk-allowed t))
            (data (subseq str (1+ semi-pos))))
        (case ps
          ((0 2) ; Set window title
           (setf (vt-handler-window-title handler) data)
           (when (vt-handler-callback handler)
             (funcall (vt-handler-callback handler) :set-title data)))
          (otherwise
           (when (vt-handler-callback handler)
             (funcall (vt-handler-callback handler) :unknown-osc
                      (list :ps ps :data data)))))))))

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


