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
