;;;; Workspace: a collection of panes with focus management and decorations.

(in-package #:lexter/panes)

;;; --------------------------------------------------------------------------
;;; Workspace class
;;; --------------------------------------------------------------------------

(defclass workspace ()
  ((name        :initarg :name
                :accessor workspace-name
                :initform ""
                :type string
                :documentation "Human-readable workspace name.")
   (panes       :initarg :panes
                :accessor workspace-panes
                :initform '()
                :type list
                :documentation "List of pane objects in this workspace.")
   (decorations :initarg :decorations
                :accessor workspace-decorations
                :initform '()
                :type list
                :documentation "List of (col row glyph swatch) for borders/separators.")
   (focus-index :accessor workspace-focus-index
                :initform 0
                :type fixnum
                :documentation "Index into panes of the focused pane."))
  (:documentation "A named collection of panes with focus management."))

;;; --------------------------------------------------------------------------
;;; Focus management
;;; --------------------------------------------------------------------------

(defun focused-pane (workspace)
  "Return the currently focused pane, or NIL if no panes."
  (let ((panes (workspace-panes workspace))
        (idx (workspace-focus-index workspace)))
    (when (and panes (< idx (length panes)))
      (nth idx panes))))

(defun focusable-panes (workspace)
  "Return list of (index . pane) for focusable panes."
  (loop :for pane :in (workspace-panes workspace)
        :for i :from 0
        :when (pane-focusable pane)
        :collect (cons i pane)))

(defun focus-next (workspace)
  "Move focus to the next focusable pane. Wraps around."
  (let ((focusable (focusable-panes workspace)))
    (when (> (length focusable) 1)
      (let* ((current-idx (workspace-focus-index workspace))
             (pos (position current-idx focusable :key #'car))
             (next-pos (if pos
                           (mod (1+ pos) (length focusable))
                           0)))
        (setf (workspace-focus-index workspace)
              (car (nth next-pos focusable)))))))

(defun focus-prev (workspace)
  "Move focus to the previous focusable pane. Wraps around."
  (let ((focusable (focusable-panes workspace)))
    (when (> (length focusable) 1)
      (let* ((current-idx (workspace-focus-index workspace))
             (pos (position current-idx focusable :key #'car))
             (prev-pos (if pos
                           (mod (1- pos) (length focusable))
                           0)))
        (setf (workspace-focus-index workspace)
              (car (nth prev-pos focusable)))))))

(defun focus-pane (workspace pane)
  "Set focus to PANE if it's in the workspace and focusable."
  (let ((idx (position pane (workspace-panes workspace))))
    (when (and idx (pane-focusable pane))
      (setf (workspace-focus-index workspace) idx))))

;;; --------------------------------------------------------------------------
;;; Workspace operations
;;; --------------------------------------------------------------------------

(defun flush-workspace (workspace grid)
  "Flush all panes in WORKSPACE to GRID, then render decorations."
  ;; Flush each pane
  (dolist (pane (workspace-panes workspace))
    (pane-flush pane grid))
  ;; Render decorations (border characters, separators)
  (dolist (dec (workspace-decorations workspace))
    (destructuring-bind (col row glyph swatch) dec
      (lexter/grid:set-simple-cell grid col row glyph swatch))))

(defun workspace-any-dirty-p (workspace)
  "Return T if any pane in WORKSPACE needs re-flushing."
  (some #'pane-dirty-p (workspace-panes workspace)))

(defun workspace-process-output (workspace)
  "Process I/O for all panes in WORKSPACE. Return T if any had output."
  (let ((any-output nil))
    (dolist (pane (workspace-panes workspace))
      (when (pane-process-output pane)
        (setf any-output t)))
    any-output))

(defun workspace-any-terminal-alive-p (workspace)
  "Return T if any terminal pane in WORKSPACE has a live connection.
   Checks both Unix terminal panes (PTY alive) and other pane types
   that respond to pane-alive-p."
  (some #'pane-alive-p (workspace-panes workspace)))

(defun destroy-workspace (workspace)
  "Clean up all panes in WORKSPACE."
  (dolist (pane (workspace-panes workspace))
    (pane-destroy pane)))

;;; --------------------------------------------------------------------------
;;; Grid clearing utility
;;; --------------------------------------------------------------------------

(defun clear-grid (grid &key (glyph 32) (swatch 0))
  "Clear the entire grid with GLYPH and SWATCH."
  (let ((cols (lexter/grid:display-grid-cols grid))
        (rows (lexter/grid:display-grid-rows grid)))
    (dotimes (row rows)
      (dotimes (col cols)
        (lexter/grid:set-simple-cell grid col row glyph swatch)))
    (lexter/grid:mark-all-dirty grid)))
