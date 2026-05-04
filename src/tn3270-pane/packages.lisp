;;;; Package definitions for TN3270 pane.

(defpackage #:pcf-gl/tn3270-pane
  (:use #:cl)
  (:export
   #:tn3270-pane
   #:tn3270-pane-host
   #:tn3270-pane-port
   #:tn3270-pane-client
   #:tn3270-pane-connected-p))
