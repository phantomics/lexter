(asdf:defsystem #:pcf-gl
  :description "Pixel font GPU terminal renderer — proof of concept"
  :version "0.1.0"
  :depends-on (#:cl-glfw3 #:cl-opengl #:cffi #:alexandria)
  :serial t
  :components ((:file "src/packages")
               (:file "src/pcf")
               (:file "src/atlas")
               (:file "src/grid")
               (:file "src/shaders")
               (:file "src/renderer")
               (:file "src/demo")))
