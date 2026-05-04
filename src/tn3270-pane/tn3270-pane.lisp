;;;; TN3270 pane: a pane that connects to a 3270 host.
;;;;
;;;; This pane uses the pcf-gl/tn3270 client library and renders
;;;; the 3270 screen to the display grid.

(in-package #:pcf-gl/tn3270-pane)

;;; --------------------------------------------------------------------------
;;; 3270 color mapping
;;; --------------------------------------------------------------------------

(defparameter *3270-color-map*
  ;; Map 3270 color codes to xterm palette indices
  ;; 3270 colors: default(0), blue(#xF1), red(#xF2), pink(#xF3),
  ;;              green(#xF4), turquoise(#xF5), yellow(#xF6), white(#xF7)
  (let ((table (make-hash-table)))
    (setf (gethash #x00 table) 7    ; default -> white
          (gethash #xF1 table) 12   ; blue -> bright blue
          (gethash #xF2 table) 9    ; red -> bright red
          (gethash #xF3 table) 13   ; pink -> bright magenta
          (gethash #xF4 table) 10   ; green -> bright green
          (gethash #xF5 table) 14   ; turquoise -> bright cyan
          (gethash #xF6 table) 11   ; yellow -> bright yellow
          (gethash #xF7 table) 15)  ; white -> bright white
    table)
  "Map 3270 color codes to xterm-256 palette indices.")

(defun map-3270-color (color-code)
  "Map a 3270 color code to palette index."
  (gethash color-code *3270-color-map* 7))

;;; --------------------------------------------------------------------------
;;; 3270 key mapping
;;; --------------------------------------------------------------------------

(defparameter *3270-key-map*
  (list
   ;; Enter -> AID Enter
   (cons :enter      tacle/tn3270.lexicon:+aid-enter+)
   ;; Function keys
   (cons :f1         tacle/tn3270.lexicon:+aid-pf1+)
   (cons :f2         tacle/tn3270.lexicon:+aid-pf2+)
   (cons :f3         tacle/tn3270.lexicon:+aid-pf3+)
   (cons :f4         tacle/tn3270.lexicon:+aid-pf4+)
   (cons :f5         tacle/tn3270.lexicon:+aid-pf5+)
   (cons :f6         tacle/tn3270.lexicon:+aid-pf6+)
   (cons :f7         tacle/tn3270.lexicon:+aid-pf7+)
   (cons :f8         tacle/tn3270.lexicon:+aid-pf8+)
   (cons :f9         tacle/tn3270.lexicon:+aid-pf9+)
   (cons :f10        tacle/tn3270.lexicon:+aid-pf10+)
   (cons :f11        tacle/tn3270.lexicon:+aid-pf11+)
   ;; Note: F12 is prefix key, so use Shift+F12 for PF12 or remap
   ;; PA keys (Ctrl+Fn)
   (cons :escape     tacle/tn3270.lexicon:+aid-pa1+)
   ;; Clear
   (cons :pause      tacle/tn3270.lexicon:+aid-clear+))
  "Mapping from GLFW keys to 3270 AID codes.")

;;; --------------------------------------------------------------------------
;;; TN3270 pane class
;;; --------------------------------------------------------------------------

(defclass tn3270-pane (pcf-gl/panes:pane)
  (;; Configuration
   (host        :initarg :host
                :accessor tn3270-pane-host
                :initform "localhost"
                :type string
                :documentation "3270 host to connect to.")
   (port        :initarg :port
                :accessor tn3270-pane-port
                :initform 3270
                :type fixnum
                :documentation "Port number.")
   ;; Runtime state
   (client      :accessor tn3270-pane-client
                :initform nil
                :documentation "TN3270 client instance.")
   (initialized :accessor tn3270-pane-initialized-p
                :initform nil
                :type boolean)
   ;; Rendering
   (atlas       :accessor tn3270-pane-atlas
                :initform nil
                :documentation "Atlas reference for glyph lookup.")
   ;; Swatches: we use indices 1-8 for 3270 colors
   (swatches    :accessor tn3270-pane-swatches
                :initform (make-hash-table)
                :documentation "Cache of (fg . highlight) -> swatch-index."))
  (:documentation "A pane displaying a TN3270 session."))

;;; --------------------------------------------------------------------------
;;; Initialization
;;; --------------------------------------------------------------------------

(defmethod pcf-gl/panes:pane-initialize ((pane tn3270-pane) atlas)
  "Initialize the 3270 pane: create client, screen, and connect."
  (when (tn3270-pane-initialized-p pane)
    (return-from pcf-gl/panes:pane-initialize nil))
  (setf (tn3270-pane-atlas pane) atlas)
  (let* ((cols (pcf-gl/panes:pane-width pane))
         (rows (pcf-gl/panes:pane-height pane))
         (screen (pcf-gl/tn3270:make-tn3270-screen :cols cols :rows rows))
         (client (pcf-gl/tn3270:make-tn3270-client
                  :host (tn3270-pane-host pane)
                  :port (tn3270-pane-port pane)
                  :screen screen)))
    (setf (tn3270-pane-client pane) client)
    ;; Attempt connection
    (format t "~&Connecting to ~a:~d...~%"
            (tn3270-pane-host pane) (tn3270-pane-port pane))
    (if (pcf-gl/tn3270:client-connect client)
        (format t "~&Connected!~%")
        (format t "~&Connection failed.~%"))
    (setf (tn3270-pane-initialized-p pane) t)
    t))

;;; --------------------------------------------------------------------------
;;; Flush to display grid
;;; --------------------------------------------------------------------------

(defmethod pcf-gl/panes:pane-flush ((pane tn3270-pane) grid)
  "Render 3270 screen to the display grid."
  (let* ((client (tn3270-pane-client pane))
         (screen (when client (pcf-gl/tn3270::client-screen client)))
         (atlas (tn3270-pane-atlas pane)))
    (unless (and screen atlas)
      (return-from pcf-gl/panes:pane-flush nil))
    (let* ((cols (pcf-gl/tn3270:screen-cols screen))
           (rows (pcf-gl/tn3270:screen-rows screen))
           (buf (pcf-gl/tn3270:screen-buffer screen))
           (colors (pcf-gl/tn3270::screen-colors screen))
           (highlights (pcf-gl/tn3270::screen-highlights screen))
           (field-attrs (pcf-gl/tn3270::screen-field-attrs screen))
           (cursor-addr (pcf-gl/tn3270:screen-cursor-address screen))
           (col-offset (pcf-gl/panes:pane-col pane))
           (row-offset (pcf-gl/panes:pane-row pane)))
      ;; Render each cell
      (dotimes (r rows)
        (dotimes (c cols)
          (let* ((addr (+ (* r cols) c))
                 (char-code (aref buf addr))
                 (color (aref colors addr))
                 (highlight (aref highlights addr))
                 (fa (aref field-attrs addr))
                 ;; Map to display coordinates
                 (gc (+ c col-offset))
                 (gr (+ r row-offset))
                 ;; Get glyph index
                 (glyph-idx (or (pcf-gl/atlas:atlas-glyph-index atlas char-code)
                                (pcf-gl/atlas:atlas-glyph-index atlas 32)))
                 ;; Compute swatch
                 (fg-color (if (plusp fa)
                               7  ; field attr displays dim
                               (map-3270-color color)))
                 (bg-color 0)
                 ;; Handle reverse video highlight
                 (reverse-p (= highlight tacle/tn3270.lexicon:+highlight-reverse+))
                 (actual-fg (if reverse-p bg-color fg-color))
                 (actual-bg (if reverse-p fg-color bg-color))
                 (swatch (get-or-create-swatch grid actual-bg actual-fg)))
            (pcf-gl/grid:set-simple-cell grid gc gr glyph-idx swatch))))
      ;; Render cursor (block cursor on current position)
      (let* ((cursor-row (floor cursor-addr cols))
             (cursor-col (mod cursor-addr cols))
             (gc (+ cursor-col col-offset))
             (gr (+ cursor-row row-offset)))
        (when (and pcf-gl/panes::*cursor-blink-on*
                   (< gc (+ col-offset cols))
                   (< gr (+ row-offset rows)))
          ;; Use cursor glyph (filled block)
          (let ((cursor-glyph (pcf-gl/atlas:atlas-glyph-index atlas :cursor-block)))
            (when cursor-glyph
              (pcf-gl/grid:set-simple-cell grid gc gr cursor-glyph 0)))))
      ;; Mark screen as clean
      (setf (pcf-gl/tn3270::screen-dirty screen) nil))))

(defvar *swatch-cache* (make-hash-table :test 'equal)
  "Cache of (bg . fg) -> swatch-index.")

(defvar *next-swatch-index* 1
  "Next available swatch index (0 is reserved for default).")

(defun get-or-create-swatch (grid bg fg)
  "Get or create a swatch for the given BG/FG colors.
   BG and FG are xterm-256 palette indices."
  (let ((key (cons bg fg)))
    (or (gethash key *swatch-cache*)
        (when (< *next-swatch-index* 256)  ; max swatches
          (let ((idx *next-swatch-index*))
            ;; set-swatch: idx, slot0=bg, slot1=fg, slot2=overlay1, slot3=overlay2
            (pcf-gl/grid:set-swatch grid idx bg fg fg bg)
            (setf (gethash key *swatch-cache*) idx)
            (incf *next-swatch-index*)
            idx))
        ;; Fallback to 0 if we run out of swatches
        0)))

;;; --------------------------------------------------------------------------
;;; Key handling
;;; --------------------------------------------------------------------------

(defmethod pcf-gl/panes:pane-handle-key ((pane tn3270-pane) key scancode action mods)
  "Handle key events for 3270 emulation."
  (declare (ignore scancode))
  (let ((client (tn3270-pane-client pane)))
    (unless (and client (pcf-gl/tn3270:client-connected-p client))
      (return-from pcf-gl/panes:pane-handle-key nil))
    (when (member action '(:press :repeat))
      (let ((screen (pcf-gl/tn3270::client-screen client)))
        ;; Check for AID keys
        (let ((aid-entry (assoc key *3270-key-map*)))
          (when aid-entry
            (pcf-gl/tn3270:client-send-aid client (cdr aid-entry))
            (return-from pcf-gl/panes:pane-handle-key t)))
        ;; Cursor movement
        (let* ((cursor-addr (pcf-gl/tn3270:screen-cursor-address screen))
               (cols (pcf-gl/tn3270:screen-cols screen))
               (size (pcf-gl/tn3270::screen-size screen)))
          (case key
            (:up
             (pcf-gl/tn3270::screen-set-cursor
              screen (mod (- cursor-addr cols) size))
             (setf (pcf-gl/tn3270::screen-dirty screen) t)
             t)
            (:down
             (pcf-gl/tn3270::screen-set-cursor
              screen (mod (+ cursor-addr cols) size))
             (setf (pcf-gl/tn3270::screen-dirty screen) t)
             t)
            (:left
             (pcf-gl/tn3270::screen-set-cursor
              screen (mod (1- cursor-addr) size))
             (setf (pcf-gl/tn3270::screen-dirty screen) t)
             t)
            (:right
             (pcf-gl/tn3270::screen-set-cursor
              screen (mod (1+ cursor-addr) size))
             (setf (pcf-gl/tn3270::screen-dirty screen) t)
             t)
            (:home
             (pcf-gl/tn3270::screen-set-cursor screen 0)
             (setf (pcf-gl/tn3270::screen-dirty screen) t)
             t)
            (:tab
             ;; Tab to next unprotected field
             (tab-to-next-field screen)
             t)
            (:backspace
             ;; Move back and clear
             (let ((new-addr (mod (1- cursor-addr) size)))
               (multiple-value-bind (fa-addr fa)
                   (pcf-gl/tn3270:screen-field-at screen new-addr)
                 (unless (and fa-addr (pcf-gl/tn3270:field-protected-p fa))
                   (setf (aref (pcf-gl/tn3270:screen-buffer screen) new-addr) 32)
                   (pcf-gl/tn3270::screen-set-cursor screen new-addr)
                   (when fa-addr
                     (pcf-gl/tn3270::set-field-modified screen fa-addr))
                   (setf (pcf-gl/tn3270::screen-dirty screen) t))))
             t)
            (:delete
             ;; Clear current position
             (multiple-value-bind (fa-addr fa)
                 (pcf-gl/tn3270:screen-field-at screen cursor-addr)
               (unless (and fa-addr (pcf-gl/tn3270:field-protected-p fa))
                 (setf (aref (pcf-gl/tn3270:screen-buffer screen) cursor-addr) 32)
                 (when fa-addr
                   (pcf-gl/tn3270::set-field-modified screen fa-addr))
                 (setf (pcf-gl/tn3270::screen-dirty screen) t)))
             t)
            (otherwise nil)))))))

(defun tab-to-next-field (screen)
  "Move cursor to the next unprotected field."
  (let* ((size (pcf-gl/tn3270::screen-size screen))
         (start (pcf-gl/tn3270:screen-cursor-address screen))
         (attrs (pcf-gl/tn3270::screen-field-attrs screen)))
    (loop :for i :from 1 :below size
          :for addr = (mod (+ start i) size)
          :for fa = (aref attrs addr)
          :when (and (plusp fa) (not (pcf-gl/tn3270:field-protected-p fa)))
          :do (pcf-gl/tn3270::screen-set-cursor screen (mod (1+ addr) size))
              (setf (pcf-gl/tn3270::screen-dirty screen) t)
              (return t))))

;;; --------------------------------------------------------------------------
;;; Character input
;;; --------------------------------------------------------------------------

(defmethod pcf-gl/panes:pane-handle-char ((pane tn3270-pane) codepoint)
  "Handle character input for 3270 data entry."
  (let ((client (tn3270-pane-client pane)))
    (unless (and client (pcf-gl/tn3270:client-connected-p client))
      (return-from pcf-gl/panes:pane-handle-char nil))
    (let* ((screen (pcf-gl/tn3270::client-screen client))
           (addr (pcf-gl/tn3270:screen-cursor-address screen))
           (char-code (if (characterp codepoint) (char-code codepoint) codepoint)))
      ;; Only type in unprotected fields
      (multiple-value-bind (fa-addr fa)
          (pcf-gl/tn3270:screen-field-at screen addr)
        (when (and fa-addr (pcf-gl/tn3270:field-protected-p fa))
          ;; Protected field - beep or skip
          (return-from pcf-gl/panes:pane-handle-char nil))
        ;; Insert character
        (pcf-gl/tn3270:screen-put-char screen addr char-code)
        ;; Mark field modified
        (when fa-addr
          (pcf-gl/tn3270::set-field-modified screen fa-addr))
        t))))

;;; --------------------------------------------------------------------------
;;; I/O processing
;;; --------------------------------------------------------------------------

(defmethod pcf-gl/panes:pane-process-output ((pane tn3270-pane))
  "Poll the 3270 client for incoming data."
  (let ((client (tn3270-pane-client pane)))
    (unless client
      (return-from pcf-gl/panes:pane-process-output nil))
    (let ((result (pcf-gl/tn3270:client-poll client :timeout 0)))
      (eq result :data))))

;;; --------------------------------------------------------------------------
;;; Dirty check
;;; --------------------------------------------------------------------------

(defmethod pcf-gl/panes:pane-dirty-p ((pane tn3270-pane))
  "Check if the 3270 screen needs re-rendering."
  (let ((client (tn3270-pane-client pane)))
    (when client
      (let ((screen (pcf-gl/tn3270::client-screen client)))
        (and screen (pcf-gl/tn3270::screen-dirty screen))))))

;;; --------------------------------------------------------------------------
;;; Cleanup
;;; --------------------------------------------------------------------------

(defmethod pcf-gl/panes:pane-destroy ((pane tn3270-pane))
  "Disconnect from the 3270 host."
  (let ((client (tn3270-pane-client pane)))
    (when client
      (pcf-gl/tn3270:client-disconnect client))))

;;; --------------------------------------------------------------------------
;;; Utility
;;; --------------------------------------------------------------------------

(defun tn3270-pane-connected-p (pane)
  "Return T if the pane is connected to a 3270 host."
  (let ((client (tn3270-pane-client pane)))
    (and client (pcf-gl/tn3270:client-connected-p client))))

(defmethod pcf-gl/panes:pane-alive-p ((pane tn3270-pane))
  "Return T if the 3270 session is connected."
  (tn3270-pane-connected-p pane))
