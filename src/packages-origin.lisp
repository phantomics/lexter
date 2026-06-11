
;;; ---------------------------------------------------------------------------
;;; Origin process management integration system
;;; ---------------------------------------------------------------------------

(defpackage #:lexter/origin
  (:use #:cl #:alexandria)
  (:export ;; Terminal definition (Approach B -- cooperative main-thread)
           #:define-terminal
           ;; Main-thread dispatcher
           #:run-main-loop
           #:stop-main-loop))
