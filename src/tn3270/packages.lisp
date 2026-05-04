;;;; Package definitions for TN3270 client library.

(defpackage #:pcf-gl/tn3270
  (:use #:cl #:tacle/tn3270.lexicon)
  (:export
   ;; Buffer address codec
   #:encode-buffer-address
   #:decode-buffer-address
   ;; Client
   #:tn3270-client
   #:make-tn3270-client
   #:client-connect
   #:client-disconnect
   #:client-connected-p
   #:client-poll
   #:client-send-aid
   ;; Screen model
   #:tn3270-screen
   #:make-tn3270-screen
   #:screen-cols
   #:screen-rows
   #:screen-buffer
   #:screen-attributes
   #:screen-cursor-address
   #:screen-field-at
   #:screen-get-char
   #:screen-put-char
   #:screen-clear
   #:screen-set-cursor
   #:screen-cursor-up
   #:screen-cursor-down
   #:screen-cursor-left
   #:screen-cursor-right
   ;; Field access
   #:field-start
   #:field-end
   #:field-length
   #:field-protected-p
   #:field-numeric-p
   #:field-modified-p
   #:field-contents
   ;; Parser
   #:process-3270-stream))
