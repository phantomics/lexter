(pushnew (truename "/home/sloane/src/chat/pcf-gl/") asdf:*central-registry* :test #'equal)
(ql:quickload :pcf-gl :silent t)
(in-package :pcf-gl/demo)

(let* ((font   (load-pcf "/home/sloane/src/chat/terminus-18n.pcf"))
       (cell-w (pcf-font-cell-width  font))
       (cell-h (pcf-font-cell-height font))
       (cols   40) (rows 10)
       (win-w  (* cols cell-w))
       (win-h  (* rows cell-h)))
  (glfw:with-init-window
      (:title "pcf-gl demo" :width win-w :height win-h
       :resizable nil :context-version-major 3
       :context-version-minor 3
       :opengl-profile :opengl-core-profile
       :opengl-forward-compat t)
    (gl:viewport 0 0 win-w win-h)
    (let* ((atlas (build-atlas (list font)))
           (grid  (make-terminal-grid :cols cols :rows rows))
           (rs    (make-renderer atlas win-w win-h))
           (pal   (make-xterm-palette)))
      (set-palette rs pal)
      (setup-demo-grid grid atlas)
      (render-frame rs grid)
      (glfw:swap-buffers)
      (glfw:poll-events)
      (sleep 0.3)
      ;; Read pixels and write PPM (GL origin is bottom-left, flip for PPM)
      (let* ((pixels (gl:read-pixels 0 0 win-w win-h :rgb :unsigned-byte))
             (path   "/tmp/pcf-gl-demo.ppm"))
        (with-open-file (f path :direction :output
                               :element-type '(unsigned-byte 8)
                               :if-exists :supersede)
          (loop for c across (format nil "P6~%~d ~d~%255~%" win-w win-h)
                do (write-byte (char-code c) f))
          (loop :for row :from (1- win-h) :downto 0
                :do (loop :for col :from 0 :below win-w
                          :for base = (* (+ (* row win-w) col) 3)
                          :do (write-byte (aref pixels base)       f)
                              (write-byte (aref pixels (+ base 1)) f)
                              (write-byte (aref pixels (+ base 2)) f))))
        (format t "~&Saved ~a~%" path))
      (destroy-renderer rs))))
