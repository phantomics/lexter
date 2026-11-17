;;;; Pane profiles: typed settings, inherited through parent profiles and then
;;;; through containment (LEXTER-DRAFT-pane-profiles-D1 to -D4).
;;;;
;;;; A setting is a slot of a profile class; an unbound slot means "not set
;;;; here, inherit". Every pane, workspace, and compositor owns a private
;;;; profile, empty until written, whose PARENT may name a shared profile. A
;;;; pane's setting is looked up in its profile and that profile's parents, then
;;;; in its workspace's, then in the compositor's, and finally in the default
;;;; the setting declares. A profile class that lacks a setting is skipped, so a
;;;; subclass of PANE-PROFILE can add settings of its own.

(in-package #:lexter/panes)

;;; --------------------------------------------------------------------------
;;; The registry of settings
;;; --------------------------------------------------------------------------

(defvar *pane-settings* (make-hash-table :test 'eq)
  "Each setting's name, a symbol, mapped to a plist of its :TYPE and :DEFAULT.")

(defun %setting-spec (setting)
  "The plist of SETTING's type and default; signals an error if it is unknown."
  (or (gethash setting *pane-settings*)
      (error "~S is not a pane-profile setting." setting)))

;;; --------------------------------------------------------------------------
;;; Lookup in a profile and its parents
;;; --------------------------------------------------------------------------

(defun %profile-chain-value (profile setting)
  "Look SETTING up in PROFILE and its chain of parents. Returns the value and
T when a profile in the chain sets it, or NIL and NIL. Profiles whose class
lacks the setting are passed over."
  (loop :for p = profile :then (profile-parent p)
        :while p
        :when (and (slot-exists-p p setting) (slot-boundp p setting))
          :do (return-from %profile-chain-value (values (slot-value p setting) t)))
  (values nil nil))

(defun %write-profile-setting (profile setting value)
  "Set SETTING in PROFILE itself to VALUE, after checking VALUE against the
setting's declared type. Returns VALUE."
  (let ((type (getf (%setting-spec setting) :type)))
    (unless (typep value type)
      (error 'type-error :datum value :expected-type type))
    (unless (slot-exists-p profile setting)
      (error "A profile of class ~S has no setting ~S."
             (class-name (class-of profile)) setting))
    (setf (slot-value profile setting) value)))

(defun resolve-pane-setting (pane setting)
  "The value of SETTING for PANE: from PANE's profile chain, then its
workspace's, then its compositor's, and otherwise the setting's default."
  (flet ((try (profile)
           (when profile
             (multiple-value-bind (value found) (%profile-chain-value profile setting)
               (when found
                 (return-from resolve-pane-setting value))))))
    (try (pane-profile pane))
    (let ((ws (pane-workspace pane)))
      (when ws
        (try (workspace-profile ws))
        (let ((comp (workspace-compositor ws)))
          (when comp
            (try (compositor-profile comp))))))
    (getf (%setting-spec setting) :default)))

(defgeneric own-profile (object)
  (:documentation "The private profile of OBJECT: a pane's, a workspace's, or a
compositor's own profile, or a profile itself."))

(defmethod own-profile ((pane pane))
  (pane-profile pane))

(defun unset-setting (object setting)
  "Remove SETTING from the private profile of OBJECT, a pane, workspace,
compositor, or profile, so that it inherits the setting again. Returns OBJECT."
  (%setting-spec setting)
  (let ((profile (own-profile object)))
    (when (slot-exists-p profile setting)
      (slot-makunbound profile setting)))
  object)

;;; --------------------------------------------------------------------------
;;; Defining profile classes and their settings
;;; --------------------------------------------------------------------------

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %setting-function-name (prefix setting)
    "The symbol PREFIX-SETTING, interned in SETTING's package."
    (intern (format nil "~A-~A" prefix (symbol-name setting)) (symbol-package setting))))

(defmacro define-pane-profile (name superclasses settings)
  "Define the profile class NAME, a subclass of SUPERCLASSES (PANE-PROFILE's
own definition names none, and gains the PARENT slot), with SETTINGS, each
(SETTING &key TYPE DEFAULT DOCUMENTATION).

For each setting this defines the slot, with no initform, so that an unbound
slot means \"inherit\", and an initarg of the setting's name as a keyword;
records the type and default; and defines readers and writers:

  PANE-SETTING          a generic reader on panes, whose default method
                        resolves the setting through profiles and containment
  (SETF PANE-SETTING)   writes the pane's private profile
  WORKSPACE-SETTING, COMPOSITOR-SETTING, PROFILE-SETTING, and their SETF
                        forms, which read the value set at that level or in
                        its parents (with a second value T when one is set),
                        and write that level's own profile

Writers check the value against the setting's type."
  (let ((slot-forms '())
        (definitions '()))
    (dolist (spec settings)
      (destructuring-bind (setting &key (type t) default documentation) spec
        (let ((pane-reader (%setting-function-name "PANE" setting))
              (ws-reader (%setting-function-name "WORKSPACE" setting))
              (comp-reader (%setting-function-name "COMPOSITOR" setting))
              (profile-reader (%setting-function-name "PROFILE" setting)))
          (push `(,setting :initarg ,(intern (symbol-name setting) :keyword)
                           ,@(when documentation `(:documentation ,documentation)))
                slot-forms)
          (push `(progn
                   (setf (gethash ',setting *pane-settings*)
                         (list :type ',type :default ,default))
                   (defgeneric ,pane-reader (pane)
                     (:documentation ,(format nil "The pane's ~(~A~) setting~@[: ~A~]"
                                              setting documentation)))
                   (defmethod ,pane-reader ((pane pane))
                     (resolve-pane-setting pane ',setting))
                   (defun (setf ,pane-reader) (value pane)
                     (%write-profile-setting (pane-profile pane) ',setting value))
                   (defun ,ws-reader (workspace)
                     (%profile-chain-value (workspace-profile workspace) ',setting))
                   (defun (setf ,ws-reader) (value workspace)
                     (%write-profile-setting (workspace-profile workspace) ',setting value))
                   (defun ,comp-reader (compositor)
                     (%profile-chain-value (compositor-profile compositor) ',setting))
                   (defun (setf ,comp-reader) (value compositor)
                     (%write-profile-setting (compositor-profile compositor) ',setting value))
                   (defun ,profile-reader (profile)
                     (%profile-chain-value profile ',setting))
                   (defun (setf ,profile-reader) (value profile)
                     (%write-profile-setting profile ',setting value)))
                definitions))))
    `(progn
       (defclass ,name ,superclasses
         (,@(unless superclasses
              '((parent :initarg :parent :initform nil :accessor profile-parent
                        :documentation "A profile to inherit unset settings from, or NIL.")))
          ,@(nreverse slot-forms))
         (:documentation ,(format nil "Pane profile class ~(~A~)." name)))
       ,@(nreverse definitions)
       ',name)))

;;; --------------------------------------------------------------------------
;;; Lexter's settings
;;; --------------------------------------------------------------------------

(define-pane-profile pane-profile ()
  ((wheel-scroll-lines :type (integer 1) :default 3
                       :documentation "Lines scrolled per wheel notch.")
   (snap-on-input      :type boolean :default t
                       :documentation "Typing returns the view to the live screen.")
   (snap-on-output     :type boolean :default nil
                       :documentation "Output returns the view to the live screen.")))

(defmethod own-profile ((profile pane-profile))
  profile)

;;; --------------------------------------------------------------------------
;;; Private profiles of panes
;;; --------------------------------------------------------------------------

(defmethod initialize-instance :after ((pane pane) &key profile-parent)
  "Give PANE's private profile PROFILE-PARENT as its parent, when one is given."
  (when profile-parent
    (setf (profile-parent (pane-profile pane)) profile-parent)))
