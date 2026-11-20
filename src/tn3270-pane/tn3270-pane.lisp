;;;; TN3270 pane: a pane that connects to a 3270 host.
;;;;
;;;; This pane uses the lexter/tn3270 client library, whose screen is a Lexter
;;;; screen with the 3270 field state beside it, and builds that screen into
;;;; the composed grid as every terminal pane does (LEXTER-D128, LEXTER-D124).

(in-package #:lexter/tn3270-pane)

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

(defclass tn3270-pane (lexter/panes:pane)
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
   (swatches    :accessor tn3270-pane-swatches
                :initform nil
                :documentation "The pane's swatch table, from the store of the
                 compositor that draws it, made when the pane is initialized and
                 released when it is destroyed
                 (LEXTER-DRAFT-cell-model-revision-D24)."))
  (:documentation "A pane displaying a TN3270 session."))

;;; --------------------------------------------------------------------------
;;; Initialization
;;; --------------------------------------------------------------------------

(defmethod lexter/panes:pane-initialize ((pane tn3270-pane) atlas)
  "Initialize the 3270 pane: create client, screen, and connect."
  (when (tn3270-pane-initialized-p pane)
    (return-from lexter/panes:pane-initialize nil))
  (setf (tn3270-pane-atlas pane) atlas)
  ;; A table of the pane's own, in place of a global cache (LEXTER-D77)
  (setf (tn3270-pane-swatches pane)
        (lexter/swatches:make-swatch-table
         (or (lexter/panes:swatch-store-of pane)
             (lexter/swatches:make-swatch-store))))
  (let* ((cols (lexter/panes:pane-width pane))
         (rows (lexter/panes:pane-height pane))
         (screen (lexter/tn3270:make-tn3270-screen :cols cols :rows rows
                                                   :swatches (tn3270-pane-swatches pane)))
         (client (lexter/tn3270:make-tn3270-client
                  :host (tn3270-pane-host pane)
                  :port (tn3270-pane-port pane)
                  :screen screen)))
    (setf (tn3270-pane-client pane) client)
    ;; Attempt connection
    (format t "~&Connecting to ~a:~d...~%"
            (tn3270-pane-host pane) (tn3270-pane-port pane))
    (if (lexter/tn3270:client-connect client)
        (format t "~&Connected!~%")
        (format t "~&Connection failed.~%"))
    (setf (tn3270-pane-initialized-p pane) t)
    t))

;;; --------------------------------------------------------------------------
;;; Flush to display grid
;;; --------------------------------------------------------------------------

(defun tn3270-pane-screen (pane)
  "The pane's 3270 screen, or NIL before it is initialized."
  (let ((client (tn3270-pane-client pane)))
    (and client (lexter/tn3270::client-screen client))))

(defmethod lexter/panes:pane-flush ((pane tn3270-pane) grid)
  "Build the 3270 screen's dirty rows into the grid, as every terminal pane's
   are built, with its cursor (LEXTER-D124)."
  (let ((screen (tn3270-pane-screen pane))
        (atlas (tn3270-pane-atlas pane)))
    (when (and screen atlas)
      (lexter/model:flush-to-display
       (lexter/tn3270:screen-model screen) grid
       :atlas atlas
       ;; Its colours are the default palette's, slot 0 (LEXTER-D92)
       :palette-slot 0
       :col-offset (lexter/panes:pane-col pane)
       :row-offset (lexter/panes:pane-row pane)
       :cursor-blink-on lexter/panes::*cursor-blink-on*))))

;;; --------------------------------------------------------------------------
;;; Key handling
;;; --------------------------------------------------------------------------

(defmethod lexter/panes:pane-handle-key ((pane tn3270-pane) key scancode action mods)
  "Handle key events for 3270 emulation."
  (declare (ignore scancode))
  (let ((client (tn3270-pane-client pane)))
    (unless (and client (lexter/tn3270:client-connected-p client))
      (return-from lexter/panes:pane-handle-key nil))
    (when (member action '(:press :repeat))
      (let ((screen (lexter/tn3270::client-screen client)))
        ;; Check for AID keys
        (let ((aid-entry (assoc key *3270-key-map*)))
          (when aid-entry
            (lexter/tn3270:client-send-aid client (cdr aid-entry))
            (return-from lexter/panes:pane-handle-key t)))
        ;; Cursor movement
        (let* ((cursor-addr (lexter/tn3270:screen-cursor-address screen))
               (cols (lexter/tn3270:screen-cols screen))
               (size (lexter/tn3270::screen-size screen)))
          (case key
            (:up
             (lexter/tn3270::screen-set-cursor
              screen (mod (- cursor-addr cols) size))
             t)
            (:down
             (lexter/tn3270::screen-set-cursor
              screen (mod (+ cursor-addr cols) size))
             t)
            (:left
             (lexter/tn3270::screen-set-cursor
              screen (mod (1- cursor-addr) size))
             t)
            (:right
             (lexter/tn3270::screen-set-cursor
              screen (mod (1+ cursor-addr) size))
             t)
            (:home
             (lexter/tn3270::screen-set-cursor screen 0)
             t)
            (:tab
             ;; Tab to next unprotected field
             (tab-to-next-field screen)
             t)
            (:backspace
             ;; Move back and clear
             (let ((new-addr (mod (1- cursor-addr) size)))
               (multiple-value-bind (fa-addr fa)
                   (lexter/tn3270:screen-field-at screen new-addr)
                 (unless (and fa-addr (lexter/tn3270:field-protected-p fa))
                   (lexter/tn3270:screen-erase-char screen new-addr)
                   (lexter/tn3270::screen-set-cursor screen new-addr)
                   (when fa-addr
                     (lexter/tn3270::set-field-modified screen fa-addr)))))
             t)
            (:delete
             ;; Clear current position
             (multiple-value-bind (fa-addr fa)
                 (lexter/tn3270:screen-field-at screen cursor-addr)
               (unless (and fa-addr (lexter/tn3270:field-protected-p fa))
                 (lexter/tn3270:screen-erase-char screen cursor-addr)
                 (when fa-addr
                   (lexter/tn3270::set-field-modified screen fa-addr))))
             t)
            (otherwise nil)))))))

(defun tab-to-next-field (screen)
  "Move cursor to the next unprotected field."
  (let* ((size (lexter/tn3270::screen-size screen))
         (start (lexter/tn3270:screen-cursor-address screen))
         (attrs (lexter/tn3270::screen-field-attrs screen)))
    (loop :for i :from 1 :below size
          :for addr = (mod (+ start i) size)
          :for fa = (aref attrs addr)
          :when (and (plusp fa) (not (lexter/tn3270:field-protected-p fa)))
          :do (lexter/tn3270::screen-set-cursor screen (mod (1+ addr) size))
              (return t))))

;;; --------------------------------------------------------------------------
;;; Character input
;;; --------------------------------------------------------------------------

(defmethod lexter/panes:pane-handle-char ((pane tn3270-pane) codepoint)
  "Handle character input for 3270 data entry."
  (let ((client (tn3270-pane-client pane)))
    (unless (and client (lexter/tn3270:client-connected-p client))
      (return-from lexter/panes:pane-handle-char nil))
    (let* ((screen (lexter/tn3270::client-screen client))
           (addr (lexter/tn3270:screen-cursor-address screen))
           (char-code (if (characterp codepoint) (char-code codepoint) codepoint)))
      ;; Only type in unprotected fields
      (multiple-value-bind (fa-addr fa)
          (lexter/tn3270:screen-field-at screen addr)
        (when (and fa-addr (lexter/tn3270:field-protected-p fa))
          ;; Protected field - beep or skip
          (return-from lexter/panes:pane-handle-char nil))
        ;; Insert character
        (lexter/tn3270:screen-put-char screen addr char-code)
        ;; Mark field modified
        (when fa-addr
          (lexter/tn3270::set-field-modified screen fa-addr))
        t))))

;;; --------------------------------------------------------------------------
;;; I/O processing
;;; --------------------------------------------------------------------------

(defmethod lexter/panes:pane-process-output ((pane tn3270-pane))
  "Poll the 3270 client for incoming data."
  (let ((client (tn3270-pane-client pane)))
    (unless client
      (return-from lexter/panes:pane-process-output nil))
    (let ((result (lexter/tn3270:client-poll client :timeout 0)))
      (eq result :data))))

;;; --------------------------------------------------------------------------
;;; Dirty check
;;; --------------------------------------------------------------------------

(defmethod lexter/panes:pane-dirty-p ((pane tn3270-pane))
  "Check if the 3270 screen needs re-rendering."
  (let ((screen (tn3270-pane-screen pane)))
    (and screen (lexter/tn3270:screen-dirty screen))))

(defmethod lexter/panes:pane-mark-dirty ((pane tn3270-pane))
  "Mark every row of the 3270 screen to be built again, as switching to the
   pane's workspace asks (LEXTER-D71)."
  (let ((screen (tn3270-pane-screen pane)))
    (when screen
      (lexter/model:mark-screen-dirty (lexter/tn3270:screen-model screen)))))

;;; --------------------------------------------------------------------------
;;; Cleanup
;;; --------------------------------------------------------------------------

(defmethod lexter/panes:pane-destroy ((pane tn3270-pane))
  "Disconnect from the 3270 host, and return the pane's swatch ranges."
  (let ((client (tn3270-pane-client pane)))
    (when client
      (lexter/tn3270:client-disconnect client)))
  (when (tn3270-pane-swatches pane)
    (lexter/swatches:release-swatch-table (tn3270-pane-swatches pane))))

;;; --------------------------------------------------------------------------
;;; Utility
;;; --------------------------------------------------------------------------

(defun tn3270-pane-connected-p (pane)
  "Return T if the pane is connected to a 3270 host."
  (let ((client (tn3270-pane-client pane)))
    (and client (lexter/tn3270:client-connected-p client))))

(defmethod lexter/panes:pane-alive-p ((pane tn3270-pane))
  "Return T if the 3270 session is connected."
  (tn3270-pane-connected-p pane))
