;;; color-identifiers-mode.el --- Color identifiers based on their names

;; Copyright (C) 2014 Ankur Dave

;; Author: Ankur Dave <ankurdave@gmail.com>
;; Url: https://github.com/ankurdave/color-identifiers-mode
;; Created: 24 Jan 2014
;; Version: 1.1
;; Keywords: faces, languages
;; Package-Requires: ((dash "2.5.0") (dash-functional "1.0.0") (emacs "24"))

;; This file is not a part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Color Identifiers is a minor mode for Emacs that highlights each source code
;; identifier uniquely based on its name.  It is inspired by a post by Evan
;; Brooks: https://medium.com/p/3a6db2743a1e/

;; Currently it only supports js-mode and scala-mode2, but support for other
;; modes is forthcoming.  You can add support for your favorite mode by modifying
;; `color-identifiers:modes-alist'.

;;; Code:

(require 'color)
(require 'dash)
(require 'dash-functional)

;;;###autoload
(define-minor-mode color-identifiers-mode
  "Color the identifiers in the current buffer based on their names."
  :init-value nil
  :lighter " ColorIds"
  (if color-identifiers-mode
      (progn
        (color-identifiers:regenerate-colors)
        (color-identifiers:refresh)
        (font-lock-add-keywords nil '((color-identifiers:colorize . default)) t)
        (unless color-identifiers:timer
          (setq color-identifiers:timer
                (run-with-idle-timer 10 t 'color-identifiers:refresh)))
        (ad-activate 'enable-theme))
    (when color-identifiers:timer
      (cancel-timer color-identifiers:timer))
    (setq color-identifiers:timer nil)
    (font-lock-remove-keywords nil '((color-identifiers:colorize . default)))
    (ad-deactivate 'enable-theme))
  (font-lock-fontify-buffer))

(defadvice enable-theme (after color-identifiers:regen-on-theme-change)
  (color-identifiers:regenerate-colors))

(add-to-list 'font-lock-extra-managed-props 'color-identifiers:fontified)

(defvar color-identifiers:timer nil)

(defvar color-identifiers:modes-alist nil
  "Alist of major modes and the ways to distinguish identifiers in those modes.
The value of each cons cell provides three constraints for finding identifiers.
A word must match all three constraints to be colored as an identifier.  The
value has the form (IDENTIFIER-CONTEXT-RE IDENTIFIER-RE IDENTIFIER-FACES).

IDENTIFIER-CONTEXT-RE is a regexp matching the text that must precede an
identifier.
IDENTIFIER-RE is a regexp whose first capture group matches identifiers.
IDENTIFIER-FACES is a list of faces with which the major mode decorates
identifiers or a function returning such a list.  If the list includes nil,
unfontified words will be considered.")

(add-to-list
 'color-identifiers:modes-alist
 `(scala-mode . ("[^.][[:space:]]*"
                 "\\_<\\([[:lower:]]\\([_]??[[:lower:][:upper:]\\$0-9]+\\)*\\(_+[#:<=>@!%&*+/?\\\\^|~-]+\\|_\\)?\\)"
                 (nil scala-font-lock:var-face font-lock-variable-name-face))))

(add-to-list
 'color-identifiers:modes-alist
 `(js-mode . ("[^.][[:space:]]*"
              "\\_<\\([a-zA-Z_$]\\(?:\\s_\\|\\sw\\)*\\)"
              (nil font-lock-variable-name-face))))

(add-to-list
 'color-identifiers:modes-alist
 `(js2-mode . ("[^.][[:space:]]*"
              "\\_<\\([a-zA-Z_$]\\(?:\\s_\\|\\sw\\)*\\)"
              (nil font-lock-variable-name-face js2-function-param))))

(add-to-list
 'color-identifiers:modes-alist
 `(ruby-mode . ("[^.][[:space:]]*" "\\_<\\([a-zA-Z_$]\\(?:\\s_\\|\\sw\\)*\\)" (nil))))

(defvar color-identifiers:num-colors 10
  "The number of different colors to generate.")

(defvar color-identifiers:colors nil
  "List of hex colors generated by `color-identifiers:regenerate-colors'.")

(defun color-identifiers:regenerate-colors ()
  "Generate perceptually distinct colors with the same luminance in HSL space.
Colors are output to `color-identifiers:colors'."
  (interactive)
  (let* ((luminance (max 0.35 (min 0.8 (color-identifiers:attribute-luminance :foreground))))
         (candidates '())
         (chosens '())
         (n 8)
         (n-1 (float (1- n))))
    ;; Populate candidates with evenly spaced HSL colors with fixed luminance,
    ;; converted to LAB
    (dotimes (h n)
      (dotimes (s n)
        (add-to-list
         'candidates
         (apply 'color-srgb-to-lab
                (color-hsl-to-rgb (/ h n-1) (/ s n-1) luminance)))))
    (let ((choose-candidate (lambda (candidate)
                              (delq candidate candidates)
                              (push candidate chosens))))
      (setq color-identifiers:colors nil)
      (funcall choose-candidate (car candidates))
      (while (and candidates (< (length chosens) color-identifiers:num-colors))
        (let* (;; For each remaining candidate, find the distance to the closest chosen
               ;; color
               (min-dists (-map (lambda (candidate)
                                  (cons candidate
                                        (-min (-map (lambda (chosen)
                                                      (color-cie-de2000 candidate chosen))
                                                    chosens))))
                                candidates))
               ;; Take the candidate with the highest min distance
               (best (-max-by (-on '> 'cdr) min-dists)))
          (funcall choose-candidate (car best))))
      (setq color-identifiers:colors
            (-map (lambda (lab)
                    (apply 'color-rgb-to-hex (apply 'color-lab-to-srgb lab)))
                  chosens)))))

(defvar-local color-identifiers:color-index-for-identifier nil
  "Alist of identifier-index pairs for internal use.
The index refers to `color-identifiers:colors'.")

(defvar-local color-identifiers:current-index 0
  "Current color index for new identifiers, for internal use.
The index refers to `color-identifiers:colors'.")

(defun color-identifiers:attribute-luminance (attribute)
  "Find the HSL luminance of the specified ATTRIBUTE on the default face."
  (let ((rgb (color-name-to-rgb (face-attribute 'default attribute))))
    (if rgb
	(nth 2 (apply 'color-rgb-to-hsl rgb))
      0.5)))

(defun color-identifiers:refresh ()
  "Refresh `color-identifiers:color-index-for-identifier' from current buffer."
  (interactive)
  (when color-identifiers-mode
    (save-excursion
      (goto-char (point-min))
      (catch 'input-pending
        (let ((i 0)
              (n color-identifiers:num-colors)
              (result nil))
          (color-identifiers:scan-identifiers
           (lambda (start end)
             (let ((identifier (buffer-substring-no-properties start end)))
               (unless (assoc-string identifier result)
                 (push (cons identifier (% i n)) result)
                 (setq i (1+ i)))))
           (point-max)
           (lambda () (if (input-pending-p) (throw 'input-pending nil) t)))
          (setq color-identifiers:color-index-for-identifier result)
          (font-lock-fontify-buffer))))))

(defun color-identifiers:color-identifier (identifier)
  "Look up or generate the hex color for IDENTIFIER.
IDENTIFIER is looked up in `color-identifiers:color-index-for-identifier' and
generated if not present there."
  (let ((entry (assoc-string identifier color-identifiers:color-index-for-identifier)))
    (if entry
        (nth (cdr entry) color-identifiers:colors)
      ;; If not present, make a temporary color using the rotating index
      (push (cons identifier (% color-identifiers:current-index
                                (length color-identifiers:colors)))
            color-identifiers:color-index-for-identifier)
      (setq color-identifiers:current-index
            (1+ color-identifiers:current-index)))))

(defun color-identifiers:scan-identifiers (fn limit &optional continue-p)
  "Run FN on all identifiers from point up to LIMIT.
Identifiers are defined by `color-identifiers:modes-alist'.
If supplied, iteration only continues if CONTINUE-P evaluates to true."
  (let ((entry (assoc major-mode color-identifiers:modes-alist)))
    (when entry
      (let ((identifier-context-re (nth 1 entry))
            (identifier-re (nth 2 entry))
            (identifier-faces
             (if (functionp (nth 3 entry))
                 (funcall (nth 3 entry))
               (nth 3 entry))))
        ;; Skip forward to the next identifier that matches all three conditions
        (condition-case nil
            (while (and (< (point) limit)
                        (if continue-p (funcall continue-p) t))
              (if (not (or (memq (get-text-property (point) 'face) identifier-faces)
                           (let ((flface-prop (get-text-property (point) 'font-lock-face)))
                             (and flface-prop (memq flface-prop identifier-faces)))
                           (get-text-property (point) 'color-identifiers:fontified)))
                  (goto-char (next-property-change (point) nil limit))
                (if (not (and (looking-back identifier-context-re)
                              (looking-at identifier-re)))
                    (progn
                      (forward-char)
                      (re-search-forward identifier-re limit)
                      (goto-char (match-beginning 0)))
                  ;; Found an identifier. Run `fn' on it
                  (funcall fn (match-beginning 1) (match-end 1))
                  (goto-char (match-end 1)))))
          (search-failed nil))))))

(defun color-identifiers:colorize (limit)
  (color-identifiers:scan-identifiers
   (lambda (start end)
     (let* ((identifier (buffer-substring-no-properties start end))
            (hex (color-identifiers:color-identifier identifier)))
       (when hex
         (put-text-property start end 'face `(:foreground ,hex))
         (put-text-property start end 'color-identifiers:fontified t))))
   limit))

(provide 'color-identifiers-mode)

;;; color-identifiers-mode.el ends here
