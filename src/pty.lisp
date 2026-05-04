(in-package #:lexter/pty)

;;;; PTY (pseudo-terminal) bindings for Unix.
;;;;
;;;; Provides CFFI bindings to forkpty/openpty and related functions
;;;; for spawning child processes with a controlling terminal.

;;; --------------------------------------------------------------------------
;;; CFFI foreign types and constants
;;; --------------------------------------------------------------------------

(cffi:define-foreign-library libutil
  (:unix "libutil.so")
  (t (:default "libutil")))

(cffi:define-foreign-library libc
  (:unix "libc.so.6")
  (t (:default "libc")))

;; Load libraries (libutil contains forkpty/openpty on Linux)
(cffi:use-foreign-library libc)
(handler-case
    (cffi:use-foreign-library libutil)
  (error () nil))  ; libutil may not be needed on some systems

;; termios structure (simplified - we only need size for winsize)
(cffi:defcstruct winsize
  (ws-row    :unsigned-short)
  (ws-col    :unsigned-short)
  (ws-xpixel :unsigned-short)
  (ws-ypixel :unsigned-short))

;; ioctl requests (Linux values)
(defconstant +TIOCSWINSZ+ #x5414)
(defconstant +TIOCGWINSZ+ #x5413)

;; fcntl constants
(defconstant +F-GETFL+ 3)
(defconstant +F-SETFL+ 4)
(defconstant +O-NONBLOCK+ #o4000)

;; poll constants
(defconstant +POLLIN+  #x0001)
(defconstant +POLLOUT+ #x0004)
(defconstant +POLLERR+ #x0008)
(defconstant +POLLHUP+ #x0010)

(cffi:defcstruct pollfd
  (fd      :int)
  (events  :short)
  (revents :short))

;;; --------------------------------------------------------------------------
;;; Foreign function declarations
;;; --------------------------------------------------------------------------

(cffi:defcfun ("forkpty" %forkpty) :int
  (amaster :pointer)    ; int *amaster
  (name    :pointer)    ; char *name (can be NULL)
  (termp   :pointer)    ; struct termios *termp (can be NULL)
  (winp    :pointer))   ; struct winsize *winp (can be NULL)

(cffi:defcfun ("close" %close) :int
  (fd :int))

(cffi:defcfun ("read" %read) :long
  (fd  :int)
  (buf :pointer)
  (count :unsigned-long))

(cffi:defcfun ("write" %write) :long
  (fd  :int)
  (buf :pointer)
  (count :unsigned-long))

(cffi:defcfun ("ioctl" %ioctl) :int
  (fd :int)
  (request :unsigned-long)
  &rest)

(cffi:defcfun ("fcntl" %fcntl) :int
  (fd :int)
  (cmd :int)
  &rest)

(cffi:defcfun ("poll" %poll) :int
  (fds :pointer)
  (nfds :unsigned-long)
  (timeout :int))

(cffi:defcfun ("waitpid" %waitpid) :int
  (pid :int)
  (status :pointer)
  (options :int))

(cffi:defcfun ("kill" %kill) :int
  (pid :int)
  (sig :int))

(cffi:defcfun ("execvp" %execvp) :int
  (file :string)
  (argv :pointer))

(cffi:defcfun ("_exit" %exit) :void
  (status :int))

(cffi:defcfun ("setsid" %setsid) :int)

(cffi:defcfun ("strerror" %strerror) :string
  (errnum :int))

(cffi:defcvar ("errno" %errno) :int)

;;; --------------------------------------------------------------------------
;;; PTY structure
;;; --------------------------------------------------------------------------

(defstruct pty
  "Pseudo-terminal connection to a child process."
  (master-fd  -1  :type fixnum)
  (slave-name ""  :type string)
  (child-pid  -1  :type fixnum)
  (alive-p    nil :type boolean))

;;; --------------------------------------------------------------------------
;;; PTY operations
;;; --------------------------------------------------------------------------

(defun pty-fork (command &key (cols 80) (rows 24) args)
  "Fork a child process running COMMAND with a PTY.
   ARGS is a list of string arguments (not including the command itself).
   Returns a PTY struct on success."
  (cffi:with-foreign-objects ((master-fd :int)
                              (winsize '(:struct winsize)))
    ;; Set up window size
    (cffi:with-foreign-slots ((ws-row ws-col ws-xpixel ws-ypixel)
                              winsize (:struct winsize))
      (setf ws-row rows
            ws-col cols
            ws-xpixel 0
            ws-ypixel 0))
    ;; Fork with PTY
    (let ((pid (%forkpty master-fd (cffi:null-pointer)
                         (cffi:null-pointer) winsize)))
      (cond
        ((< pid 0)
         (error "forkpty failed: ~a" (%strerror %errno)))
        ((= pid 0)
         ;; Child process
         (%child-exec command args))
        (t
         ;; Parent process
         (make-pty :master-fd (cffi:mem-ref master-fd :int)
                   :slave-name ""
                   :child-pid pid
                   :alive-p t))))))

(defun %child-exec (command args)
  "Execute command in child process. Does not return."
  ;; Build argv array: [command, ...args, NULL]
  (let* ((all-args (cons command args))
         (argc (length all-args)))
    (cffi:with-foreign-object (argv :pointer (1+ argc))
      (loop :for arg :in all-args
            :for i :from 0
            :do (setf (cffi:mem-aref argv :pointer i)
                      (cffi:foreign-string-alloc arg)))
      (setf (cffi:mem-aref argv :pointer argc) (cffi:null-pointer))
      ;; Set up environment variables for terminal
      (cffi:foreign-funcall "setenv" :string "TERM" :string "xterm-256color" :int 1 :int)
      ;; Execute
      (%execvp command argv)
      ;; If we get here, exec failed
      (%exit 127))))

(defun pty-close (pty)
  "Close the PTY and terminate the child process if still running."
  (when (pty-alive-p pty)
    ;; Try to kill child gracefully
    (%kill (pty-child-pid pty) 15)  ; SIGTERM
    ;; Close master fd
    (%close (pty-master-fd pty))
    (setf (pty-alive-p pty) nil
          (pty-master-fd pty) -1)))

(defun pty-set-nonblocking (pty)
  "Set the PTY master fd to non-blocking mode."
  (let* ((fd (pty-master-fd pty))
         (flags (%fcntl fd +F-GETFL+)))
    (when (< flags 0)
      (error "fcntl F_GETFL failed: ~a" (%strerror %errno)))
    (when (< (%fcntl fd +F-SETFL+ :int (logior flags +O-NONBLOCK+)) 0)
      (error "fcntl F_SETFL failed: ~a" (%strerror %errno)))))

(defun pty-set-size (pty cols rows)
  "Set the PTY window size. Sends SIGWINCH to child."
  (cffi:with-foreign-object (ws '(:struct winsize))
    (cffi:with-foreign-slots ((ws-row ws-col ws-xpixel ws-ypixel)
                              ws (:struct winsize))
      (setf ws-row rows
            ws-col cols
            ws-xpixel 0
            ws-ypixel 0))
    (let ((result (%ioctl (pty-master-fd pty) +TIOCSWINSZ+ :pointer ws)))
      (when (< result 0)
        (error "ioctl TIOCSWINSZ failed: ~a" (%strerror %errno))))))

;;; --------------------------------------------------------------------------
;;; PTY I/O
;;; --------------------------------------------------------------------------

(defun pty-read (pty buffer &key (start 0) (end nil))
  "Read available data from PTY into BUFFER (a (unsigned-byte 8) array).
   Returns the number of bytes read, 0 if nothing available (non-blocking),
   or -1 if the PTY is closed/EOF."
  (let* ((end (or end (length buffer)))
         (count (- end start)))
    (cffi:with-pointer-to-vector-data (ptr buffer)
      (let ((n (%read (pty-master-fd pty)
                      (cffi:inc-pointer ptr start)
                      count)))
        (cond
          ((> n 0) n)
          ((= n 0)
           ;; EOF - child closed
           (setf (pty-alive-p pty) nil)
           -1)
          (t
           ;; Error - check if it's just EAGAIN/EWOULDBLOCK
           (if (member %errno '(11 35))  ; EAGAIN=11 (Linux), EWOULDBLOCK=35 (macOS)
               0
               (progn
                 (setf (pty-alive-p pty) nil)
                 -1))))))))

(defun pty-write (pty buffer &key (start 0) (end nil))
  "Write data from BUFFER to PTY.
   Returns the number of bytes written."
  (let* ((end (or end (length buffer)))
         (count (- end start)))
    (cffi:with-pointer-to-vector-data (ptr buffer)
      (let ((n (%write (pty-master-fd pty)
                       (cffi:inc-pointer ptr start)
                       count)))
        (if (< n 0)
            (error "write failed: ~a" (%strerror %errno))
            n)))))

(defun pty-write-string (pty string)
  "Write STRING to PTY as UTF-8 bytes."
  (let ((bytes (babel:string-to-octets string :encoding :utf-8)))
    (pty-write pty bytes)))

;;; --------------------------------------------------------------------------
;;; Polling
;;; --------------------------------------------------------------------------

(defun pty-poll (pty timeout-ms)
  "Poll PTY for readable data.
   TIMEOUT-MS: milliseconds to wait (-1 for infinite, 0 for immediate).
   Returns :readable if data is available, :closed if PTY closed, :timeout otherwise."
  (cffi:with-foreign-object (pfd '(:struct pollfd))
    (cffi:with-foreign-slots ((fd events revents) pfd (:struct pollfd))
      (setf fd (pty-master-fd pty)
            events +POLLIN+
            revents 0))
    (let ((result (%poll pfd 1 timeout-ms)))
      (cond
        ((< result 0)
         (if (= %errno 4)  ; EINTR
             :timeout
             (error "poll failed: ~a" (%strerror %errno))))
        ((= result 0)
         :timeout)
        (t
         (let ((revents (cffi:foreign-slot-value pfd '(:struct pollfd) 'revents)))
           (cond
             ((logtest revents (logior +POLLERR+ +POLLHUP+))
              (setf (pty-alive-p pty) nil)
              :closed)
             ((logtest revents +POLLIN+)
              :readable)
             (t :timeout))))))))

(defun pty-check-child (pty)
  "Check if child process is still running. Updates pty-alive-p.
   Returns T if child is alive, NIL otherwise."
  (when (pty-alive-p pty)
    (cffi:with-foreign-object (status :int)
      (let ((result (%waitpid (pty-child-pid pty) status 1)))  ; WNOHANG=1
        (cond
          ((= result 0)
           ;; Child still running
           t)
          ((> result 0)
           ;; Child exited
           (setf (pty-alive-p pty) nil)
           nil)
          (t
           ;; Error
           (setf (pty-alive-p pty) nil)
           nil))))))
