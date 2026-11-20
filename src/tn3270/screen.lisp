;;;; 3270 screen model.
;;;;
;;;; The 3270 screen is a fixed-size buffer with field-based editing. Its
;;;; characters are held once, in a Lexter screen of its geometry, written
;;;; through the model's operations and built into the composed grid as every
;;;; terminal's is (LEXTER-D128, LEXTER-D124). Beside it the 3270 screen keeps,
;;;; for each buffer address, what the model has no place for: where field
;;;; attributes stand, with their protection, intensity, and modified-data tag,
;;;; and each cell's extended colour and highlight.
;;;;
;;;; A cell's style is made from its field's intensity and its own extended
;;;; attributes: a non-display field is invisible, an intensified one bold, and
;;;; the highlights reverse, underscore, and blink are those attributes of a
;;;; style. The styles of every cell are made again after each change to the
;;;; screen (SCREEN-RESTYLE), so that a change to a field attribute restyles
;;;; the cells of its field. A field attribute's position is a blank cell.
;;;; Every buffer address is one cell: the data stream decides widths
;;;; (LEXTER-D117).

(in-package #:lexter/tn3270)

;;; --------------------------------------------------------------------------
;;; 3270 colours
;;; --------------------------------------------------------------------------

(defparameter *3270-color-map*
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
;;; Screen structure
;;; --------------------------------------------------------------------------

(defstruct (tn3270-screen (:conc-name screen-) (:constructor %make-tn3270-screen))
  "3270 screen model: a Lexter screen, and the field state beside it."
  (cols 80 :type fixnum)
  (rows 24 :type fixnum)
  ;; The characters, in a Lexter screen of the same geometry
  (model nil)
  ;; Field attribute at each address (0 = none; non-zero marks a field start)
  (field-attrs (make-array 0 :element-type '(unsigned-byte 8))
               :type (simple-array (unsigned-byte 8) (*)))
  ;; Extended attributes per cell (color, highlight)
  (colors (make-array 0 :element-type '(unsigned-byte 8))
          :type (simple-array (unsigned-byte 8) (*)))
  (highlights (make-array 0 :element-type '(unsigned-byte 8))
              :type (simple-array (unsigned-byte 8) (*)))
  ;; Current field attributes (set by SA orders, reset by field attrs)
  (current-color 0 :type (unsigned-byte 8))
  (current-highlight 0 :type (unsigned-byte 8))
  ;; Buffer (write) address: the host's paint pointer while a Write stream is
  ;; processed. Distinct from the cursor, the Lexter screen's, which only IC
  ;; and local key handling move.
  (buffer-address 0 :type fixnum)
  ;; Style ids by (intensity, colour, highlight), in the model's style table
  (style-ids (make-hash-table) :type hash-table))

(defun make-tn3270-screen (&key (cols 80) (rows 24) swatches)
  "Make a 3270 screen of COLS by ROWS, every position a space with no field
   attribute, whose Lexter screen takes its swatches from SWATCHES, a swatch
   table, or from a table of its own."
  (let* ((size (* cols rows))
         (screen (%make-tn3270-screen
                  :cols cols :rows rows
                  :model (lexter/model:make-screen :cols cols :rows rows :mode :3270
                                                   :scrollback-enabled nil
                                                   :cursor-blink t
                                                   :swatches swatches)
                  :field-attrs (make-array size :element-type '(unsigned-byte 8)
                                                :initial-element 0)
                  :colors (make-array size :element-type '(unsigned-byte 8)
                                           :initial-element 0)
                  :highlights (make-array size :element-type '(unsigned-byte 8)
                                               :initial-element 0))))
    (screen-clear screen)
    screen))

;;; --------------------------------------------------------------------------
;;; Address conversion
;;; --------------------------------------------------------------------------

(declaim (inline address-to-row address-to-col row-col-to-address))

(defun address-to-row (screen address)
  "Convert buffer address to row (0-indexed)."
  (declare (type tn3270-screen screen) (type fixnum address))
  (floor address (screen-cols screen)))

(defun address-to-col (screen address)
  "Convert buffer address to column (0-indexed)."
  (declare (type tn3270-screen screen) (type fixnum address))
  (mod address (screen-cols screen)))

(defun row-col-to-address (screen row col)
  "Convert row/col to buffer address."
  (declare (type tn3270-screen screen) (type fixnum row col))
  (+ (* row (screen-cols screen)) col))

;;; --------------------------------------------------------------------------
;;; Styles
;;; --------------------------------------------------------------------------

(defun %style-id (screen intensity color highlight)
  "The id of the style of a cell whose field has INTENSITY, the field
   attribute's bits #x0C, and which has the extended COLOR and HIGHLIGHT."
  (let ((key (logior (ash intensity 16) (ash color 8) highlight)))
    (or (gethash key (screen-style-ids screen))
        (setf (gethash key (screen-style-ids screen))
              (lexter/model:intern-style
               (lexter/model:screen-styles (screen-model screen))
               (lexter/model:make-style
                :foreground (lexter/model:palette-colour (map-3270-color color))
                :bold (= intensity +fa-intensity-high+)
                :invisible (= intensity +fa-intensity-invisible+)
                :reverse (= highlight +highlight-reverse+)
                :underline (= highlight +highlight-underscore+)
                :blink (= highlight +highlight-blink+)))))))

(defun screen-restyle (screen)
  "Give every cell the style its field and extended attributes make: a field
   attribute's position the plain style, and every other cell its own colour
   and highlight in the intensity of the field that governs it, the nearest
   field attribute before it, wrapping round; an unformatted screen has none.
   Only cells whose style changes are marked dirty."
  (let* ((size (screen-size screen))
         (attrs (screen-field-attrs screen))
         (model (screen-model screen))
         (cols (screen-cols screen))
         ;; The field that governs address 0 begins at the last attribute
         (fa (loop :for a :from (1- size) :downto 0
                   :when (plusp (aref attrs a)) :return (aref attrs a))))
    (dotimes (addr size)
      (let ((style (if (plusp (aref attrs addr))
                       (progn (setf fa (aref attrs addr))
                              (%style-id screen 0 0 0))
                       (%style-id screen (if fa (logand fa #x0C) 0)
                                  (aref (screen-colors screen) addr)
                                  (aref (screen-highlights screen) addr)))))
        (lexter/model:set-cell-style model (mod addr cols) (floor addr cols) style)))))

;;; --------------------------------------------------------------------------
;;; Screen operations
;;; --------------------------------------------------------------------------

(defun screen-size (screen)
  "Return total number of buffer positions."
  (* (screen-cols screen) (screen-rows screen)))

(defun %write (screen address codepoint)
  "Write CODEPOINT at ADDRESS of the Lexter screen, one cell wide, in the style
   the cell has until it is restyled."
  (let* ((model (screen-model screen))
         (col (address-to-col screen address))
         (row (address-to-row screen address)))
    (lexter/model:write-char-at model col row codepoint
                                :style (lexter/model:cell-style model col row))))

(defun screen-clear (screen)
  "Clear the screen: all spaces, no field attributes, the cursor at 0."
  (let ((size (screen-size screen)))
    (fill (screen-field-attrs screen) 0)
    (fill (screen-colors screen) 0)
    (fill (screen-highlights screen) 0)
    (dotimes (addr size)
      (%write screen addr 32))
    (setf (screen-buffer-address screen) 0
          (screen-current-color screen) 0
          (screen-current-highlight screen) 0)
    (screen-set-cursor screen 0)
    (screen-restyle screen)))

(defun screen-get-char (screen address)
  "The codepoint at ADDRESS."
  (declare (type tn3270-screen screen) (type fixnum address))
  (lexter/model:cell-content (screen-model screen)
                             (address-to-col screen address)
                             (address-to-row screen address)))

(defun screen-cursor-address (screen)
  "The address of the user cursor, where the operator is typing."
  (let ((model (screen-model screen)))
    (row-col-to-address screen (lexter/model:cursor-row model) (lexter/model:cursor-col model))))

(defun screen-dirty (screen)
  "True when the screen has changed since it was last built into the grid."
  (lexter/model:any-row-dirty-p (screen-model screen)))

(defun screen-write-cell (screen address char)
  "Write CHAR (codepoint) at ADDRESS with the current extended attributes,
   without moving either the buffer address or the user cursor."
  (declare (type tn3270-screen screen) (type fixnum address char))
  (setf (aref (screen-colors screen) address) (screen-current-color screen)
        (aref (screen-highlights screen) address) (screen-current-highlight screen))
  (%write screen address char))

(defun screen-put-char (screen address char)
  "Put CHAR (codepoint) at ADDRESS and advance the cursor.
   Used by the local typing path (operator input), where the user cursor
   should follow the character just entered. The host paint path uses
   SCREEN-PUT-CHAR-BUFFER instead, which advances the buffer address."
  (declare (type tn3270-screen screen) (type fixnum address char))
  (screen-write-cell screen address char)
  (screen-set-cursor screen (mod (1+ address) (screen-size screen)))
  (screen-restyle screen))

(defun screen-erase-char (screen address)
  "Make ADDRESS a space, keeping its extended attributes."
  (%write screen address 32))

(defun screen-set-buffer-address (screen address)
  "Set the host paint (buffer) address. Does not touch the user cursor."
  (declare (type tn3270-screen screen) (type fixnum address))
  (setf (screen-buffer-address screen) address))

(defun screen-put-char-buffer (screen char)
  "Write CHAR (codepoint) at the current buffer address and advance the buffer
   address with wraparound. This is the host paint path: it never moves the
   user cursor (only the IC order does that)."
  (declare (type tn3270-screen screen) (type fixnum char))
  (let ((address (screen-buffer-address screen)))
    (screen-write-cell screen address char)
    (setf (screen-buffer-address screen)
          (mod (1+ address) (screen-size screen)))))

(defun screen-put-field-attr (screen address attr)
  "Put a field attribute at ADDRESS. The cell displays as blank."
  (declare (type tn3270-screen screen) (type fixnum address)
           (type (unsigned-byte 8) attr))
  (setf (aref (screen-field-attrs screen) address) attr
        ;; Reset current extended attributes
        (screen-current-color screen) 0
        (screen-current-highlight screen) 0)
  (%write screen address 32))

(defun screen-set-field-attr (screen fa-address attr)
  "Change the field attribute at FA-ADDRESS to ATTR, as MF does."
  (setf (aref (screen-field-attrs screen) fa-address) attr))

(defun screen-set-cursor (screen address)
  "Set cursor position."
  (declare (type tn3270-screen screen) (type fixnum address))
  (lexter/model:set-cursor-position (screen-model screen)
                                    (address-to-col screen address)
                                    (address-to-row screen address)))

(defun screen-cursor-up (screen)
  "Move cursor up one row (with wraparound)."
  (screen-set-cursor screen (mod (- (screen-cursor-address screen) (screen-cols screen))
                                 (screen-size screen))))

(defun screen-cursor-down (screen)
  "Move cursor down one row (with wraparound)."
  (screen-set-cursor screen (mod (+ (screen-cursor-address screen) (screen-cols screen))
                                 (screen-size screen))))

(defun screen-cursor-left (screen)
  "Move cursor left one column (with wraparound)."
  (screen-set-cursor screen (mod (1- (screen-cursor-address screen)) (screen-size screen))))

(defun screen-cursor-right (screen)
  "Move cursor right one column (with wraparound)."
  (screen-set-cursor screen (mod (1+ (screen-cursor-address screen)) (screen-size screen))))

;;; --------------------------------------------------------------------------
;;; Field queries
;;; --------------------------------------------------------------------------

(defun find-field-attr-before (screen address)
  "Find the field attribute that governs ADDRESS.
   Returns the address of the field attribute, or NIL if unformatted."
  (let ((size (screen-size screen))
        (attrs (screen-field-attrs screen)))
    ;; Search backward from ADDRESS, wrapping around
    (loop :for i :from 0 :below size
          :for pos = (mod (- address i 1) size)
          :when (plusp (aref attrs pos))
          :return pos
          :finally (return nil))))

(defun screen-field-at (screen address)
  "Return field info at ADDRESS as (VALUES attr-address attr-byte).
   Returns (VALUES NIL NIL) if the screen is unformatted."
  (let ((fa-addr (find-field-attr-before screen address)))
    (if fa-addr
        (values fa-addr (aref (screen-field-attrs screen) fa-addr))
        (values nil nil))))

(defun field-protected-p (attr)
  "Return T if field attribute indicates protected field."
  (logbitp 5 attr))  ; bit 5 = protected

(defun field-numeric-p (attr)
  "Return T if field attribute indicates numeric field."
  (logbitp 4 attr))  ; bit 4 = numeric

(defun field-modified-p (screen fa-address)
  "Return T if field's MDT (modified data tag) is set."
  (logbitp 0 (aref (screen-field-attrs screen) fa-address)))

(defun set-field-modified (screen fa-address)
  "Set the MDT bit on the field at FA-ADDRESS."
  (setf (aref (screen-field-attrs screen) fa-address)
        (logior (aref (screen-field-attrs screen) fa-address) +fa-mdt+)))

;;; --------------------------------------------------------------------------
;;; Extended attributes (SA order)
;;; --------------------------------------------------------------------------

(defun screen-set-attribute (screen type value)
  "Set current extended attribute for subsequent characters.
   TYPE is the attribute type (XA-3270, XA-HIGHLIGHT, XA-COLOR, XA-BGCOLOR, XA-CHARSET).
   VALUE is the attribute value (for color, this is a 3270 color code like #xF2=red)."
  (declare (type tn3270-screen screen))
  (cond
    ((= type +xa-3270+)
     ;; Reset to field defaults (value is new FA byte)
     (setf (screen-current-color screen) 0
           (screen-current-highlight screen) 0))
    ((= type +xa-highlight+)
     (setf (screen-current-highlight screen) value))
    ((= type +xa-color+)
     ;; Foreground color - value is 3270 color code (e.g., #xF2=red, #xF4=green)
     (setf (screen-current-color screen) value))
    ((= type +xa-bgcolor+)
     ;; Background color - not kept yet
     nil)
    ((= type +xa-charset+)
     ;; Character set - currently ignored
     nil)))

;;; --------------------------------------------------------------------------
;;; Field content extraction (for read operations)
;;; --------------------------------------------------------------------------

(defun next-field-attr (screen from-address)
  "Find the next field attribute starting at FROM-ADDRESS.
   Returns address or NIL if no fields."
  (let ((size (screen-size screen))
        (attrs (screen-field-attrs screen)))
    (loop :for i :from 0 :below size
          :for pos = (mod (+ from-address i) size)
          :when (plusp (aref attrs pos))
          :return pos
          :finally (return nil))))

(defun field-contents (screen fa-address)
  "Extract the contents of the field starting at FA-ADDRESS.
   Returns a string of characters (excluding the field attribute itself)."
  (let* ((size (screen-size screen))
         (start (mod (1+ fa-address) size))  ; first data position
         (end (or (next-field-attr screen start) fa-address))
         (result (make-array 256 :element-type 'character :fill-pointer 0 :adjustable t)))
    ;; Collect characters from start to end (exclusive)
    (loop :for pos = start :then (mod (1+ pos) size)
          :until (= pos end)
          :do (vector-push-extend (code-char (screen-get-char screen pos)) result))
    result))
