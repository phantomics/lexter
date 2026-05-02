(asdf:defsystem #:pcf-gl
  :description "Pixel font GPU terminal renderer — proof of concept"
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
(asdf:defsystem #:pcf-gl/unix
  :description "Unix terminal backend for pcf-gl"
  :version "0.1.0"
  :depends-on (#:pcf-gl #:cl-vt #:babel)
  :serial t
  :components ((:file "src/packages-unix")
               (:file "src/pty")
               (:file "src/vt-handler")
               (:file "src/unix-term")))
