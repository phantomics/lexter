(asdf:defsystem #:lexter
  :description "Lexter — Lisp-Emergent eXtensible Terminal Emulator Runtime"
  :license "BSD"
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
  :license "BSD"
  :version "0.1.0"
  :depends-on (#:lexter #:lexter/telnet #:cl-vt #:babel)
  :serial t
  :components ((:file "src/packages-unix")
               (:file "src/pty")
               (:file "src/vt-handler")
               (:file "src/unix-term")))

;;; Pane multiplexer subsystem
(asdf:defsystem #:lexter/panes
  :description "Pane multiplexer for Lexter"
  :license "BSD"
  :version "0.1.0"
  :depends-on (#:lexter/unix)
  :serial t
  :components ((:file "src/panes/packages")
               (:file "src/panes/protocol")
               (:file "src/panes/chrome-mixin")
               (:file "src/panes/vt-pane")
               (:file "src/panes/uterm-pane")
               (:file "src/panes/function-pane")
               (:file "src/panes/workspace")
               (:file "src/panes/compositor")))

;;; TN3270 client library (standalone, no pane dependency)
(asdf:defsystem #:lexter/tn3270
  :description "TN3270/TN3270E client library for Lexter"
  :license "BSD"
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
  :license "BSD"
  :version "0.1.0"
  :depends-on (#:lexter/panes #:lexter/tn3270)
  :serial t
  :components ((:file "src/tn3270-pane/packages")
               (:file "src/tn3270-pane/tn3270-pane")))

;;; Telnet client library (standalone, no pane dependency)
(asdf:defsystem #:lexter/telnet
  :description "Telnet client library for Lexter"
  :license "BSD"
  :version "0.1.0"
  :depends-on (#:usocket)
  :serial t
  :components ((:file "src/telnet/packages")
               (:file "src/telnet/cp437")
               (:file "src/telnet/client")))

;;; Telnet pane (requires panes and telnet systems)
(asdf:defsystem #:lexter/telnet-pane
  :description "Telnet/raw TCP pane for Lexter"
  :license "BSD"
  :version "0.1.0"
  :depends-on (#:lexter/panes #:lexter/telnet)
  :serial t
  :components ((:file "src/telnet-pane/packages")
               (:file "src/telnet-pane/telnet-pane")))

;;; PBM bitmap font loader (for CP437 DOS fonts)
(asdf:defsystem #:lexter/pbm
  :description "PBM bitmap font loader for Lexter"
  :license "BSD"
  :version "0.1.0"
  :depends-on (#:lexter #:lexter/telnet #:cl-netpbm)
  :serial t
  :components ((:file "src/pbm")))

;;; Origin process manager integration
(asdf:defsystem #:lexter/origin
  :description "Origin process manager integration for Lexter"
  :license "BSD"
  :version "0.1.0"
  :depends-on ("lexter/unix" "origin" "alexandria")
  :serial t
  :components ((:file "src/origin")))
