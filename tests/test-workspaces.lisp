;;;; tests/test-workspaces.lisp — Switching between a compositor's workspaces.
;;;;
;;;; Pure: a compositor that is never initialized, its workspaces' terminal
;;;; panes made on a test atlas with no PTY, and a display grid in memory; no
;;;; GL. The tests of LEXTER-O32 fail until a switch marks the new workspace's
;;;; panes and decorations dirty (LEXTER-D71).

(in-package #:lexter-tests)
(in-suite workspaces)

(defmacro with-two-workspaces ((first second grid) &body body)
  "Run BODY with FIRST and SECOND bound to terminal panes of 5 by 2, each the
one pane of a workspace of a compositor that is not initialized, and GRID to
the compositor's display grid. The panes' screens are made on a test atlas;
the first workspace is shown. The second workspace has a list decoration:
glyph B at column 5, row 1, beside the pane. In BODY, (SHOW index) switches to a workspace and
flushes it, and (WRITE-A pane) writes A at column 0, row 1 of PANE's screen."
  (let ((comp (gensym "COMP")) (atlas (gensym "ATLAS")))
    `(let* ((,atlas (make-test-atlas))
            (,first (make-instance 'lexter/panes:uterm-pane :width 5 :height 2))
            (,second (make-instance 'lexter/panes:uterm-pane :width 5 :height 2))
            (,comp (lexter/panes:make-paned-compositor
                    :workspaces
                    (list (make-instance 'lexter/panes:workspace :panes (list ,first))
                          (make-instance 'lexter/panes:workspace
                                         :panes (list ,second)
                                         :decorations (list (list 5 1 (glyph ,atlas #x42) 0))))))
            (,grid (make-test-grid :cols 6 :rows 2)))
       (setf (lexter/panes:compositor-display ,comp) ,grid)
       (lexter/panes:pane-initialize ,first ,atlas)
       (lexter/panes:pane-initialize ,second ,atlas)
       (flet ((show (index)
                ;; As the compositor's tick does: switch, then flush the
                ;; workspace shown
                (lexter/panes::switch-workspace ,comp index)
                (lexter/panes:flush-workspace (lexter/panes::active-workspace ,comp) ,grid))
              (write-a (pane)
                ;; Below the cursor's row, which every flush copies again
                (lexter/model:write-char-at (lexter/panes:vt-pane-screen pane) 0 1
                                            (glyph ,atlas #x41))))
         (declare (ignorable #'show #'write-a))
         ,@body))))

(def-test switch-repaints-the-workspace-shown ()
  "LEXTER-O32: a workspace switched back to is drawn again whole, though its
panes produced no output while it was hidden (LEXTER-D71)."
  (with-two-workspaces (first second grid)
    (write-a second)
    (show 1)
    (show 0)
    (show 1)
    (is (= (glyph (make-test-atlas) #x41) (grid-glyph grid 0 1)))))

(def-test switch-redraws-the-decorations ()
  "LEXTER-O32: a workspace switched back to has its decorations drawn again,
though nothing changed its layout (LEXTER-D71)."
  (with-two-workspaces (first second grid)
    (show 1)
    (show 0)
    (show 1)
    (is (= (glyph (make-test-atlas) #x42) (grid-glyph grid 5 1)))))
