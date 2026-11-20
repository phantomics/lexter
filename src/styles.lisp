(in-package #:lexter/model)

;;;; Styles
;;;;
;;;; A style holds the attributes in which a terminal wrote text, as the host
;;;; sent them: three colours, each the default, a palette index, or a 24-bit
;;;; value, and bold, the lines, reverse video, blink, and invisible as flags
;;;; (LEXTER-D118, LEXTER-D125). Each text cell names its style by a 16-bit
;;;; id, from a table that a terminal's primary and alternate screens share.
;;;; Presentation rules, such as bold-as-bright, are applied from the
;;;; terminal's settings when rows are built, never when a cell is written.

;;; --------------------------------------------------------------------------
;;; Colours
;;; --------------------------------------------------------------------------
;;;
;;; A colour is an integer: bits 24-25 say what it is, 0 the default, 1 a
;;; palette index, 2 a 24-bit value; bits 0-23 hold the index or the value.

(deftype colour () '(unsigned-byte 26))

(defconstant +default-colour+ 0
  "The default colour, as SGR 39 and 49 select it.")

(declaim (inline palette-colour rgb-colour colour-palette-index))

(defun palette-colour (index)
  "The colour of palette entry INDEX, 0-255."
  (logior #x1000000 index))

(defun rgb-colour (red green blue)
  "The 24-bit colour RED, GREEN, BLUE, each 0-255."
  (logior #x2000000 (ash red 16) (ash green 8) blue))

(defun colour-palette-index (colour)
  "The palette index COLOUR names, or NIL when it is the default or 24-bit."
  (and (= (ldb (byte 2 24) colour) 1) (ldb (byte 8 0) colour)))

(defun colour-rgb (colour)
  "The red, green, and blue of a 24-bit COLOUR, or NIL when it is not one."
  (when (= (ldb (byte 2 24) colour) 2)
    (values (ldb (byte 8 16) colour) (ldb (byte 8 8) colour) (ldb (byte 8 0) colour))))

(defun rgb-to-256 (r g b)
  "Convert 24-bit RGB, each component 0-255, to the nearest xterm 256-colour
   index, which is always 16-255 (LEXTER-D68)."
  ;; Check if it's a grayscale value
  (if (and (= r g) (= g b))
      (cond
        ((< r 8) 16)        ; black
        ((> r 248) 231)     ; white
        ;; The greyscale ramp, 232-255, whose last entry is 238
        (t (min 255 (+ 232 (floor (- r 8) 10)))))
      ;; Map to 6x6x6 color cube
      (let ((ri (floor r 51))
            (gi (floor g 51))
            (bi (floor b 51)))
        (+ 16 (* 36 ri) (* 6 gi) bi))))

;;; --------------------------------------------------------------------------
;;; Styles
;;; --------------------------------------------------------------------------

(defstruct (style (:copier copy-style))
  "The attributes of text as the host sent them. An interned style is never
   changed: a new one is made with COPY-STYLE and interned in its turn."
  (foreground       +default-colour+ :type colour)
  (background       +default-colour+ :type colour)
  ;; The SGR 58 colour of lines, the default being the foreground's
  (underline-colour +default-colour+ :type colour)
  (bold          nil :type boolean)
  (underline     nil :type boolean)
  ;; The line style, 0 the single line; others are LEXTER-O48
  (line-style    0   :type (unsigned-byte 3))
  (strikethrough nil :type boolean)
  (overline      nil :type boolean)
  (reverse       nil :type boolean)
  (blink         nil :type boolean)
  (invisible     nil :type boolean))

(defconstant +max-styles+ 65536
  "The most styles a table holds: as many as a 16-bit style id names.")

(defstruct (style-table (:constructor %make-style-table))
  "A terminal's styles, by id, shared by its screens, with the terminal's
   presentation settings and the swatch each style is drawn in under them."
  (styles  (make-array 16 :adjustable t :fill-pointer 0) :type vector)
  (index   (make-hash-table :test 'equalp) :type hash-table)
  ;; The global swatch of each style under the settings, or -1 until built
  (swatches (make-array 16 :element-type 'fixnum :adjustable t :fill-pointer 0)
   :type vector)
  ;; The id of the style that keeps only each style's colours, or -1
  (erased (make-array 16 :element-type 'fixnum :adjustable t :fill-pointer 0)
   :type vector)
  (%bold-as-bright nil :type boolean))

(defun make-style-table (&key bold-as-bright)
  "Make a style table whose style 0 is the default: default colours and no
   attributes, the style of every blank cell. BOLD-AS-BRIGHT is the
   terminal's setting of that presentation rule (LEXTER-D125)."
  (let ((table (%make-style-table :%bold-as-bright bold-as-bright)))
    (intern-style table (make-style))
    table))

(defun style-table-count (table)
  "How many styles TABLE holds."
  (fill-pointer (style-table-styles table)))

(defun intern-style (table style)
  "The id of STYLE in TABLE, interning it if it is new. A full table interns
   nothing and gives style 0, the default."
  (or (gethash style (style-table-index table))
      (let ((id (style-table-count table)))
        (if (>= id +max-styles+)
            0
            (progn
              (vector-push-extend style (style-table-styles table))
              (vector-push-extend -1 (style-table-swatches table))
              (vector-push-extend -1 (style-table-erased table))
              (setf (gethash style (style-table-index table)) id))))))

(defun table-style (table id)
  "The style whose id in TABLE is ID."
  (aref (style-table-styles table) id))

(defun style-table-bold-as-bright (table)
  "True when TABLE's terminal draws bold text of palette colours 0-7 in colours
   8-15."
  (style-table-%bold-as-bright table))

(defun (setf style-table-bold-as-bright) (value table)
  "Set the bold-as-bright rule of TABLE's terminal. Its screens' rows must be
   built again to draw under it."
  (unless (eq (and value t) (style-table-%bold-as-bright table))
    (setf (style-table-%bold-as-bright table) (and value t))
    (fill (style-table-swatches table) -1))
  value)

(defun erased-style (table id)
  "The id of the style in which a cell of style ID is erased: its foreground
   and background, and no other attributes, as the first edition's erase kept
   a cell's swatch and cleared its attributes."
  (let ((cached (aref (style-table-erased table) id)))
    (if (>= cached 0)
        cached
        (let ((style (table-style table id)))
          (setf (aref (style-table-erased table) id)
                (intern-style table (make-style :foreground (style-foreground style)
                                                :background (style-background style))))))))

;;; --------------------------------------------------------------------------
;;; Presentation
;;; --------------------------------------------------------------------------

(defun %drawn-index (colour default)
  "The palette index COLOUR is drawn in: DEFAULT for the default colour, and
   the nearest entry of the 256-colour palette for a 24-bit colour, until the
   inline-colour format draws it (LEXTER-D125)."
  (or (colour-palette-index colour)
      (multiple-value-bind (r g b) (colour-rgb colour)
        (if r (rgb-to-256 r g b) default))))

(defun style-swatch (styles swatches id palette)
  "The global swatch, from SWATCHES, in which text of style ID of STYLES is
   drawn under its terminal's settings: its background and foreground, the
   foreground of a bold style brightened from palette colours 0-7 to 8-15
   when the terminal draws bold as bright, but never the default foreground
   (LEXTER-D125). A full swatch table gives its nearest swatch, as drawn in
   PALETTE. Each style's swatch is kept until the settings change."
  (let ((cached (aref (style-table-swatches styles) id)))
    (if (>= cached 0)
        cached
        (let* ((style (table-style styles id))
               (fg-colour (style-foreground style))
               (fg (%drawn-index fg-colour 7))
               (fg (if (and (style-table-%bold-as-bright styles)
                            (style-bold style)
                            (colour-palette-index fg-colour)
                            (<= 0 fg 7))
                       (+ fg 8)
                       fg))
               (bg (%drawn-index (style-background style) 0)))
          (setf (aref (style-table-swatches styles) id)
                (intern-swatch swatches bg fg fg 0 palette))))))
