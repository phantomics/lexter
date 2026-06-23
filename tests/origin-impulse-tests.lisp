;;;; tests/origin-impulse-tests.lisp
;;;;
;;;; Headless tests for the :LEXTER-HOST Impulse sub-vocabulary (Phase 7).
;;;;
;;;; No display is needed: MAKE-TERMINAL builds a UNIX-TERMINAL struct without
;;;; touching GLFW, so we populate the live-window registry (*GUI-OBJECTS*) with
;;;; uninitialized terminals and drive the control plane in-image. A minimal
;;;; fake cooperative executor exercises the main-thread marshaling path.

(defpackage #:lexter/origin-tests
  (:use #:cl #:fiveam)
  (:shadow #:run-all-tests)
  (:import-from #:hamcrest/fiveam #:assert-that)
  (:import-from #:hamcrest/matchers #:has-plist-entries)
  (:export #:run-all-tests))

(in-package #:lexter/origin-tests)

(def-suite lexter-impulse
  :description "Phase 7: the :LEXTER-HOST Impulse sub-vocabulary")
(in-suite lexter-impulse)

;;; -----------------------------------------------------------------------
;;; Isolation + fixtures
;;; -----------------------------------------------------------------------

(defun %canon (name)
  (etypecase name (string name) (symbol (string-downcase (symbol-name name)))))

(defun %clean ()
  "Reset Origin registry and the Lexter / Impulse side registries."
  (ignore-errors (origin:clear-registry :force t))
  (sb-thread:with-mutex (origin::*registry-lock*)
    (clrhash origin::*process-registry*))
  (setf lexter/origin::*gui-objects* nil)
  (clrhash lexter/origin::*terminal-specs*)
  (clrhash impulse::*orbital-control-types*)
  (clrhash impulse::*orbital-specs*))

(defmacro with-clean (&body body)
  `(unwind-protect (progn (%clean) ,@body) (%clean)))

(defmacro with-fake-executor (&body body)
  "Register a cooperative executor whose mailbox runs inline on this thread, so
the dispatcher's :COOPERATIVE marshaling path is exercised."
  `(let ((mb (origin:make-mailbox :executor-thread sb-thread:*current-thread*)))
     (origin:register-cooperative-executor
      :start (lambda (p) (declare (ignore p)) nil)
      :stop  (lambda (p &key timeout) (declare (ignore p timeout)) nil)
      :mailbox mb)
     (unwind-protect (progn ,@body)
       (origin:unregister-cooperative-executor))))

(defun setup-terminal (name &rest args)
  "Register NAME as a Lexter terminal orbital and place a headless live
UNIX-TERMINAL (built with ARGS) into the live-window registry. Returns the
terminal object."
  (apply #'lexter/origin:define-terminal name "/bin/bash" args)
  (let ((term (apply #'lexter/unix-term:make-terminal "/bin/bash" args)))
    (push (cons (%canon name) term) lexter/origin::*gui-objects*)
    term))

;;; -----------------------------------------------------------------------
;;; Control-type tagging
;;; -----------------------------------------------------------------------

(def-test define-terminal-tags-lexter-host ()
  "define-terminal tags the orbital with the :LEXTER-HOST control type."
  (with-clean
    (lexter/origin:define-terminal :bash "/bin/bash" :cols 80 :rows 24)
    (is (eq :lexter-host (impulse:orbital-control-type
                          (origin:find-process "bash"))))))

;;; -----------------------------------------------------------------------
;;; describe
;;; -----------------------------------------------------------------------

(def-test describe-advertises-lexter-vocabulary ()
  "describe reports the :LEXTER-HOST control type and the window query/config
schema leaves."
  (with-clean
    (setup-terminal :bash :cols 80 :rows 24)
    (let* ((r (impulse:request "bash" :describe))
           (d (impulse:response-result r)))
      (is-true (impulse:ok-p r))
      (assert-that d (has-plist-entries :control-type :lexter-host))
      ;; The :status query schema includes the Lexter window leaves.
      (let* ((status-q (find :status (getf d :queries)
                             :key (lambda (q) (getf q :verb))))
             (leaves (mapcar #'first (getf status-q :leaves))))
        (dolist (leaf '(:cols :rows :pixel-scale :title :window-alive
                        :scrollback-lines :cursor :pid))
          (is-true (member leaf leaves) "describe should advertise ~S" leaf)))
      ;; The config schema includes the Lexter writable params.
      (let ((config (mapcar #'first (getf d :config-schema))))
        (dolist (param '(:cols :rows :pixel-scale :font-path :title))
          (is-true (member param config) "config should advertise ~S" param))))))

;;; -----------------------------------------------------------------------
;;; status -- typed window fields
;;; -----------------------------------------------------------------------

(def-test status-reports-window-fields ()
  "status on a :LEXTER-HOST orbital returns the typed window fields alongside
the universal status fields."
  (with-clean
    (setup-terminal :bash :cols 100 :rows 40 :title "shell" :pixel-scale 2)
    (let* ((r (impulse:request "bash" :status))
           (result (impulse:response-result r)))
      (is-true (impulse:ok-p r))
      ;; Universal fields still present.
      (assert-that result (has-plist-entries :name "bash" :status :stopped))
      ;; Lexter window fields present.
      (assert-that result
        (has-plist-entries :cols 100 :rows 40 :title "shell" :pixel-scale 2
                           :command "/bin/bash"))
      ;; Uninitialized terminal: not alive, no screen/pty derived fields.
      (is-false (getf result :window-alive))
      (is (null (getf result :scrollback-lines)))
      (is (null (getf result :pid))))))

(def-test status-query-narrows-window-fields ()
  "status :query selects across both universal and window fields."
  (with-clean
    (setup-terminal :bash :cols 132 :rows 50)
    (let* ((r (impulse:request "bash" :status :query '(:name :cols :rows)))
           (result (impulse:response-result r)))
      (is-true (impulse:ok-p r))
      (assert-that result (has-plist-entries :name "bash" :cols 132 :rows 50))
      ;; Fields not requested are absent.
      (is (null (getf result :title)))
      (is (null (getf result :pixel-scale))))))

(def-test status-falls-back-to-spec-when-no-live-window ()
  "With no live terminal, status reports the declared geometry from the spec."
  (with-clean
    ;; Register but do NOT push a live terminal into *gui-objects*.
    (lexter/origin:define-terminal :ghost "/bin/bash" :cols 90 :rows 30 :title "g")
    (let ((result (impulse:response-result (impulse:request "ghost" :status))))
      (assert-that result (has-plist-entries :cols 90 :rows 30 :title "g"))
      (is-false (getf result :window-alive)))))

;;; -----------------------------------------------------------------------
;;; configure / apply -- validate + commit window params
;;; -----------------------------------------------------------------------

(def-test configure-applies-live-and-to-spec ()
  "configure validates and commits Lexter params: live-settable ones hit the
terminal struct, all of them update the rebuild spec."
  (with-clean
    (let ((term (setup-terminal :bash :cols 80 :rows 24 :pixel-scale 1 :title "old")))
      (let ((r (impulse:request "bash" :configure
                                :args '(:pixel-scale 3 :title "new" :cols 120))))
        (is-true (impulse:ok-p r)))
      ;; Live-settable params applied to the terminal object.
      (is (= 3 (lexter/unix-term::unix-terminal-pixel-scale term)))
      (is (string= "new" (lexter/unix-term::unix-terminal-title term)))
      ;; All params persisted into the rebuild spec (cols applies on restart).
      (let ((spec (gethash "bash" lexter/origin::*terminal-specs*)))
        (is (= 120 (getf spec :cols)))
        (is (= 3 (getf spec :pixel-scale)))
        (is (string= "new" (getf spec :title)))))))

(def-test configure-rejects-invalid-param ()
  "An invalid Lexter param is a structured invalid-spec error."
  (with-clean
    (setup-terminal :bash :cols 80 :rows 24)
    (let ((r (impulse:request "bash" :configure :args '(:cols -5))))
      (is-true (impulse:error-p r))
      (assert-that (impulse:response-condition r)
        (has-plist-entries :type :invalid-spec)))))

(def-test configure-accepts-generic-knob ()
  "A universal knob (e.g. :priority) still validates/commits through the
:LEXTER-HOST methods, which delegate generic keys to the generic methods."
  (with-clean
    (setup-terminal :bash :cols 80 :rows 24)
    (let ((r (impulse:request "bash" :configure :args '(:priority :high :title "x"))))
      (is-true (impulse:ok-p r))
      (is (eq :high (origin:process-priority (origin:find-process "bash")))))))

;;; -----------------------------------------------------------------------
;;; Cooperative main-thread marshaling
;;; -----------------------------------------------------------------------

(def-test status-dispatches-through-cooperative-executor ()
  "With a cooperative executor active, dispatch marshals the :LEXTER-HOST
handler through the mailbox and still returns correct results."
  (with-clean
    (with-fake-executor
      (setup-terminal :bash :cols 77 :rows 25)
      (let ((result (impulse:response-result (impulse:request "bash" :status))))
        (assert-that result (has-plist-entries :cols 77 :rows 25))))))

;;; -----------------------------------------------------------------------
;;; Restart state handoff (Phase 9)
;;; -----------------------------------------------------------------------

(defun setup-terminal-with-screen (name &key (cols 80) (rows 24))
  "define-terminal NAME and place a headless terminal carrying a fresh model
SCREEN into *gui-objects*. Returns the screen."
  (apply #'lexter/origin:define-terminal name "/bin/bash" (list :cols cols :rows rows))
  (let ((term (lexter/unix-term:make-terminal "/bin/bash" :cols cols :rows rows))
        (screen (lexter/model:make-screen :cols cols :rows rows)))
    (setf (lexter/unix-term::unix-terminal-screen term) screen)
    (push (cons (%canon name) term) lexter/origin::*gui-objects*)
    screen))

(def-test handoff-advertised-in-describe ()
  "describe advertises the strata a Lexter terminal can hand off."
  (with-clean
    (lexter/origin:define-terminal :bash "/bin/bash" :cols 80 :rows 24)
    (is (equal '(:application :session)
               (getf (impulse:describe-orbital (origin:find-process "bash"))
                     :handoff)))))

(def-test handoff-exports-geometry-and-cursor ()
  "export-state captures the terminal geometry (:application) and cursor
position (:session) as a versioned handoff datum."
  (with-clean
    (let ((screen (setup-terminal-with-screen :bash :cols 100 :rows 40)))
      (lexter/model:set-cursor-position screen 7 11)
      (let ((state (impulse:export-state :lexter-host (origin:find-process "bash"))))
        (is-true (impulse:handoff-state-p state))
        (let ((app (impulse:handoff-stratum state :application))
              (sess (impulse:handoff-stratum state :session)))
          (is (= 100 (getf app :cols)))
          (is (= 40 (getf app :rows)))
          (is (= 7 (getf sess :cursor-col)))
          (is (= 11 (getf sess :cursor-row))))))))

(def-test handoff-imports-cursor-into-fresh-screen ()
  "import-state restores the cursor position into a freshly-rebuilt terminal --
the native in-heap handoff round-trip."
  (with-clean
    ;; Source terminal with a positioned cursor.
    (let ((screen-a (setup-terminal-with-screen :a :cols 80 :rows 24)))
      (lexter/model:set-cursor-position screen-a 5 3)
      (let ((state (impulse:export-state :lexter-host (origin:find-process "a"))))
        ;; A fresh terminal (cursor at origin) receives the state.
        (let ((screen-b (setup-terminal-with-screen :b :cols 80 :rows 24)))
          (is (= 0 (lexter/model:cursor-col screen-b)))
          (is-true (impulse:import-state :lexter-host (origin:find-process "b") state))
          (is (= 5 (lexter/model:cursor-col screen-b)))
          (is (= 3 (lexter/model:cursor-row screen-b))))))))

(def-test handoff-import-version-mismatch-is-safe ()
  "An incompatible handoff version is ignored (fail-safe) -- the cursor stays
at the fresh origin."
  (with-clean
    (let ((screen (setup-terminal-with-screen :bash :cols 80 :rows 24))
          (bad (impulse:make-handoff-state :lexter-host
                 '(:session (:cursor-col 9 :cursor-row 9)) :version 999)))
      (is-false (impulse:import-state :lexter-host (origin:find-process "bash") bad))
      (is (= 0 (lexter/model:cursor-col screen))))))

;;; -----------------------------------------------------------------------
;;; Runner
;;; -----------------------------------------------------------------------

(defun run-all-tests ()
  (run! 'lexter-impulse))
