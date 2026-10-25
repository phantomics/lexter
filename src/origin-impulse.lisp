;;;; origin-impulse.lisp
;;;;
;;;; Phase 7 of the Impulse project: the :LEXTER-HOST control sub-vocabulary.
;;;;
;;;; This is the first *typed* Impulse sub-vocabulary -- the proof of the
;;;; extension pattern the universal verbs were built for. A Lexter terminal
;;;; orbital (a :COOPERATIVE process driven by the main-thread GUI dispatcher)
;;;; is tagged with the :LEXTER-HOST control type, and this file gives that type
;;;;
;;;;   - typed STATUS query leaves: the window's geometry, title, liveness,
;;;;     scrollback depth, cursor, and child PID, on top of the universal
;;;;     status fields;
;;;;   - CONFIGURE/APPLY parameters (cols, rows, pixel-scale, font, title), via
;;;;     VALIDATE-SPEC / COMMIT-SPEC methods specialized on :LEXTER-HOST;
;;;;   - a DESCRIBE surface, advertised automatically from the registered
;;;;     query/config schemas.
;;;;
;;;; Main-thread affinity is free: IMPULSE's dispatcher marshals every handler
;;;; for a :COOPERATIVE orbital onto the executor (main) thread via the mailbox,
;;;; so a status read or a configure that touches GL/terminal state runs where
;;;; it is safe to, with no code here.

#|

---------------------------------------------------------------------------
REPL examples
---------------------------------------------------------------------------

Assume a running Lexter terminal orbital, defined and started under the
main-thread dispatcher:

  (lexter/origin:define-terminal :bash "/bin/bash" :cols 80 :rows 24
                                 :font-path "~/src/chat/terminus-18n.pcf")
  (origin:start-supervisor)
  (lexter/origin:run-main-loop :autostart '(:bash))   ; blocks the main thread

The examples below run from another thread -- a Slynk REPL in the same
image, or, for a Lexter *image* orbital, the parent core over the Impulse
socket. Every call returns a response datum; IMPULSE:RESPONSE-RESULT pulls
the payload out of an (:OK :RESULT ... ) reply.

--- STATUS: observed state, universal + typed window fields ---------------

  (impulse:request :bash :status)
  ;; => (:OK :RESULT (:NAME "bash" :STATUS :RUNNING :EXECUTION-MODE :COOPERATIVE
  ;;                  :ALIVE T :READY T ... :HEALTH (:ALIVE T :READY T :STARTED T)
  ;;                  :COLS 80 :ROWS 24 :PIXEL-SCALE 1 :TITLE "lexter terminal"
  ;;                  :WINDOW-ALIVE T :SCROLLBACK-LINES 142
  ;;                  :CURSOR (:COL 12 :ROW 7) :PID 48213) :ID NIL)

  (impulse:with-connection (s (lexter/origin:impulse-socket-path :lexter-image)
                              :tier impulse:+tier-read-write+)
    (impulse:session-request s "bash" :status :query '(:cols :rows :cursor)))

  ;; Narrow to chosen leaves (GraphQL-style field selection):
  (impulse:response-result
    (impulse:request :bash :status :query '(:cols :rows :scrollback-lines :cursor)))
  ;; => (:COLS 80 :ROWS 24 :SCROLLBACK-LINES 142 :CURSOR (:COL 12 :ROW 7))

  ;; Other strata of the same verb: declared spec, or the dependency topology:
  (impulse:request :bash :status :args '(:view :spec))
  (impulse:request :bash :status :args '(:view :topology))

--- DESCRIBE: discover the :LEXTER-HOST surface --------------------------

  (impulse:response-result (impulse:request :bash :describe))
  ;; => (:ORBITAL "bash" :CONTROL-TYPE :LEXTER-HOST
  ;;     :VERBS ((:VERB :DESCRIBE :EFFECT :SAFE ...) (:VERB :CONFIGURE ...) ...)
  ;;     :QUERIES ((:VERB :STATUS :LEAVES ((:COLS :TYPE :INTEGER :ACCESS :READ-ONLY)
  ;;                                       (:SCROLLBACK-LINES ...) (:CURSOR ...) ...)))
  ;;     :CONFIG-SCHEMA ((:COLS :TYPE :INTEGER :ACCESS :READ-WRITE)
  ;;                     (:ROWS ...) (:PIXEL-SCALE ...) (:FONT-PATH ...) (:TITLE ...))
  ;;     :HANDOFF (:APPLICATION :SESSION) :SUB-VOCABULARIES NIL)
  ;;
  ;; A tool renders an inspector/editor from this -- no Lexter-specific
  ;; knowledge baked in.

--- CONFIGURE / APPLY: set window parameters ----------------------------

  ;; CONFIGURE -- an immediate, validated, idempotent parameter set. Live-
  ;; settable knobs (title, pixel-scale) take effect now; geometry/font are
  ;; written to the rebuild spec and applied on the next restart.
  (impulse:request :bash :configure :args '(:pixel-scale 2 :title "shell"))
  ;; => (:OK :RESULT (:NAME "bash" :COMMITTED T :SPEC (... :PIXEL-SCALE 2 ...)) ...)

  ;; APPLY -- the declarative desired-state verb. :DRY-RUN validates and
  ;; reports without mutating:
  (impulse:request :bash :apply :args '(:spec (:cols 120 :rows 40) :dry-run t))
  ;; => (:OK :RESULT (:NAME "bash" :VALID T :DRY-RUN T :SPEC (... :COLS 120 ...)) ...)

  ;; Commit it (geometry change applies on the next restart):
  (impulse:request :bash :apply :args '(:spec (:cols 120 :rows 40)))

  ;; An invalid parameter comes back as a structured error, not a crash:
  (impulse:request :bash :configure :args '(:cols -5))
  ;; => (:ERROR :CONDITION (:TYPE :INVALID-SPEC :KEY :COLS :VALUE -5
  ;;                        :REASON "must be a positive integer") :ID NIL)

--- Over the Impulse socket (a Lexter image orbital from the parent) -----

  (impulse:with-connection (s "/run/origin/lexter.sock"
                              :tier impulse:+tier-read-write+)
    (impulse:session-request s "bash" :status :query '(:cols :rows :cursor)))

--- Fleet addressing (every terminal at once) ---------------------------

  (impulse:request :all :status :query '(:title :scrollback-lines))
  (impulse:request '(:where (:eq :app :terminal)) :configure :args '(:pixel-scale 2))

|#

(in-package #:lexter/origin)

;;; -----------------------------------------------------------------------
;;; Schema registration (DESCRIBE renders these automatically)
;;; -----------------------------------------------------------------------

(impulse:register-query-schema :lexter-host :status
  (append (impulse:generic-status-schema)
          '((:command          :type (:or :string :null)  :access :read-only)
            (:cols             :type :integer             :access :read-only)
            (:rows             :type :integer             :access :read-only)
            (:pixel-scale      :type :integer             :access :read-only)
            (:title            :type :string              :access :read-only)
            (:window-alive     :type :boolean             :access :read-only)
            (:scrollback-lines :type (:or :integer :null) :access :read-only)
            (:cursor           :type (:or :plist :null)   :access :read-only)
            (:pid              :type (:or :integer :null) :access :read-only))))

(impulse:register-config-schema :lexter-host
  (append (impulse:generic-config-schema)
          '((:cols        :type :integer :access :read-write)
            (:rows        :type :integer :access :read-write)
            (:pixel-scale :type :integer :access :read-write)
            (:font-path   :type :string  :access :read-write)
            (:title       :type :string  :access :read-write))))

;;; -----------------------------------------------------------------------
;;; Window field extraction
;;; -----------------------------------------------------------------------

(defun %live-terminal (orbital)
  "The live UNIX-TERMINAL object for ORBITAL, or NIL if it is not running."
  (cdr (assoc (origin:process-name orbital) *gui-objects* :test #'equal)))

(defun %window-fields (orbital)
  "The :LEXTER-HOST window status fields for ORBITAL: drawn from the live
terminal when one is running, else from its stored build spec (so a stopped
terminal still reports its declared geometry)."
  (let ((term (%live-terminal orbital)))
    (if term
        (let ((screen (lexter/unix-term::unix-terminal-screen term))
              (pty    (lexter/unix-term::unix-terminal-pty term)))
          (list :command          (lexter/unix-term::unix-terminal-command term)
                :cols             (lexter/unix-term::unix-terminal-cols term)
                :rows             (lexter/unix-term::unix-terminal-rows term)
                :pixel-scale      (lexter/unix-term::unix-terminal-pixel-scale term)
                :title            (lexter/unix-term::unix-terminal-title term)
                :window-alive     (and (lexter/gui:gui-alive-p term) t)
                :scrollback-lines (and screen (lexter/model:scrollback-lines screen))
                :cursor           (and screen (list :col (lexter/model:cursor-col screen)
                                                    :row (lexter/model:cursor-row screen)))
                :pid              (and pty (lexter/pty:pty-child-pid pty))))
        (let ((spec (gethash (origin:process-name orbital) *terminal-specs*)))
          (list :command          (getf spec :command)
                :cols             (or (getf spec :cols) 80)
                :rows             (or (getf spec :rows) 24)
                :pixel-scale      (or (getf spec :pixel-scale) 1)
                :title            (or (getf spec :title) "lexter terminal")
                :window-alive     nil
                :scrollback-lines nil
                :cursor           nil
                :pid              nil)))))

(defun %base-status-fields (orbital)
  "The universal observed-status plist (process-info plus the health triple),
as IMPULSE's generic :STATUS produces before query narrowing."
  (append (origin:process-info orbital)
          (list :health (impulse:orbital-health orbital))))

;;; -----------------------------------------------------------------------
;;; :STATUS -- universal fields plus the typed window fields
;;; -----------------------------------------------------------------------

(impulse:define-control-handler (:lexter-host :status) (orbital request)
  ;; The default :STATUS view augments the universal observed fields with the
  ;; Lexter window fields, honoring GraphQL-style :QUERY narrowing across both.
  ;; The other views (:spec / :both / :topology) are unchanged from generic.
  (let ((view  (or (getf (impulse:request-args request) :view) :status))
        (query (impulse:request-query request)))
    (if (eq view :status)
        (let ((info (append (%base-status-fields orbital) (%window-fields orbital))))
          (if query
              (loop for field in query append (list field (getf info field)))
              info))
        (impulse:status-view orbital view query))))

;;; -----------------------------------------------------------------------
;;; CONFIGURE / APPLY -- validate and commit the window parameters
;;; -----------------------------------------------------------------------
;;;
;;; The generic CONFIGURE/APPLY handlers route through VALIDATE-SPEC /
;;; COMMIT-SPEC keyed on the orbital's control type, so specializing those two
;;; on :LEXTER-HOST is all that is needed -- no extra verb handler.

(defparameter *lexter-config-keys* '(:cols :rows :pixel-scale :font-path :title)
  "The configurable parameters owned by the :LEXTER-HOST sub-vocabulary; any
other key is a universal knob handled by the :GENERIC methods.")

(defun %partition-spec (spec)
  "Split SPEC into (VALUES LEXTER-PLIST GENERIC-PLIST) by *LEXTER-CONFIG-KEYS*,
preserving key/value order in each."
  (let ((lex '()) (gen '()))
    (loop for (k v) on spec by #'cddr do
      (if (member k *lexter-config-keys*)
          (setf lex (append lex (list k v)))
          (setf gen (append gen (list k v)))))
    (values lex gen)))

(defmethod impulse:validate-spec ((type (eql :lexter-host)) orbital spec)
  (multiple-value-bind (lex gen) (%partition-spec spec)
    (loop for (k v) on lex by #'cddr do
      (flet ((bad (reason) (error 'impulse:invalid-spec :key k :value v :reason reason)))
        (case k
          ((:cols :rows :pixel-scale)
           (unless (and (integerp v) (plusp v)) (bad "must be a positive integer")))
          (:title     (unless (stringp v) (bad "must be a string")))
          (:font-path (unless (stringp v) (bad "must be a string"))))))
    ;; The universal knobs are validated by the generic method.
    (impulse:validate-spec :generic orbital gen))
  nil)

(defun %set-spec-key (name key val)
  "Persist KEY=VAL into NAME's stored terminal build spec, so a restart rebuilds
the terminal with the new value."
  (let ((spec (gethash name *terminal-specs*)))
    (when spec
      (setf (getf spec key) val
            (gethash name *terminal-specs*) spec))))

(defmethod impulse:commit-spec ((type (eql :lexter-host)) orbital spec)
  (multiple-value-bind (lex gen) (%partition-spec spec)
    (let ((name (origin:process-name orbital))
          (term (%live-terminal orbital)))
      (loop for (k v) on lex by #'cddr do
        ;; Persist into the rebuild spec for restart-time application.
        (%set-spec-key name k v)
        ;; Live-apply the parameters that need no window rebuild; :cols/:rows/
        ;; :font-path take effect on the next restart (spec already updated).
        (when term
          (case k
            (:title       (setf (lexter/unix-term::unix-terminal-title term) v))
            (:pixel-scale (setf (lexter/unix-term::unix-terminal-pixel-scale term) v))))))
    (impulse:commit-spec :generic orbital gen))
  spec)

;;; -----------------------------------------------------------------------
;;; Restart state handoff (Phase 9): a native, in-heap example
;;; -----------------------------------------------------------------------
;;;
;;; nginx (a foreign orbital) hands off nothing; a Lexter terminal is the
;;; native counterpart whose precious state is application data in the heap, not
;;; kernel FDs -- so the Tether serializes the data. The MVP carries the
;;; terminal's geometry and scrollback depth (:application) and its cursor
;;; position (:session) across a clean restart. Import is fail-safe: it only
;;; restores the cursor into an already-rebuilt screen, so a fresh window always
;;; comes up regardless.

(defmethod impulse:export-state ((type (eql :lexter-host)) orbital)
  (let ((term (%live-terminal orbital)))
    (when term
      (let ((screen (lexter/unix-term::unix-terminal-screen term)))
        (impulse:make-handoff-state :lexter-host
          (append
           (list :application
                 (list :cols (lexter/unix-term::unix-terminal-cols term)
                       :rows (lexter/unix-term::unix-terminal-rows term)
                       :scrollback-lines (if screen
                                             (lexter/model:scrollback-lines screen)
                                             0)))
           (when screen
             (list :session
                   (list :cursor-col (lexter/model:cursor-col screen)
                         :cursor-row (lexter/model:cursor-row screen))))))))))

(defmethod impulse:import-state ((type (eql :lexter-host)) orbital state)
  (when (impulse:handoff-compatible-p state)
    (let ((term (%live-terminal orbital))
          (session (impulse:handoff-stratum state :session)))
      (when (and term session)
        (let ((screen (lexter/unix-term::unix-terminal-screen term)))
          (when screen
            (lexter/model:set-cursor-position screen
                                              (getf session :cursor-col)
                                              (getf session :cursor-row))
            t))))))

(defmethod impulse:handoff-strata-for ((type (eql :lexter-host)))
  '(:application :session))
