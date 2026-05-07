;;; darr-tests.el --- Tests for darr  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'darr)

;;; Fixtures — sampled real xrandr output

(defconst darr-tests--xrandr-laptop-only
  "Screen 0: minimum 320 x 200, current 2160 x 1350, maximum 16384 x 16384
eDP-1 connected primary 2160x1350+0+0 (normal left inverted right x axis y axis) 280mm x 175mm
   2160x1350     59.74*+  30.00
   1920x1080     60.01    59.97    59.96    59.93
HDMI-1 disconnected (normal left inverted right x axis y axis)
DP-1 disconnected (normal left inverted right x axis y axis)
")

(defconst darr-tests--xrandr-dual
  "Screen 0: minimum 320 x 200, current 4080 x 1350, maximum 16384 x 16384
eDP-1 connected primary 2160x1350+0+0 (normal left inverted right x axis y axis) 280mm x 175mm
   2160x1350     59.74*+
HDMI-1 connected 1920x1080+2160+135 (normal left inverted right x axis y axis) 510mm x 290mm
   1920x1080     60.00*+  59.94
   1280x720      60.00
")

(defconst darr-tests--xrandr-connected-but-off
  "Screen 0: minimum 320 x 200, current 2160 x 1350, maximum 16384 x 16384
eDP-1 connected primary 2160x1350+0+0 (normal left inverted right x axis y axis) 280mm x 175mm
   2160x1350     59.74*+
DP-3 connected (normal left inverted right x axis y axis) 510mm x 290mm
   3840x2160     60.00 +  59.94
   1920x1080     60.00
")

;;; Parser

(ert-deftest darr-test-parses-laptop-only ()
  "Single connected display with multiple disconnected ports."
  (let ((outs (darr--parse-xrandr darr-tests--xrandr-laptop-only)))
    (should (= (length outs) 3))
    (let ((edp (cl-find "eDP-1" outs :key #'darr-output-name :test #'string=)))
      (should (darr-output-connected edp))
      (should (darr-output-enabled edp))
      (should (darr-output-primary edp))
      (should (equal (darr-output-current-mode edp) "2160x1350"))
      (should (equal (darr-output-current-rate edp) 59.74))
      (should (equal (darr-output-geometry edp) '(0 0 2160 1350)))
      (should (eq (darr-output-rotation edp) 'normal)))
    (let ((hdmi (cl-find "HDMI-1" outs :key #'darr-output-name :test #'string=)))
      (should-not (darr-output-connected hdmi))
      (should-not (darr-output-enabled hdmi))
      (should (null (darr-output-current-mode hdmi))))))

(ert-deftest darr-test-parses-dual-displays ()
  "Two enabled displays, second offset to the right."
  (let* ((outs (darr--parse-xrandr darr-tests--xrandr-dual))
         (hdmi (cl-find "HDMI-1" outs :key #'darr-output-name :test #'string=)))
    (should (darr-output-connected hdmi))
    (should (darr-output-enabled hdmi))
    (should-not (darr-output-primary hdmi))
    (should (equal (darr-output-geometry hdmi) '(2160 135 1920 1080)))
    (should (equal (darr-output-current-mode hdmi) "1920x1080"))
    (should (equal (darr-output-current-rate hdmi) 60.0))))

(ert-deftest darr-test-parses-connected-but-off ()
  "DP-3 connected but currently --off has no geometry/rate but has modes."
  (let* ((outs (darr--parse-xrandr darr-tests--xrandr-connected-but-off))
         (dp (cl-find "DP-3" outs :key #'darr-output-name :test #'string=)))
    (should (darr-output-connected dp))
    (should-not (darr-output-enabled dp))
    (should (null (darr-output-current-mode dp)))
    (should (null (darr-output-current-rate dp)))
    (should (null (darr-output-geometry dp)))
    (should (assoc "3840x2160" (darr-output-modes dp)))
    ;; "60.00 +" is preferred but not current ("*"), so no current-rate is set.
    (should (member 60.0 (cdr (assoc "3840x2160" (darr-output-modes dp)))))))

(ert-deftest darr-test-mode-list-preserves-order ()
  "Modes are stored in source order so cycle commands behave predictably."
  (let* ((outs (darr--parse-xrandr darr-tests--xrandr-laptop-only))
         (edp (cl-find "eDP-1" outs :key #'darr-output-name :test #'string=))
         (modes (mapcar #'car (darr-output-modes edp))))
    (should (equal modes '("2160x1350" "1920x1080")))))

;;; xrandr-args round-trip

(ert-deftest darr-test-xrandr-args-enabled ()
  "Args for an enabled display include --mode/--rate/--pos/--rotate."
  (let* ((darr--state
          (list (make-darr-output
                 :name "eDP-1" :connected t :enabled t :primary t
                 :geometry '(0 0 2160 1350) :rotation 'normal
                 :current-mode "2160x1350" :current-rate 59.74)))
         (args (darr--xrandr-args)))
    (should (member "--output" args))
    (should (member "eDP-1" args))
    (should (member "--mode" args))
    (should (member "2160x1350" args))
    (should (member "--rate" args))
    (should (member "59.74" args))
    (should (member "--pos" args))
    (should (member "0x0" args))
    (should (member "--primary" args))
    (should-not (cl-some #'null args))))

(ert-deftest darr-test-xrandr-args-disabled ()
  "Disabled display gets --off; no mode/rate/pos."
  (let* ((darr--state
          (list (make-darr-output
                 :name "eDP-1" :connected t :enabled nil
                 :rotation 'normal)))
         (args (darr--xrandr-args)))
    (should (member "--off" args))
    (should-not (member "--mode" args))
    (should-not (member "--rate" args))
    (should-not (cl-some #'null args))))

(ert-deftest darr-test-xrandr-args-no-mode-uses-auto ()
  "Defensive fallback: enabled display without a known mode uses --auto."
  (let* ((darr--state
          (list (make-darr-output
                 :name "DP-1" :connected t :enabled t
                 :rotation 'normal
                 :current-mode nil :current-rate nil :geometry nil)))
         (args (darr--xrandr-args)))
    (should (member "--auto" args))
    (should-not (member "--mode" args))
    (should-not (cl-some #'null args))))

(ert-deftest darr-test-xrandr-args-skips-disconnected ()
  "Disconnected outputs produce no args (xrandr would error)."
  (let* ((darr--state
          (list (make-darr-output :name "HDMI-1" :connected nil)))
         (args (darr--xrandr-args)))
    (should (null args))))

(provide 'darr-tests)
;;; darr-tests.el ends here
