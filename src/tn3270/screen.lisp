;;;; 3270 screen model.
;;;;
;;;; The 3270 screen is a fixed-size buffer with field-based editing.
;;;; Each position can hold either:
;;;; - A field attribute byte (marks start of field, occupies one cell)
;;;; - A character within a field
;;;;
;;;; Fields have attributes: protected, numeric, intensity, MDT (modified).

(in-package #:lexter/tn3270)

;;; --------------------------------------------------------------------------
;;; Screen structure
;;; --------------------------------------------------------------------------

(defstruct (tn3270-screen (:conc-name screen-))
  "3270 screen model."
  (cols 80 :type fixnum)
  (rows 24 :type fixnum)
  ;; Character buffer: Unicode codepoints (after EBCDIC decode)
  (buffer (make-array (* 80 24) :element-type 'fixnum :initial-element 32)
          :type (simple-array fixnum (*)))
  ;; Attribute buffer: per-cell attributes (0 = no attribute at this position)
  ;; Non-zero means this cell is a field attribute byte
  (field-attrs (make-array (* 80 24) :element-type '(unsigned-byte 8) :initial-element 0)
               :type (simple-array (unsigned-byte 8) (*)))
  ;; Extended attributes per cell (color, highlight, charset)
  (colors (make-array (* 80 24) :element-type '(unsigned-byte 8) :initial-element 0)
          :type (simple-array (unsigned-byte 8) (*)))
  (highlights (make-array (* 80 24) :element-type '(unsigned-byte 8) :initial-element 0)
              :type (simple-array (unsigned-byte 8) (*)))
  ;; Current field attributes (set by SA orders, reset by field attrs)
  (current-color 0 :type (unsigned-byte 8))
  (current-highlight 0 :type (unsigned-byte 8))
  ;; Cursor position
  (cursor-address 0 :type fixnum)
  ;; Dirty tracking
  (dirty t :type boolean))

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
;;; Screen operations
;;; --------------------------------------------------------------------------

(defun screen-size (screen)
  "Return total number of buffer positions."
  (* (screen-cols screen) (screen-rows screen)))

(defun screen-clear (screen)
  "Clear the screen: all spaces, no field attributes."
  (let ((size (screen-size screen)))
    (fill (screen-buffer screen) 32 :end size)
    (fill (screen-field-attrs screen) 0 :end size)
    (fill (screen-colors screen) 0 :end size)
    (fill (screen-highlights screen) 0 :end size)
    (setf (screen-cursor-address screen) 0
          (screen-current-color screen) 0
          (screen-current-highlight screen) 0
          (screen-dirty screen) t)))

(defun screen-get-char (screen address)
  "Get character at ADDRESS."
  (declare (type tn3270-screen screen) (type fixnum address))
  (aref (screen-buffer screen) address))

(defun screen-put-char (screen address char)
  "Put CHAR (codepoint) at ADDRESS and advance cursor."
  (declare (type tn3270-screen screen) (type fixnum address char))
  (let ((size (screen-size screen)))
    (setf (aref (screen-buffer screen) address) char
          (aref (screen-colors screen) address) (screen-current-color screen)
          (aref (screen-highlights screen) address) (screen-current-highlight screen)
          (screen-dirty screen) t)
    ;; Advance cursor with wraparound
    (setf (screen-cursor-address screen)
          (mod (1+ address) size))))

(defun screen-put-field-attr (screen address attr)
  "Put a field attribute at ADDRESS. The cell displays as blank."
  (declare (type tn3270-screen screen) (type fixnum address)
           (type (unsigned-byte 8) attr))
  (setf (aref (screen-field-attrs screen) address) attr
        (aref (screen-buffer screen) address) 32  ; field attr displays as space
        ;; Reset current extended attributes
        (screen-current-color screen) 0
        (screen-current-highlight screen) 0
        (screen-dirty screen) t))

(defun screen-set-cursor (screen address)
  "Set cursor position."
  (declare (type tn3270-screen screen) (type fixnum address))
  (setf (screen-cursor-address screen) address
        (screen-dirty screen) t))

(defun screen-cursor-up (screen)
  "Move cursor up one row (with wraparound)."
  (let* ((cols (screen-cols screen))
         (size (screen-size screen))
         (addr (screen-cursor-address screen))
         (new-addr (mod (- addr cols) size)))
    (setf (screen-cursor-address screen) new-addr
          (screen-dirty screen) t)))

(defun screen-cursor-down (screen)
  "Move cursor down one row (with wraparound)."
  (let* ((cols (screen-cols screen))
         (size (screen-size screen))
         (addr (screen-cursor-address screen))
         (new-addr (mod (+ addr cols) size)))
    (setf (screen-cursor-address screen) new-addr
          (screen-dirty screen) t)))

(defun screen-cursor-left (screen)
  "Move cursor left one column (with wraparound)."
  (let* ((size (screen-size screen))
         (addr (screen-cursor-address screen))
         (new-addr (mod (1- addr) size)))
    (setf (screen-cursor-address screen) new-addr
          (screen-dirty screen) t)))

(defun screen-cursor-right (screen)
  "Move cursor right one column (with wraparound)."
  (let* ((size (screen-size screen))
         (addr (screen-cursor-address screen))
         (new-addr (mod (1+ addr) size)))
    (setf (screen-cursor-address screen) new-addr
          (screen-dirty screen) t)))

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
     ;; Background color - currently we don't track per-cell bg, but store it
     ;; TODO: add per-cell background color support if needed
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
         (buf (screen-buffer screen))
         (result (make-array 256 :element-type 'character :fill-pointer 0 :adjustable t)))
    ;; Collect characters from start to end (exclusive)
    (loop :for pos = start :then (mod (1+ pos) size)
          :until (= pos end)
          :do (vector-push-extend (code-char (aref buf pos)) result))
    result))
