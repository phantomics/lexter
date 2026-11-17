;;;; tests/test-profiles.lisp — Pane profiles and the lookup of their settings.
;;;;
;;;; Pure: panes, workspaces, and compositors made in memory, never given a
;;;; window; no GL, no PTY. They test the pane-profiles plan's profiles
;;;; (LEXTER-DRAFT-pane-profiles-D1 to -D4), with the compositor found as
;;;; LEXTER-DRAFT-pane-profiles-O2 leans.

(in-package #:lexter-tests)
(in-suite profiles)

;;; A profile class of the kind the APL layer defines, with a setting of its
;;; own that Lexter's base profiles lack.
(lexter/panes:define-pane-profile test-pane-profile (lexter/panes:pane-profile)
  ((border-flash-color :type (unsigned-byte 8) :default 11
                       :documentation "A setting only this profile class has.")))

(defmacro with-pane-in-compositor ((pane workspace compositor) &body body)
  "Run BODY with PANE bound to a pane in WORKSPACE, the one workspace of
COMPOSITOR, none of them given a window."
  `(let* ((,pane (make-instance 'lexter/panes:uterm-pane :width 10 :height 3))
          (,workspace (make-instance 'lexter/panes:workspace :panes (list ,pane)))
          (,compositor (lexter/panes:make-paned-compositor :workspaces (list ,workspace))))
     (declare (ignorable ,compositor))
     ,@body))

(def-test workspace-knows-its-compositor ()
  "A compositor's workspaces refer back to it, so that a pane finds the
compositor through its workspace (LEXTER-DRAFT-pane-profiles-O2)."
  (with-pane-in-compositor (pane ws comp)
    (is (eq ws (lexter/panes:pane-workspace pane)))
    (is (eq comp (lexter/panes:workspace-compositor ws)))))

(def-test unset-settings-take-their-defaults ()
  "A setting set nowhere takes the default its definition declares."
  (with-pane-in-compositor (pane ws comp)
    (is (= 3 (lexter/panes:pane-wheel-scroll-lines pane)))
    (is-true (lexter/panes:pane-snap-on-input pane))
    (is-false (lexter/panes:pane-snap-on-output pane))))

(def-test pane-then-workspace-then-compositor ()
  "A setting is looked up in the pane's profile, then the workspace's, then the
compositor's: the nearest level that sets it wins, and a value set at run
time reaches panes already built."
  (with-pane-in-compositor (pane ws comp)
    (setf (lexter/panes:compositor-wheel-scroll-lines comp) 5)
    (is (= 5 (lexter/panes:pane-wheel-scroll-lines pane)))
    (setf (lexter/panes:workspace-wheel-scroll-lines ws) 4)
    (is (= 4 (lexter/panes:pane-wheel-scroll-lines pane)))
    (setf (lexter/panes:pane-wheel-scroll-lines pane) 2)
    (is (= 2 (lexter/panes:pane-wheel-scroll-lines pane)))))

(def-test parent-chain-comes-before-containment ()
  "A pane's profile and its chain of parents are searched before the
workspace's profile (LEXTER-DRAFT-pane-profiles-D2)."
  (with-pane-in-compositor (pane ws comp)
    (setf (lexter/panes:workspace-wheel-scroll-lines ws) 4
          (lexter/panes:profile-parent (lexter/panes:pane-profile pane))
          (make-instance 'lexter/panes:pane-profile :wheel-scroll-lines 7))
    (is (= 7 (lexter/panes:pane-wheel-scroll-lines pane)))))

(def-test shared-parent-reaches-every-sharer ()
  "Panes whose profiles share a parent read its settings, and a write through
one pane changes only that pane's own profile (LEXTER-DRAFT-pane-profiles-D3)."
  (let* ((shared (make-instance 'lexter/panes:pane-profile :snap-on-output t))
         (a (make-instance 'lexter/panes:uterm-pane :profile-parent shared))
         (b (make-instance 'lexter/panes:uterm-pane :profile-parent shared)))
    (is-true (lexter/panes:pane-snap-on-output a))
    (is-true (lexter/panes:pane-snap-on-output b))
    (setf (lexter/panes:pane-snap-on-output a) nil)
    (is-false (lexter/panes:pane-snap-on-output a))
    (is-true (lexter/panes:pane-snap-on-output b))
    (is-true (lexter/panes:profile-snap-on-output shared))))

(def-test profiles-without-the-setting-are-skipped ()
  "A setting that only a subclass of the base profile defines is found in a
pane's chain, and otherwise takes its default, though the workspace's and
compositor's profiles lack it."
  (with-pane-in-compositor (pane ws comp)
    (is (= 11 (pane-border-flash-color pane)))
    (setf (lexter/panes:profile-parent (lexter/panes:pane-profile pane))
          (make-instance 'test-pane-profile :border-flash-color 9))
    (is (= 9 (pane-border-flash-color pane)))))

(def-test unsetting-restores-inheritance ()
  "Removing a setting from a pane's own profile makes the pane inherit it
again."
  (with-pane-in-compositor (pane ws comp)
    (setf (lexter/panes:workspace-wheel-scroll-lines ws) 4
          (lexter/panes:pane-wheel-scroll-lines pane) 2)
    (lexter/panes:unset-setting pane 'lexter/panes:wheel-scroll-lines)
    (is (= 4 (lexter/panes:pane-wheel-scroll-lines pane)))))

(def-test writers-check-the-declared-type ()
  "A writer refuses a value outside the setting's declared type, at every
level."
  (with-pane-in-compositor (pane ws comp)
    (signals type-error (setf (lexter/panes:pane-wheel-scroll-lines pane) 0))
    (signals type-error (setf (lexter/panes:workspace-wheel-scroll-lines ws) "3"))
    (signals type-error (setf (lexter/panes:compositor-snap-on-input comp) :yes))
    (is (= 3 (lexter/panes:pane-wheel-scroll-lines pane)))))
