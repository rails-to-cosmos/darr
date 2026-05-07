;;; darr.el --- Visual layout editor for displays  -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Dmitry Akatov
;; Author: Dmitry Akatov <dmitry.akatov@protonmail.com>
;; URL: https://github.com/rails-to-cosmos/darr
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: hardware, multimedia

;;; Commentary:
;;
;; Buffer-based interactive editor for display configuration.
;; Currently shells out to xrandr/autorandr (X11); Wayland support is on
;; the roadmap.  No native code; pure Elisp.
;;
;; Usage:
;;   M-x darr            open the layout buffer (alias for darr-show)
;;
;; Inside the *Displays* buffer:
;;   n / p     next / previous display
;;   h j k l   move selected display left/down/up/right relative to neighbor
;;   r / R     cycle resolution forward / backward
;;   F         cycle refresh rate
;;   o         cycle rotation (normal / left / inverted / right)
;;   P         mark as primary
;;   d         disable display
;;   e         enable display
;;   C-c C-c   apply with xrandr
;;   C-c C-s   save current as autorandr profile
;;   C-c C-l   load autorandr profile
;;   C-c C-d   delete saved autorandr profile
;;   g         refresh from xrandr

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup darr nil
  "Visual layout editor for displays."
  :group 'hardware
  :prefix "darr-")

(defcustom darr-xrandr-command "xrandr"
  "Path to the xrandr binary."
  :type 'string
  :group 'darr)

(defcustom darr-autorandr-command "autorandr"
  "Path to the autorandr binary."
  :type 'string
  :group 'darr)

(defcustom darr-buffer-name "*Displays*"
  "Name of the displays layout buffer."
  :type 'string
  :group 'darr)

(defcustom darr-canvas-width 60
  "Width (in characters) of the layout minimap drawn above the rows."
  :type 'integer
  :group 'darr)

(defcustom darr-on-connect-hook nil
  "Hook run when a new display is connected.
Each function is called with the output name."
  :type 'hook
  :group 'darr)

(defcustom darr-on-disconnect-hook nil
  "Hook run when a display is disconnected."
  :type 'hook
  :group 'darr)

;;; Faces

(defface darr-box
  '((t :inherit default :box (:line-width 1)))
  "Face for the display rectangle."
  :group 'darr)

(defface darr-primary
  '((t :inherit success :weight bold))
  "Face for the primary marker."
  :group 'darr)

(defface darr-disabled
  '((t :inherit shadow :strike-through t))
  "Face for disabled displays."
  :group 'darr)

(defface darr-name
  '((t :inherit font-lock-keyword-face))
  "Face for the output name."
  :group 'darr)

(defface darr-resolution
  '((t :inherit font-lock-string-face))
  "Face for the resolution string."
  :group 'darr)

(defface darr-selected
  '((t :inherit highlight :weight bold :extend t))
  "Face applied to the line of the currently-selected display."
  :group 'darr)

;;; Data model

(cl-defstruct darr-output
  name              ; "eDP-1"
  connected         ; t / nil
  enabled           ; t / nil  (disabled means --off)
  primary           ; t / nil
  geometry          ; (X Y W H)
  rotation          ; 'normal / 'left / 'right / 'inverted
  current-mode      ; "2160x1350"
  current-rate      ; 60.0 (Hz)
  modes)            ; alist: ("2160x1350" . (60.0 59.93)) - rates per mode

(defvar darr--state nil
  "List of `darr-output' structs reflecting current xrandr query.")

(defvar darr--dirty nil
  "Non-nil when in-buffer state diverges from applied state.")

;;; xrandr parsing

(defun darr--call (program &rest args)
  "Run PROGRAM with ARGS, return stdout as string. Errors signal.
Refuses to even try if PROGRAM isn't on `exec-path' so the failure
mode is a clear `user-error' rather than an opaque `call-process'
crash."
  (unless (executable-find program)
    (user-error
     "%s not found in `exec-path' — install it (or set `darr-%s-command')"
     program
     (cond ((string= program "xrandr")    "xrandr")
           ((string= program "autorandr") "autorandr")
           (t program))))
  (with-temp-buffer
    (let ((exit (apply #'call-process program nil t nil args)))
      (unless (zerop exit)
        (error "%s %s failed (%d): %s"
               program (string-join args " ") exit (buffer-string)))
      (buffer-string))))

(defun darr--parse-xrandr (text)
  "Parse `xrandr --query` TEXT into list of `darr-output'."
  (let ((outputs nil)
        (current nil))
    (dolist (line (split-string text "\n"))
      (cond
       ;; Output header: "eDP-1 connected primary 2160x1350+0+0 ..."
       ((string-match
         (concat "^\\([A-Za-z0-9-]+\\) +"
                 "\\(connected\\|disconnected\\)"
                 "\\(?: +primary\\)?"
                 "\\(?: +\\([0-9]+\\)x\\([0-9]+\\)\\+\\([0-9]+\\)\\+\\([0-9]+\\)\\)?"
                 "\\(?: +\\(normal\\|left\\|right\\|inverted\\)\\)?")
         line)
        (when current (push current outputs))
        (let* ((primary-p (string-match-p " primary " line))
               (rotation (and (match-string 7 line)
                              (intern (match-string 7 line))))
               (w (and (match-string 3 line) (string-to-number (match-string 3 line))))
               (h (and (match-string 4 line) (string-to-number (match-string 4 line))))
               (x (and (match-string 5 line) (string-to-number (match-string 5 line))))
               (y (and (match-string 6 line) (string-to-number (match-string 6 line)))))
          (setq current
                (make-darr-output
                 :name (match-string 1 line)
                 :connected (string= (match-string 2 line) "connected")
                 :enabled (and w h)
                 :primary primary-p
                 :geometry (and w h (list x y w h))
                 :rotation (or rotation 'normal)
                 :current-mode (and w h (format "%dx%d" w h))
                 :modes nil))))
       ;; Mode line: "   2160x1350    60.00*+  59.93"
       ((and current
             (string-match "^ +\\([0-9]+x[0-9]+\\) +\\(.*\\)$" line))
        (let ((mode (match-string 1 line))
              (rates-str (match-string 2 line))
              (rates nil))
          (dolist (token (split-string rates-str))
            (when (string-match "^\\([0-9.]+\\)\\([*+]*\\)$" token)
              (let ((rate (string-to-number (match-string 1 token)))
                    (flags (match-string 2 token)))
                (push rate rates)
                (when (string-match-p "\\*" flags)
                  (setf (darr-output-current-rate current) rate)))))
          (push (cons mode (nreverse rates))
                (darr-output-modes current))))))
    (when current (push current outputs))
    ;; Modes were collected with `push' so each output's mode list is in
    ;; reverse source order; flip back so cycle-resolution visits the
    ;; preferred mode first (xrandr lists preferred first).
    (dolist (o outputs)
      (setf (darr-output-modes o) (nreverse (darr-output-modes o))))
    (nreverse outputs)))

(defun darr-refresh ()
  "Re-query xrandr and update internal state."
  (interactive)
  (setq darr--state (darr--parse-xrandr
                         (darr--call darr-xrandr-command "--query")))
  (setq darr--dirty nil)
  (when (get-buffer darr-buffer-name)
    (darr--render)))

;;; Buffer rendering

(defvar darr-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m "n" #'darr-next)
    (define-key m "p" #'darr-prev)
    (define-key m "g" #'darr-refresh)
    (define-key m "h" #'darr-move-left)
    (define-key m "j" #'darr-move-down)
    (define-key m "k" #'darr-move-up)
    (define-key m "l" #'darr-move-right)
    (define-key m "r" #'darr-cycle-resolution)
    (define-key m "R" #'darr-cycle-resolution-prev)
    (define-key m "o" #'darr-cycle-rotation)
    (define-key m "F" #'darr-cycle-rate)
    (define-key m "P" #'darr-toggle-primary)
    (define-key m "d" #'darr-disable)
    (define-key m "e" #'darr-enable)
    (define-key m (kbd "C-c C-c") #'darr-apply)
    (define-key m (kbd "C-c C-s") #'darr-save-profile)
    (define-key m (kbd "C-c C-l") #'darr-load-profile)
    (define-key m (kbd "C-c C-d") #'darr-delete-profile)
    (define-key m "?" #'darr-help)
    m)
  "Keymap for `darr-mode'.")

(define-derived-mode darr-mode special-mode "Displays"
  "Major mode for editing X display layout."
  (setq-local truncate-lines t
              cursor-type nil)
  (read-only-mode 1))

(defvar-local darr--selected nil
  "Name of currently selected output in the buffer.")

(defun darr--render-minimap ()
  "Insert a scaled 2D minimap of enabled displays' relative positions.
Selected display's box is highlighted; others share the regular name face.
No-op when there's nothing enabled with geometry."
  (let ((enabled (cl-remove-if-not
                  (lambda (o) (and (darr-output-enabled o)
                                   (darr-output-geometry o)))
                  darr--state)))
    (when enabled
      (let* ((geoms (mapcar #'darr-output-geometry enabled))
             (min-x (apply #'min (mapcar (lambda (g) (nth 0 g)) geoms)))
             (min-y (apply #'min (mapcar (lambda (g) (nth 1 g)) geoms)))
             (max-x (apply #'max (mapcar (lambda (g) (+ (nth 0 g) (nth 2 g))) geoms)))
             (max-y (apply #'max (mapcar (lambda (g) (+ (nth 1 g) (nth 3 g))) geoms)))
             (canvas-w (max 16 darr-canvas-width))
             ;; Char cells are roughly 2:1 (h:w); scale Y by 0.5 so the
             ;; rendered aspect ratio matches the physical one.
             (scale (/ (float canvas-w) (max 1 (- max-x min-x))))
             (canvas-h (max 3 (ceiling (* (- max-y min-y) scale 0.5))))
             (grid (apply #'vector
                          (cl-loop repeat canvas-h
                                   collect (make-vector canvas-w ?\s))))
             (rects nil))
        (cl-flet ((put-c (x y c)
                         (when (and (<= 0 x) (< x canvas-w)
                                    (<= 0 y) (< y canvas-h))
                           (aset (aref grid y) x c))))
          (dolist (out enabled)
            (let* ((g (darr-output-geometry out))
                   (gx (nth 0 g)) (gy (nth 1 g))
                   (gw (nth 2 g)) (gh (nth 3 g))
                   (x0 (round (* (- gx min-x) scale)))
                   (y0 (round (* (- gy min-y) scale 0.5)))
                   (x1 (1- (max (+ x0 2)
                                (round (* (- (+ gx gw) min-x) scale)))))
                   (y1 (1- (max (+ y0 2)
                                (round (* (- (+ gy gh) min-y) scale 0.5))))))
              (setq x0 (max 0 (min (1- canvas-w) x0))
                    y0 (max 0 (min (1- canvas-h) y0))
                    x1 (max x0 (min (1- canvas-w) x1))
                    y1 (max y0 (min (1- canvas-h) y1)))
              (push (list out x0 y0 x1 y1) rects)
              (cl-loop for x from x0 to x1 do
                       (put-c x y0 ?─) (put-c x y1 ?─))
              (cl-loop for y from y0 to y1 do
                       (put-c x0 y ?│) (put-c x1 y ?│))
              (put-c x0 y0 ?┌) (put-c x1 y0 ?┐)
              (put-c x0 y1 ?└) (put-c x1 y1 ?┘)
              (let* ((label (darr-output-name out))
                     (mid-y (/ (+ y0 y1) 2))
                     (avail (max 0 (1- (- x1 x0))))
                     (lab (substring label 0 (min (length label) avail)))
                     (lab-x (max (1+ x0)
                                 (- (/ (+ x0 x1 1) 2) (/ (length lab) 2)))))
                (cl-loop for i from 0 below (length lab) do
                         (put-c (+ lab-x i) mid-y (aref lab i)))))))
        (let ((canvas-start (point)))
          (cl-loop for row across grid do
                   (insert (apply #'string (append row nil)) "\n"))
          (dolist (entry rects)
            (cl-destructuring-bind (out x0 y0 x1 y1) entry
              (let ((face (if (string= (darr-output-name out)
                                       darr--selected)
                              'darr-selected
                            'darr-name)))
                (cl-loop for row from y0 to y1 do
                         (let* ((line-bol (+ canvas-start
                                             (* row (1+ canvas-w))))
                                (a (+ line-bol x0))
                                (b (+ line-bol (1+ x1))))
                           (add-face-text-property a b face)))))))
        (insert "\n")))))

(defun darr--render ()
  "Render `darr--state' into the layout buffer."
  (with-current-buffer (get-buffer-create darr-buffer-name)
    (unless (derived-mode-p 'darr-mode)
      (darr-mode))
    (darr--ensure-selected)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize "Displays" 'face 'bold)
              (if darr--dirty
                  (propertize "  [unapplied]" 'face 'warning)
                "")
              "\n\n")
      (darr--render-minimap)
      (dolist (out darr--state)
        (darr--render-output out)
        (insert "\n"))
      (insert "\n"
              (propertize
               (concat "n/p select  •  hjkl move  •  r/R res  F rate  o rotate"
                       "  •  P primary  d disable  e enable\n"
                       "C-c C-c apply  •  C-c C-s save  •  C-c C-l load  •  C-c C-d delete  •  g refresh  •  ? help\n")
               'face 'shadow)))
    (darr--goto-selected)))

(defun darr--render-output (out)
  "Render a single OUTPUT struct as a labeled row."
  (let* ((selected (string= (darr-output-name out) darr--selected))
         (sigil    (if selected "* " "  "))
         (name     (darr-output-name out))
         (conn     (darr-output-connected out))
         (enabled  (darr-output-enabled out))
         (primary  (darr-output-primary out))
         (mode     (darr-output-current-mode out))
         (rate     (darr-output-current-rate out))
         (rot      (darr-output-rotation out))
         (geom     (darr-output-geometry out))
         (start    (point)))
    (insert sigil)
    (insert (propertize name 'face
                        (cond ((not conn) 'darr-disabled)
                              ((not enabled) 'shadow)
                              (t 'darr-name))))
    (insert "  ")
    (cond
     ((not conn)
      (insert (propertize "(disconnected)" 'face 'shadow)))
     ((not enabled)
      (insert (propertize "(off)" 'face 'shadow)))
     (t
      (insert (propertize (or mode "?") 'face 'darr-resolution))
      (when rate
        (insert (format " @ %.0fHz" rate)))
      (when (and geom (not (eq rot 'normal)))
        (insert (format "  %s" rot)))
      (when geom
        (insert (format "  +%d+%d" (nth 0 geom) (nth 1 geom))))
      (when primary
        (insert "  ")
        (insert (propertize "★ primary" 'face 'darr-primary)))))
    (put-text-property start (line-end-position) 'darr-output name)
    (when selected
      ;; Extend through the trailing newline so the highlight spans the
      ;; whole row, not just the printed glyphs.
      (add-face-text-property start (min (point-max) (1+ (line-end-position)))
                              'darr-selected))))

;;; Selection

(defun darr--find (name)
  "Return the `darr-output' struct named NAME or nil."
  (cl-find name darr--state
           :key #'darr-output-name :test #'string=))

(defun darr--connected-names ()
  (mapcar #'darr-output-name
          (cl-remove-if-not #'darr-output-connected darr--state)))

(defun darr--all-names ()
  (mapcar #'darr-output-name darr--state))

(defun darr--ensure-selected ()
  (unless (and darr--selected (darr--find darr--selected))
    (setq darr--selected
          (or (car (darr--connected-names))
              (car (darr--all-names))))))

(defun darr--goto-selected ()
  "Move point onto the line of the currently-selected output."
  (goto-char (point-min))
  (let ((found
         (catch 'found
           (while (not (eobp))
             (when (equal (get-text-property (point) 'darr-output)
                          darr--selected)
               (throw 'found t))
             (forward-line 1)))))
    (unless found (goto-char (point-min)))))

(defun darr-next ()
  "Select the next display (wraps; cycles through all outputs)."
  (interactive)
  (let* ((names (darr--all-names))
         (idx (cl-position darr--selected names :test #'string=)))
    (setq darr--selected
          (nth (mod (1+ (or idx -1)) (length names)) names))
    (darr--render)))

(defun darr-prev ()
  "Select the previous display (wraps; cycles through all outputs)."
  (interactive)
  (let* ((names (darr--all-names))
         (idx (cl-position darr--selected names :test #'string=)))
    (setq darr--selected
          (nth (mod (1- (or idx 1)) (length names)) names))
    (darr--render)))

;;; Mutations

(defun darr--current (&optional action)
  "Return the currently-selected `darr-output' struct.
If ACTION is non-nil, also signal a friendly `user-error' when the
selected display is disconnected (so commands that don't make sense on
absent hardware fail quietly instead of crashing).  ACTION is the verb
shown in the message, e.g. \"cycle resolution\"."
  (darr--ensure-selected)
  (let ((cur (or (darr--find darr--selected)
                 (user-error "No display selected"))))
    (when (and action (not (darr-output-connected cur)))
      (user-error "Cannot %s — %s is disconnected"
                  action (darr-output-name cur)))
    cur))

(defun darr--mark-dirty ()
  (setq darr--dirty t)
  (darr--render))

(defun darr-toggle-primary ()
  "Toggle primary flag on the selected display."
  (interactive)
  (let ((cur (darr--current "mark primary")))
    (dolist (out darr--state)
      (setf (darr-output-primary out) nil))
    (setf (darr-output-primary cur) t)
    (darr--mark-dirty)))

(defun darr-disable ()
  "Disable the selected display (--off on apply)."
  (interactive)
  (setf (darr-output-enabled (darr--current "disable")) nil)
  (darr--mark-dirty))

(defun darr-enable ()
  "Enable the selected display (--auto on apply).
If the display has no current mode/rate/geometry (e.g. it was --off, or
just plugged in), seed sensible defaults: first available mode + rate,
and place it to the right of the rightmost enabled display."
  (interactive)
  (let ((cur (darr--current "enable")))
    (setf (darr-output-enabled cur) t)
    (unless (darr-output-current-mode cur)
      (when-let* ((modes (darr-output-modes cur))
                  (preferred (car modes)))
        (setf (darr-output-current-mode cur) (car preferred))
        (setf (darr-output-current-rate cur) (car (cdr preferred)))))
    (unless (darr-output-geometry cur)
      (let* ((mode (darr-output-current-mode cur))
             (dims (and mode (split-string mode "x")))
             (w (or (and dims (string-to-number (nth 0 dims))) 1920))
             (h (or (and dims (string-to-number (nth 1 dims))) 1080))
             (others (cl-remove cur (cl-remove-if-not
                                     #'darr-output-enabled
                                     darr--state)))
             (max-x (apply #'max 0
                           (mapcar (lambda (o)
                                     (let ((g (darr-output-geometry o)))
                                       (if g
                                           (+ (nth 0 g) (nth 2 g))
                                         0)))
                                   others))))
        (setf (darr-output-geometry cur) (list max-x 0 w h))))
    (darr--mark-dirty)))

(defun darr-cycle-rotation ()
  "Cycle rotation: normal -> left -> inverted -> right -> normal."
  (interactive)
  (let* ((cur (darr--current "cycle rotation"))
         (cycle '(normal left inverted right))
         (next (or (cadr (memq (darr-output-rotation cur) cycle))
                   (car cycle))))
    (setf (darr-output-rotation cur) next)
    (darr--mark-dirty)))

(defun darr--cycle-resolution-by (direction)
  "Move the selected display's mode forward (DIRECTION +1) or back (-1)."
  (let* ((cur (darr--current "cycle resolution"))
         (modes (mapcar #'car (darr-output-modes cur))))
    (unless modes (user-error "No modes available for %s"
                              (darr-output-name cur)))
    (let* ((idx (cl-position (darr-output-current-mode cur) modes
                             :test #'string=))
           (next (nth (mod (+ (or idx 0) direction) (length modes)) modes)))
      (setf (darr-output-current-mode cur) next)
      (darr--mark-dirty))))

(defun darr-cycle-resolution ()
  "Cycle the selected display's resolution forward (preferred-first order)."
  (interactive)
  (darr--cycle-resolution-by +1))

(defun darr-cycle-resolution-prev ()
  "Cycle the selected display's resolution backward."
  (interactive)
  (darr--cycle-resolution-by -1))

(defun darr-cycle-rate ()
  "Cycle the refresh rate within the current resolution."
  (interactive)
  (let* ((cur (darr--current "cycle refresh rate"))
         (mode (darr-output-current-mode cur))
         (rates (cdr (assoc mode (darr-output-modes cur)))))
    (unless rates
      (user-error "No refresh rates known for %s — is the display enabled?"
                  (darr-output-name cur)))
    (let* ((idx (cl-position (darr-output-current-rate cur) rates))
           (next (nth (mod (1+ (or idx -1)) (length rates)) rates)))
      (setf (darr-output-current-rate cur) next)
      (darr--mark-dirty))))

(defun darr--move (dir)
  "Move selected display relative to neighbor in DIR ('left/'right/'up/'down)."
  (let* ((cur (darr--current "move"))
         (others (cl-remove cur darr--state))
         (anchor (car (cl-remove-if-not #'darr-output-enabled others))))
    (unless (darr-output-geometry cur)
      (user-error "Cannot move %s — display is not enabled (no geometry)"
                  (darr-output-name cur)))
    (unless anchor
      (user-error "No other enabled display to position relative to"))
    (let* ((g (darr-output-geometry anchor))
           (ax (nth 0 g)) (ay (nth 1 g))
           (aw (nth 2 g)) (ah (nth 3 g))
           (cw (nth 2 (darr-output-geometry cur)))
           (ch (nth 3 (darr-output-geometry cur)))
           (nx ax) (ny ay))
      (pcase dir
        ('right (setq nx (+ ax aw) ny ay))
        ('left  (setq nx (- ax cw) ny ay))
        ('down  (setq nx ax ny (+ ay ah)))
        ('up    (setq nx ax ny (- ay ch))))
      (setf (darr-output-geometry cur) (list nx ny cw ch)))
    (darr--mark-dirty)))

(defun darr-move-left ()  (interactive) (darr--move 'left))
(defun darr-move-right () (interactive) (darr--move 'right))
(defun darr-move-up ()    (interactive) (darr--move 'up))
(defun darr-move-down ()  (interactive) (darr--move 'down))

;;; Apply via xrandr

(defun darr--xrandr-args ()
  "Build xrandr command-line arguments from current state."
  (let (args)
    (dolist (out darr--state)
      (when (darr-output-connected out)
        (let ((name (darr-output-name out)))
          (push "--output" args)
          (push name args)
          (cond
           ((not (darr-output-enabled out))
            (push "--off" args))
           (t
            (if-let ((mode (darr-output-current-mode out)))
                (progn
                  (push "--mode" args)
                  (push mode args)
                  (when-let ((r (darr-output-current-rate out)))
                    (push "--rate" args)
                    (push (number-to-string r) args)))
              ;; No mode known — let xrandr pick the preferred one.
              (push "--auto" args))
            (when-let ((g (darr-output-geometry out)))
              (push "--pos" args)
              (push (format "%dx%d" (nth 0 g) (nth 1 g)) args))
            (push "--rotate" args)
            (push (symbol-name (darr-output-rotation out)) args)
            (when (darr-output-primary out)
              (push "--primary" args)))))))
    (nreverse args)))

(defun darr-apply ()
  "Apply current layout via xrandr."
  (interactive)
  (let ((args (darr--xrandr-args)))
    (apply #'darr--call darr-xrandr-command args)
    (message "Applied: xrandr %s" (string-join args " "))
    (darr-refresh)))

;;; Profiles (autorandr)

;;;###autoload
(defun darr-list-profiles ()
  "List autorandr profiles."
  (interactive)
  (message "%s" (string-trim
                 (darr--call darr-autorandr-command "--list"))))

(defun darr--profile-list ()
  "Return the list of existing autorandr profile names."
  (split-string
   (string-trim
    (condition-case _ (darr--call darr-autorandr-command "--list")
      (error "")))
   "\n" t))

(defun darr--read-profile (prompt &optional require-match)
  "Prompt with PROMPT for an autorandr profile name.
If REQUIRE-MATCH is non-nil, only existing profiles are accepted;
otherwise the user may type a new name (used by save for overwrite UX)."
  (completing-read prompt (darr--profile-list) nil require-match))

;;;###autoload
(defun darr-save-profile (name)
  "Save current layout as autorandr profile NAME.
Completes against existing profiles so overwriting is easy; you may
also type a new name.  Confirms before overwriting."
  (interactive (list (darr--read-profile "Save profile: ")))
  (when (string-empty-p name)
    (user-error "No profile name given"))
  (let ((existing (member name (darr--profile-list))))
    (when (and existing
               (not (y-or-n-p (format "Overwrite existing profile %S? " name))))
      (user-error "Cancelled"))
    (darr--call darr-autorandr-command "--save" name "--force")
    (message "%s profile: %s" (if existing "Overwrote" "Saved") name)))

;;;###autoload
(defun darr-load-profile (name)
  "Load autorandr profile NAME."
  (interactive (list (darr--read-profile "Profile: " t)))
  (darr--call darr-autorandr-command "--load" name)
  (darr-refresh)
  (message "Loaded profile: %s" name))

;;;###autoload
(defun darr-delete-profile (name)
  "Delete autorandr profile NAME (asks for confirmation)."
  (interactive (list (darr--read-profile "Delete profile: " t)))
  (when (string-empty-p name)
    (user-error "No profile selected"))
  (when (y-or-n-p (format "Delete autorandr profile %S? " name))
    (darr--call darr-autorandr-command "--remove" name)
    (message "Deleted profile: %s" name)))

;;; Hot-plug watcher

(defvar darr--watcher-process nil)
(defvar darr--last-connected nil)

(defun darr--watch-tick ()
  "Poll xrandr; fire hooks on connect/disconnect."
  (let* ((state (darr--parse-xrandr
                 (darr--call darr-xrandr-command "--query")))
         (connected (cl-remove-if-not #'darr-output-connected state))
         (names (mapcar #'darr-output-name connected)))
    (dolist (n names)
      (unless (member n darr--last-connected)
        (run-hook-with-args 'darr-on-connect-hook n)))
    (dolist (n darr--last-connected)
      (unless (member n names)
        (run-hook-with-args 'darr-on-disconnect-hook n)))
    (setq darr--last-connected names
          darr--state state)
    (when (get-buffer darr-buffer-name)
      (darr--render))))

;;;###autoload
(define-minor-mode darr-watch-mode
  "Poll for display hot-plug changes.
Fires `darr-on-connect-hook' / `darr-on-disconnect-hook'.

Off by default: many systems are better served by autorandr's udev
integration (`autorandr --change` triggered by the system on plug events).
Enable this only if you don't have that wired up."
  :global t
  :lighter " Displays"
  (if darr-watch-mode
      (progn
        (setq darr--last-connected (darr--connected-names))
        (setq darr--watcher-process
              (run-with-timer 5 5 #'darr--watch-tick)))
    (when (timerp darr--watcher-process)
      (cancel-timer darr--watcher-process))
    (setq darr--watcher-process nil)))

;;; Entry points

;;;###autoload
(defun darr-show ()
  "Open the displays layout buffer."
  (interactive)
  (pop-to-buffer (get-buffer-create darr-buffer-name))
  (darr-refresh))

;;;###autoload
(defalias 'darr #'darr-show
  "Discoverable entry point: `M-x darr' opens the layout buffer.")

(defun darr-help ()
  "Show key bindings for `darr-mode'."
  (interactive)
  (describe-mode))

(provide 'darr)
;;; darr.el ends here
