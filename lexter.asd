(asdf:defsystem #:lexter
  :description "Lexter — Lisp-Emergent eXtensible Terminal Emulator Runtime"
  :license "BSD"
  :version "0.1.0"
  :depends-on ("cl-glfw3" "cl-opengl" "cffi" "alexandria" "babel" "chipz" "flexi-streams")
  :in-order-to ((asdf:test-op (asdf:test-op #:lexter/tests)))
  :serial t
  :components ((:file "src/packages")
               (:file "src/width-data")
               (:file "src/width")
               (:file "src/pcf")
               (:file "src/atlas")
               (:file "src/grid")
               (:file "src/swatches")
               (:file "src/shaders")
               (:file "src/renderer")
               (:file "src/gui")
               (:file "src/model")
               (:file "src/demo")))

;;; Unix terminal backend: the PTY and the VT handler (requires cl-vt). The
;;; standalone terminal, a compositor with one pane, is in lexter/panes
;;; (LEXTER-D67).
(asdf:defsystem #:lexter/unix
  :description "Unix terminal backend for Lexter: PTY and VT handler"
  :license "BSD"
  :version "0.1.0"
  :depends-on (#:lexter #:lexter/telnet #:cl-vt #:babel)
  :serial t
  :components ((:file "src/packages-unix")
               (:file "src/pty")
               (:file "src/vt-handler")))

;;; Screenshot-based test rig (raw-input recording + deterministic replay)
(asdf:defsystem #:lexter/test
  :description "Screenshot-based test rig for Lexter (record + replay + checksum)"
  :license "BSD"
  :version "0.1.0"
  :depends-on (#:lexter/panes #:cl-glfw3)
  :serial t
  :components ((:file "src/test-rig")))

;;; Pane multiplexer subsystem, and the standalone terminal built on it
(asdf:defsystem #:lexter/panes
  :description "Pane multiplexer for Lexter, and the standalone terminal"
  :license "BSD"
  :version "0.1.0"
  :depends-on (#:lexter/unix)
  :serial t
  :components ((:file "src/panes/packages")
               (:file "src/panes/protocol")
               (:file "src/panes/profile")
               (:file "src/panes/chrome-mixin")
               (:file "src/panes/vt-pane")
               (:file "src/panes/uterm-pane")
               (:file "src/panes/function-pane")
               (:file "src/panes/workspace")
               (:file "src/panes/compositor")
               (:file "src/packages-unix-term")
               (:file "src/unix-term")))

;;; Regression suite (Square: FiveAM + cl-hamcrest; headless, no GL or display).
;;; Reproduction tests fail until their repairs land
;;; (LEXTER-DRAFT-cell-model-revision-D21).
(asdf:defsystem #:lexter/tests
  :description "Regression suite for Lexter (FiveAM + cl-hamcrest), headless"
  :license "BSD"
  :version "0.1.0"
  :depends-on (#:lexter #:lexter/unix #:lexter/panes #:lexter/tn3270
               #:lexter/telnet-pane #:babel #:usocket #:sb-introspect #:sb-posix
               #:fiveam #:hamcrest/fiveam)
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "package")
                             (:file "helpers")
                             (:file "test-atlas")
                             (:file "test-handler")
                             (:file "test-model")
                             (:file "test-grid")
                             (:file "test-swatches")
                             (:file "test-structure")
                             (:file "test-tn3270")
                             (:file "test-telnet")
                             (:file "test-pty")
                             (:file "test-width")
                             (:file "test-profiles")
                             (:file "test-scrollback")
                             (:file "test-workspaces"))))
  :perform (asdf:test-op (o s)
             (uiop:symbol-call '#:lexter-tests '#:run-all-tests)))

;;; Mouse-reporting + routing unit tests (pure: no GL / display required).
;;; Predates the suite and uses its own check macro; moves into lexter/tests
;;; later (LEXTER-DRAFT-cell-model-revision-D21).
(asdf:defsystem #:lexter/mouse-tests
  :description "Unit tests for Lexter mouse reporting and pointer routing"
  :license "BSD"
  :version "0.1.0"
  :depends-on (#:lexter/panes)
  :serial t
  :components ((:file "tests/mouse-tests"))
  :perform (asdf:test-op (o s)
             (uiop:symbol-call :lexter/panes :run-all-tests)))

;;; TN3270 client library (standalone, no pane dependency)
(asdf:defsystem #:lexter/tn3270
  :description "TN3270/TN3270E client library for Lexter"
  :license "BSD"
  :version "0.1.0"
  :depends-on (#:usocket #:babel #:tacle.tn3270/lexicon #:specops.map.ebcdic)
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
  :depends-on ("lexter/panes" "origin" "impulse" "alexandria" "slynk")
  :serial t
  :components ((:file "src/packages-origin")
               (:file "src/origin")
               (:file "src/origin-gui")
               (:file "src/origin-image")
               (:file "src/origin-impulse")))

;;; Origin/Impulse integration tests (headless: fake cooperative executor,
;;; no display).
(asdf:defsystem #:lexter/origin-tests
  :description "Tests for the Lexter Origin/Impulse integration"
  :license "BSD"
  :depends-on ("lexter/origin" "hamcrest/fiveam")
  :serial t
  :components ((:file "tests/origin-impulse-tests"))
  :perform (asdf:test-op (o s)
             (uiop:symbol-call :lexter/origin-tests :run-all-tests)))
