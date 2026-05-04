;;;; Telnet pane package definition

(defpackage #:lexter/telnet-pane
  (:use #:cl)
  (:export
   ;; Telnet pane class
   #:telnet-pane
   #:telnet-pane-host
   #:telnet-pane-port
   #:telnet-pane-mode
   #:telnet-pane-encoding
   #:telnet-pane-ttype
   #:telnet-pane-client
   ;; Constructor helper
   #:make-telnet-pane))
