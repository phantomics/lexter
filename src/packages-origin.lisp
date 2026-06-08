
;;; ---------------------------------------------------------------------------
;;; Origin process management integration system
;;; ---------------------------------------------------------------------------

(defpackage #:lexter/origin
  (:use #:cl #:lexter/pcf #:lexter/atlas #:lexter/grid #:lexter/renderer #:alexandria #:origin)
  (:export ;; Terminal definition
           #:define-terminal))
