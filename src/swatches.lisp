(in-package #:lexter/swatches)

;;;; Swatch stores and the tables that own their ranges (LEXTER-D99,
;;;; LEXTER-D100, LEXTER-DRAFT-cell-model-revision-D24).
;;;;
;;;; A store is the CPU's account of one GPU swatch store: 65,536 swatches in
;;;; ranges of 2048, each range owned by at most one table. A table interns
;;;; swatches and hands out global indices, its range's base plus the offset,
;;;; which screens store in their cells and the flush copies unchanged. A
;;;; table takes a range when it is made and another when it fills, up to a
;;;; limit; a full table returns its nearest existing swatch. Ranges never
;;;; move, and return to the store when their table is released.
;;;;
;;;; The store's display table, which holds everything drawn at the level of
;;;; Lexter's display, takes range 0 when the store is made, so global swatch 0
;;;; is always the default colours (LEXTER-D83).
;;;;
;;;; The renderer's upload decision is here too, with no GL, so that the tests
;;;; call the decision the renderer makes (LEXTER-D106).

;;; --------------------------------------------------------------------------
;;; Constants
;;; --------------------------------------------------------------------------

(defconstant +range-size+ 2048
  "Swatches in one range of a store.")

(defconstant +store-size+ 65536
  "Swatches in a store, the texels a texture buffer is guaranteed in OpenGL 3.3.")

(defconstant +store-ranges+ (floor +store-size+ +range-size+)
  "Ranges in a store.")

(defconstant +first-edition-ranges+ 16
  "Ranges usable while the first edition carries the wide flag in bit 15 of
   each instance's swatch field, so that global indices stay below 32,768.")

(defconstant +max-table-ranges+ 4
  "Ranges one table may hold, so that one pane cannot take the whole store.")

(defconstant +palette-entries+ 256
  "Colours in one palette.")

(defconstant +palette-bytes+ (* +palette-entries+ 4)
  "Bytes in one palette: an RGBA8 texel for each colour.")

;;; --------------------------------------------------------------------------
;;; The default palette
;;; --------------------------------------------------------------------------

(deftype palette ()
  "A palette: 256 colours as RGBA bytes, as the GPU's integer store holds them
   (LEXTER-D109)."
  `(simple-array (unsigned-byte 8) (,+palette-bytes+)))

(defun make-default-palette ()
  "Return a fresh copy of the standard xterm 256-colour palette, as RGBA bytes."
  (let ((p (make-array +palette-bytes+ :element-type '(unsigned-byte 8)
                                       :initial-element 255)))
    (flet ((set-rgb (i r g b)
             (setf (aref p (+ (* i 4) 0)) r
                   (aref p (+ (* i 4) 1)) g
                   (aref p (+ (* i 4) 2)) b))
           (comp6 (v) (if (zerop v) 0 (+ 55 (* 40 v)))))
      ;; Colours 0-15: standard ANSI
      (loop :for (r g b) :in '((0   0   0)    ; 0  black
                               (170 0   0)    ; 1  dark red
                               (0   170 0)    ; 2  dark green
                               (170 85  0)    ; 3  dark yellow
                               (0   0   170)  ; 4  dark blue
                               (170 0   170)  ; 5  dark magenta
                               (0   170 170)  ; 6  dark cyan
                               (170 170 170)  ; 7  light grey
                               (85  85  85)   ; 8  dark grey
                               (255 85  85)   ; 9  bright red
                               (85  255 85)   ; 10 bright green
                               (255 255 85)   ; 11 bright yellow
                               (85  85  255)  ; 12 bright blue
                               (255 85  255)  ; 13 bright magenta
                               (85  255 255)  ; 14 bright cyan
                               (255 255 255)) ; 15 white
            :for i :from 0
            :do (set-rgb i r g b))
      ;; Colours 16-231: 6x6x6 cube
      (loop :for i :from 16 :to 231
            :for n = (- i 16)
            :do (set-rgb i
                         (comp6 (floor n 36))
                         (comp6 (mod (floor n 6) 6))
                         (comp6 (mod n 6))))
      ;; Colours 232-255: greyscale ramp
      (loop :for i :from 232 :to 255
            :for v = (+ 8 (* 10 (- i 232)))
            :do (set-rgb i v v v)))
    p))

(defvar *default-palette* (make-default-palette)
  "The default palette, by which a table finds its nearest swatch when it is
   given no palette. Never modified.")

;;; --------------------------------------------------------------------------
;;; Stores and tables
;;; --------------------------------------------------------------------------

(defvar *next-table-id* 0
  "The last id given to a swatch table. Ids come from this one counter, so an
   upload record names its table even after the table's range has been
   released and given to another.")

(defstruct (swatch-store (:constructor %make-swatch-store))
  "The CPU's account of one GPU swatch store: which table owns each range."
  (owners (make-array +store-ranges+ :initial-element nil) :type simple-vector)
  (usable-ranges +first-edition-ranges+ :type fixnum)
  (max-table-ranges +max-table-ranges+ :type fixnum)
  (display-table nil))

(defstruct (swatch-table (:constructor %make-swatch-table))
  "A table of swatches with interning, owning ranges of its store. Local
   number N lies in the table's range N / 2048, at offset N mod 2048."
  (id 0 :type fixnum)
  (store nil :type (or null swatch-store))
  ;; Swatch N occupies bytes [N*4 .. N*4+3]: its palette indices for slots 0-3
  (data (make-array 0 :element-type '(unsigned-byte 8))
   :type (simple-array (unsigned-byte 8) (*)))
  (count 0 :type fixnum)
  ;; The store's ranges this table holds, in the order it took them
  (ranges (make-array 0 :adjustable t :fill-pointer 0) :type vector)
  ;; Key of four palette indices -> global index of an interned swatch
  (index (make-hash-table) :type hash-table)
  ;; Key -> global index of the nearest swatch, for keys a full table refused
  (fallbacks (make-hash-table) :type hash-table)
  ;; Bumped by any change other than growth, so the range is uploaded again
  (version 0 :type fixnum)
  (released nil :type boolean))

(defun %swatch-key (s0 s1 s2 s3)
  (logior s0 (ash s1 8) (ash s2 16) (ash s3 24)))

(defun %take-range (store table)
  "Give TABLE the lowest free range of STORE, and return it, or NIL when the
   store has none free or TABLE holds as many as it may."
  (when (< (length (swatch-table-ranges table)) (swatch-store-max-table-ranges store))
    (let ((owners (swatch-store-owners store)))
      (loop :for r :from 0 :below (swatch-store-usable-ranges store)
            :unless (aref owners r)
              :do (setf (aref owners r) table)
                  (vector-push-extend r (swatch-table-ranges table))
                  (let ((data (make-array (* (length (swatch-table-ranges table))
                                             +range-size+ 4)
                                          :element-type '(unsigned-byte 8)
                                          :initial-element 0)))
                    (replace data (swatch-table-data table))
                    (setf (swatch-table-data table) data))
                  (return r)))))

(defun %local->global (table local)
  (+ (* (aref (swatch-table-ranges table) (floor local +range-size+)) +range-size+)
     (mod local +range-size+)))

(defun %global->local (table global)
  "The local number of GLOBAL in TABLE, or NIL if TABLE does not hold it."
  (let ((k (position (floor global +range-size+) (swatch-table-ranges table))))
    (when k
      (let ((local (+ (* k +range-size+) (mod global +range-size+))))
        (when (< local (swatch-table-count table))
          local)))))

(defun %add-entry (table s0 s1 s2 s3)
  "Append a swatch to TABLE, taking a range if it needs one, and return its
   global index, or NIL when TABLE is full."
  (let ((local (swatch-table-count table)))
    (when (or (< local (* (length (swatch-table-ranges table)) +range-size+))
              (%take-range (swatch-table-store table) table))
      (let ((base (* local 4))
            (data (swatch-table-data table)))
        (setf (aref data (+ base 0)) s0
              (aref data (+ base 1)) s1
              (aref data (+ base 2)) s2
              (aref data (+ base 3)) s3))
      (incf (swatch-table-count table))
      (%local->global table local))))

(defun %check-live (table)
  (when (swatch-table-released table)
    (error "Swatch table ~d has been released." (swatch-table-id table))))

(defun make-swatch-table (store)
  "Make a table in STORE, give it the lowest free range, and intern the default
   swatch, background 0 and foreground 7, as its local 0. Its global index is
   the table's default swatch (SWATCH-TABLE-DEFAULT). A table made when STORE
   has no range free holds none, and every swatch it is asked for is global
   swatch 0, the default colours of the display's table."
  (let ((table (%make-swatch-table :id (incf *next-table-id*) :store store)))
    (when (%take-range store table)
      (intern-swatch table 0 7 7 0))
    table))

(defun make-swatch-store (&key (usable-ranges +first-edition-ranges+)
                               (max-table-ranges +max-table-ranges+))
  "Make a swatch store whose tables may use its first USABLE-RANGES ranges, at
   most MAX-TABLE-RANGES each. Its display table takes range 0, so global
   swatch 0 is the default colours."
  (let ((store (%make-swatch-store :usable-ranges usable-ranges
                                   :max-table-ranges max-table-ranges)))
    (setf (swatch-store-display-table store) (make-swatch-table store))
    store))

(defun swatch-table-default (table)
  "The global index of TABLE's default swatch, its local 0."
  (if (plusp (swatch-table-count table))
      (%local->global table 0)
      0))

(defun swatch-table-full-p (table)
  "True when TABLE's ranges are filled and it can take no other."
  (let ((store (swatch-table-store table))
        (held (length (swatch-table-ranges table))))
    (and (= (swatch-table-count table) (* held +range-size+))
         (or (>= held (swatch-store-max-table-ranges store))
             (not (find nil (swatch-store-owners store)
                        :end (swatch-store-usable-ranges store)))))))

;;; --------------------------------------------------------------------------
;;; Interning
;;; --------------------------------------------------------------------------

(defun %colour-distance (palette a b)
  "The squared distance between the RGB values of palette entries A and B."
  (let ((pa (* a 4)) (pb (* b 4)))
    (loop :for c :below 3
          :sum (expt (- (aref palette (+ pa c)) (aref palette (+ pb c))) 2))))

(defun %nearest-swatch (table s0 s1 s2 s3 palette)
  "The global index of TABLE's swatch whose four slots are nearest to S0-S3,
   by the sum of squared RGB distances in PALETTE; ties go to the lowest."
  (let ((data (swatch-table-data table))
        (best nil)
        (best-distance nil))
    (dotimes (local (swatch-table-count table))
      (let* ((base (* local 4))
             (d (+ (%colour-distance palette s0 (aref data base))
                   (%colour-distance palette s1 (aref data (+ base 1)))
                   (%colour-distance palette s2 (aref data (+ base 2)))
                   (%colour-distance palette s3 (aref data (+ base 3))))))
        (when (or (null best-distance) (< d best-distance))
          (setf best local best-distance d))))
    (if best (%local->global table best) 0)))

(defun intern-swatch (table s0 s1 s2 s3 &optional palette)
  "Return the global index of the swatch of palette indices S0-S3 in TABLE,
   interning it if it is new. A full table interns nothing, and returns its
   existing swatch nearest in colour, as drawn in PALETTE (by default the
   default palette), so that drawing never fails
   (LEXTER-DRAFT-cell-model-revision-D24)."
  (%check-live table)
  (let ((key (%swatch-key s0 s1 s2 s3)))
    (or (gethash key (swatch-table-index table))
        (gethash key (swatch-table-fallbacks table))
        (let ((global (%add-entry table s0 s1 s2 s3)))
          (if global
              (setf (gethash key (swatch-table-index table)) global)
              (setf (gethash key (swatch-table-fallbacks table))
                    (%nearest-swatch table s0 s1 s2 s3
                                     (or palette *default-palette*))))))))

(defun append-swatch (table s0 s1 s2 s3)
  "Append a swatch to TABLE that interning never matches, and return its
   global index, or NIL when TABLE is full. Such entries keep room for
   swatches that are reindexed rather than interned (LEXTER-O73)."
  (%check-live table)
  (%add-entry table s0 s1 s2 s3))

(defun table-swatch (table global)
  "The palette indices of TABLE's swatch GLOBAL, as four values."
  (let ((local (or (%global->local table global)
                   (error "Swatch table ~d holds no swatch ~d."
                          (swatch-table-id table) global)))
        (data (swatch-table-data table)))
    (values (aref data (* local 4))
            (aref data (+ (* local 4) 1))
            (aref data (+ (* local 4) 2))
            (aref data (+ (* local 4) 3)))))

(defun store-swatch (store global)
  "The palette indices of global swatch GLOBAL in STORE, as four values: zeros
   for a swatch that no table holds."
  (let ((owner (aref (swatch-store-owners store) (floor global +range-size+))))
    (if (and owner (%global->local owner global))
        (table-swatch owner global)
        (values 0 0 0 0))))

(defun range-owner (store range)
  "The table that owns RANGE of STORE, or NIL."
  (aref (swatch-store-owners store) range))

(defun bump-swatch-table-version (table)
  "Record a change to TABLE other than growth, so that its ranges are uploaded
   whole at the next frame."
  (incf (swatch-table-version table)))

(defun release-swatch-table (table)
  "Return TABLE's ranges to its store. A released table interns nothing."
  (unless (swatch-table-released table)
    (let ((owners (swatch-store-owners (swatch-table-store table))))
      (loop :for r :across (swatch-table-ranges table)
            :do (when (eq (aref owners r) table)
                  (setf (aref owners r) nil))))
    (setf (fill-pointer (swatch-table-ranges table)) 0
          (swatch-table-released table) t))
  table)

;;; --------------------------------------------------------------------------
;;; Uploads (the renderer's decision, without GL)
;;; --------------------------------------------------------------------------

(defstruct (swatch-upload-records (:constructor make-swatch-upload-records ()))
  "What the GPU's copy of a store holds, range by range: the id and version of
   the table last uploaded to the range, and how many of its swatches."
  (table-ids (make-array +store-ranges+ :element-type 'fixnum :initial-element -1)
   :type (simple-array fixnum (*)))
  (versions (make-array +store-ranges+ :element-type 'fixnum :initial-element 0)
   :type (simple-array fixnum (*)))
  (counts (make-array +store-ranges+ :element-type 'fixnum :initial-element 0)
   :type (simple-array fixnum (*))))

(defun plan-swatch-uploads (store records)
  "Decide what to upload so that the GPU's copy of STORE matches its tables,
   and note it in RECORDS as uploaded. For each range a table owns: the whole
   of what the table holds there, when the range was last uploaded from
   another table or another version of this one; otherwise the swatches it
   has added since. Returns a list of (FIRST COUNT DATA START): COUNT swatches
   for the store from global index FIRST, taken from the byte vector DATA from
   byte START."
  (let ((ids (swatch-upload-records-table-ids records))
        (versions (swatch-upload-records-versions records))
        (counts (swatch-upload-records-counts records))
        (spans '()))
    (dotimes (r +store-ranges+ (nreverse spans))
      (let ((table (aref (swatch-store-owners store) r)))
        (when table
          (let* ((k (position r (swatch-table-ranges table)))
                 (used (max 0 (min +range-size+
                                   (- (swatch-table-count table) (* k +range-size+)))))
                 (same (and (= (aref ids r) (swatch-table-id table))
                            (= (aref versions r) (swatch-table-version table))))
                 (from (if same (aref counts r) 0)))
            (when (< from used)
              (push (list (+ (* r +range-size+) from)
                          (- used from)
                          (swatch-table-data table)
                          (* 4 (+ (* k +range-size+) from)))
                    spans))
            (setf (aref ids r) (swatch-table-id table)
                  (aref versions r) (swatch-table-version table)
                  (aref counts r) used)))))))
