;;;; Telnet client package definition

(defpackage #:lexter/telnet
  (:use #:cl)
  (:export
   ;; Telnet client
   #:telnet-client
   #:make-telnet-client
   #:telnet-connect
   #:telnet-disconnect
   #:telnet-connected-p
   #:telnet-read
   #:telnet-write
   #:telnet-write-string
   #:telnet-send-naws
   ;; Client accessors
   #:telnet-client-host
   #:telnet-client-port
   #:telnet-client-mode
   #:telnet-client-ttype
   ;; CP437 encoding table
   #:+cp437-to-unicode+))
