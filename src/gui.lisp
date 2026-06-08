(in-package #:lexter/gui)

;;;; GUI iteration protocol: a steppable window lifecycle.
;;;;
;;;; A "GUI object" owns a GLFW window plus its OpenGL context and is advanced
;;;; one frame at a time by GUI-TICK. The blocking loop does not live inside the
;;;; object -- it lives in the dispatcher (RUN-GUI-LOOP). Because each tick makes
;;;; its own context current before touching GL, a single main thread can service
;;;; several windows by polling GLFW once and ticking each object in turn.
;;;;
;;;; Lexter remains single-threaded: all of an object's work (I/O, parsing,
;;;; rendering) happens on the dispatcher's thread, in the same call stack, once
;;;; per tick. The only thing hoisted out of the object is the loop itself.
;;;;
;;;; GLFW initialization and termination are owned by the *caller* of
;;;; RUN-GUI-LOOP (the standalone entry-point wrappers today; an Origin
;;;; main-thread dispatcher later), never by individual objects. The dispatcher
;;;; assumes GLFW is already initialized and every object already GUI-INITIALIZEd.

;;; --------------------------------------------------------------------------
;;; Protocol
;;; --------------------------------------------------------------------------

(defgeneric gui-initialize (object)
  (:documentation
   "Create OBJECT's GLFW window, OpenGL context, and rendering/backend resources,
    and register its input callbacks. Must run on the main thread, after
    GLFW has been initialized. GLFW-CREATE-WINDOW makes the new window's context
    current, so any GL resources created here belong to that context.
    Returns OBJECT."))

(defgeneric gui-tick (object)
  (:documentation
   "Advance OBJECT by exactly one frame. Makes OBJECT's GL context current,
    processes its pending I/O, and renders if anything is dirty. Does NOT call
    GLFW:POLL-EVENTS -- the dispatcher polls once for all windows before ticking.
    Returns a generalized boolean: true if OBJECT is still alive, NIL if it has
    finished and should be destroyed."))

(defgeneric gui-destroy (object)
  (:documentation
   "Release every resource owned by OBJECT, including its GLFW window. Must be
    idempotent: after the first call (which clears the window slot) further calls
    are no-ops. Runs on the main thread."))

(defgeneric gui-window (object)
  (:documentation
   "Return OBJECT's GLFW window handle, or NIL if it has not been initialized or
    has already been destroyed."))

(defgeneric gui-alive-p (object)
  (:documentation
   "Return true if OBJECT still has a live window/session."))

;;; --------------------------------------------------------------------------
;;; Dispatcher
;;; --------------------------------------------------------------------------

(defun run-gui-loop (objects &key stop-flag)
  "Main-thread dispatcher for a set of GUI OBJECTS.

OBJECTS is a list of already-GUI-INITIALIZEd objects. Each iteration polls GLFW
once (servicing every window's callbacks), then ticks every live object in turn.
An object whose GUI-TICK returns NIL is GUI-DESTROYed and dropped from the active
set. The loop returns when no live objects remain, or when STOP-FLAG -- a list
whose CAR is checked each iteration -- has a NIL car. The list of survivors (live
objects still present when a STOP-FLAG stop occurred) is returned so the caller
can tear them down.

This function assumes GLFW:INITIALIZE has already been called and does NOT call
GLFW:TERMINATE; GLFW lifetime is the caller's responsibility."
  (let ((live (copy-list objects)))
    (loop :while (and live
                      (or (null stop-flag) (car stop-flag)))
          :do (glfw:poll-events)
              (setf live
                    (loop :for obj :in live
                          :if (gui-tick obj)
                            :collect obj
                          :else
                            :do (gui-destroy obj)))
              ;; Small sleep to avoid burning CPU when idle.
              (sleep 0.001))
    live))
