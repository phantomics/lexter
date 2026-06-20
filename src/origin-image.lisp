;;;; origin-image.lisp
;;;;
;;;; Lexter/Origin image launcher: spawn a dedicated SBCL image (an :image
;;;; orbital) that runs Lexter on its own main thread, hosts one or more
;;;; cooperative windows via the cooperative dispatcher, and is interactive
;;;; via Slynk.
;;;;
;;;; The parent Origin treats the image as an :image orbital -- supervised
;;;; (crash detection, restart policy, backoff) exactly like any other
;;;; orbital.  The child image is a "smart" satellite: it runs its own local
;;;; Origin supervisor + cooperative dispatcher, so windows can be added and
;;;; removed within it at runtime.
;;;;
;;;; Usage:
;;;;
;;;;   ;; Author a config file, e.g. /path/my-image.lisp, containing:
;;;;   ;;   (in-package :lexter/origin)
;;;;   ;;   (define-terminal :bash "/bin/bash" :cols 80 :rows 24
;;;;   ;;                    :font-path "/path/terminus-18n.pcf")
;;;;
;;;;   ;; In the parent core:
;;;;   (lexter/origin:define-image :term-host :config "/path/my-image.lisp")
;;;;   (origin:start-supervisor)
;;;;   (origin:start :term-host)          ; spawns the child SBCL image
;;;;   (origin:info :term-host)           ; shows PID, status; Slynk port via
;;;;                                      ;   (lexter/origin:image-slynk-port :term-host)

(in-package #:lexter/origin)

(eval-when (:load-toplevel :execute)
  (require :sb-bsd-sockets))

;;; -----------------------------------------------------------------------
;;; Configuration
;;; -----------------------------------------------------------------------

(defvar *image-log-directory*
  (merge-pathnames "origin-logs/" (uiop:temporary-directory))
  "Directory for per-image log files.  Configurable per Origin instance.")

(defvar *image-metadata* (make-hash-table :test 'equal)
  "Canonical-name -> plist of (:slynk-port :log-file :config) for image orbitals.")

;;; -----------------------------------------------------------------------
;;; Port allocation
;;; -----------------------------------------------------------------------

(defun %free-port ()
  "Ask the OS for a free TCP port on the loopback interface.
Binds to port 0, reads the assigned port, and closes the socket.
There is a small TOCTOU window before the child binds it -- acceptable
for v1; explicit ports can be supplied to avoid it."
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket
                               :type :stream :protocol :tcp)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-bind socket #(127 0 0 1) 0)
           (nth-value 1 (sb-bsd-sockets:socket-name socket)))
      (sb-bsd-sockets:socket-close socket))))

;;; -----------------------------------------------------------------------
;;; Child argv construction
;;; -----------------------------------------------------------------------

(defun %build-child-argv (&key config slynk-port impulse-socket)
  "Build the argv list to spawn a Lexter child image.

Uses the running SBCL binary, a deterministic init (--no-userinit
--no-sysinit), loads Quicklisp, pushes the origin and lexter source
directories so the child can quickload lexter/origin regardless of its
registry configuration, then calls %CHILD-BOOT.  Each --eval form is
read only after the previous one is evaluated, so later forms may
reference packages loaded by earlier ones."
  (let ((sbcl       (namestring sb-ext:*runtime-pathname*))
        (origin-dir (namestring (asdf:system-source-directory "origin")))
        (lexter-dir (namestring (asdf:system-source-directory "lexter/origin")))
        (ql-setup   (namestring (merge-pathnames "quicklisp/setup.lisp"
                                                 (user-homedir-pathname)))))
    (list sbcl
          "--no-userinit" "--no-sysinit" "--non-interactive"
          "--eval" "(require :asdf)"
          "--eval" (format nil "(load ~S)" ql-setup)
          "--eval" (format nil "(push #P~S asdf:*central-registry*)" origin-dir)
          "--eval" (format nil "(push #P~S asdf:*central-registry*)" lexter-dir)
          "--eval" "(funcall (read-from-string \"ql:quickload\") \"lexter/origin\")"
          "--eval" (format nil "(funcall (read-from-string \"lexter/origin::%child-boot\") ~
                                  :config ~A :slynk-port ~D :impulse-socket ~A)"
                           (if config (prin1-to-string (namestring config)) "nil")
                           slynk-port
                           (if impulse-socket (prin1-to-string impulse-socket) "nil")))))

;;; -----------------------------------------------------------------------
;;; Parent-side: register an image orbital
;;; -----------------------------------------------------------------------

(defun %default-log-file (canonical-name)
  (merge-pathnames (format nil "~A.log" canonical-name) *image-log-directory*))

(defun %default-impulse-socket (canonical-name)
  (namestring
   (merge-pathnames (format nil "~A.impulse.sock" canonical-name)
                    *image-log-directory*)))

(defun define-image (name &key config slynk-port log-file impulse-socket
                            (restart-policy :transient)
                            (max-restarts 5)
                            description)
  "Register a dedicated Lexter image as an Origin :IMAGE orbital.

NAME is the orbital name (symbol or string).
CONFIG is a pathname/namestring of a Lisp config file the child loads to
declare its cooperative terminals (and any local setup).  May be NIL.
SLYNK-PORT is the port the child's Slynk server listens on; if NIL, a
free port is allocated and recorded.
IMPULSE-SOCKET is the Unix-socket path the child's Impulse listener binds;
if NIL, a default under *IMAGE-LOG-DIRECTORY* is used and recorded.
LOG-FILE is where the child's stdout/stderr are written; defaults to
<*image-log-directory*>/<name>.log.

The orbital is registered but not started.  Call (ORIGIN:START name) to
spawn the image, and (ORIGIN:STOP name) / (ORIGIN:KILL name) to tear it
down.  Restart policy and supervision behave as for any orbital.  Once
running, the image is reachable for structured control via Impulse at its
socket -- (impulse:connect (lexter/origin:impulse-socket-path name))."
  (let* ((canonical (%canonical-name name))
         (port (or slynk-port (%free-port)))
         (log  (or log-file (%default-log-file canonical)))
         (sock (or impulse-socket (%default-impulse-socket canonical)))
         (argv (%build-child-argv :config config :slynk-port port
                                  :impulse-socket sock)))
    (ensure-directories-exist log)
    (setf (gethash canonical *image-metadata*)
          (list :slynk-port port :log-file log :config config
                :impulse-socket sock))
    (origin:define-process name
      :execution-mode :image
      :image-command argv
      :image-output log
      :image-error log
      :restart-policy restart-policy
      :max-restarts max-restarts
      :description (or description
                       (format nil "Lexter image (Slynk ~D)" port)))))

(defun image-slynk-port (name)
  "Return the Slynk port assigned to image orbital NAME, or NIL."
  (getf (gethash (%canonical-name name) *image-metadata*) :slynk-port))

(defun image-log-file (name)
  "Return the log-file pathname for image orbital NAME, or NIL."
  (getf (gethash (%canonical-name name) *image-metadata*) :log-file))

(defun impulse-socket-path (name)
  "Return the Impulse Unix-socket path for image orbital NAME, or NIL."
  (getf (gethash (%canonical-name name) *image-metadata*) :impulse-socket))

;;; -----------------------------------------------------------------------
;;; Config generation stub
;;; -----------------------------------------------------------------------

(defun generate-orbital-config (&rest keyword-args)
  "Stub: a future version will generate an image config Lisp file from
KEYWORD-ARGS (terminals, fonts, ports, etc.) and return its pathname.
Currently a no-op placeholder that reserves the API and returns NIL."
  (declare (ignore keyword-args))
  nil)

;;; -----------------------------------------------------------------------
;;; Child-side: boot recipe (runs inside the spawned image)
;;; -----------------------------------------------------------------------

(defun %child-boot (&key config slynk-port impulse-socket)
  "Boot recipe executed inside a spawned Lexter image.

Starts a Slynk server for human interactivity and an Impulse listener for
structured control, starts this image's own local Origin supervisor, loads
the user CONFIG (which declares cooperative terminals), then enters the
cooperative main loop -- autostarting every cooperative orbital the config
registered.  Blocks the image's main thread for its lifetime; Slynk and
Impulse each run on their own threads."
  (when slynk-port
    (funcall (read-from-string "slynk:create-server")
             :port slynk-port :dont-close t))
  (when impulse-socket
    (impulse:start-listener :path impulse-socket
                            :tier impulse:+tier-read-write+))
  (origin:start-supervisor)
  (when config
    (load config))
  (let ((names (loop for o in (origin:orbit)
                     when (eq :cooperative (origin:process-execution-mode o))
                       collect (origin:process-name o))))
    (run-main-loop :autostart names)))
