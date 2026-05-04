(asdf:defsystem #:lexter
  :description "Lexter — Lisp-Emergent eXtensible Terminal Emulator Runtime"
  :version "0.1.0"
  :depends-on (#:cl-glfw3 #:cl-opengl #:cffi #:alexandria #:babel)
  :serial t
  :components ((:file "src/packages")
               (:file "src/pcf")
               (:file "src/atlas")
               (:file "src/grid")
               (:file "src/shaders")
               (:file "src/renderer")
               (:file "src/model")
               (:file "src/demo")))

;;; Unix terminal subsystem (requires cl-vt)
(asdf:defsystem #:lexter/unix
  :description "Unix terminal backend for Lexter"
  :version "0.1.0"
  :depends-on (#:lexter #:cl-vt #:babel)
  :serial t
  :components ((:file "src/packages-unix")
               (:file "src/pty")
               (:file "src/vt-handler")
               (:file "src/unix-term")))

;;; Pane multiplexer subsystem
(asdf:defsystem #:lexter/panes
  :description "Pane multiplexer for Lexter"
  :version "0.1.0"
  :depends-on (#:lexter/unix)
  :serial t
  :components ((:file "src/panes/packages")
               (:file "src/panes/protocol")
               (:file "src/panes/uterm-pane")
               (:file "src/panes/function-pane")
               (:file "src/panes/workspace")
               (:file "src/panes/compositor")))

;;; TN3270 client library (standalone, no pane dependency)
(asdf:defsystem #:lexter/tn3270
  :description "TN3270/TN3270E client library for Lexter"
  :version "0.1.0"
  :depends-on (#:usocket #:babel #:tacle.tn3270/lexicon #:specops/format.ebcdic)
  :serial t
  :components ((:file "src/tn3270/packages")
               (:file "src/tn3270/codec")
               (:file "src/tn3270/screen")
               (:file "src/tn3270/parser")
               (:file "src/tn3270/client")))

;;; TN3270 pane (requires panes system)
(asdf:defsystem #:lexter/tn3270-pane
  :description "TN3270 pane for Lexter"
  :version "0.1.0"
  :depends-on (#:lexter/panes #:lexter/tn3270)
  :serial t
  :components ((:file "src/tn3270-pane/packages")
               (:file "src/tn3270-pane/tn3270-pane")))
