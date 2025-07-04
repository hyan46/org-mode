;;; ob-latex.el --- Babel Functions for LaTeX        -*- lexical-binding: t; -*-

;; Copyright (C) 2009-2025 Free Software Foundation, Inc.

;; Author: Eric Schulte
;; Keywords: literate programming, reproducible research
;; URL: https://orgmode.org

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Org-Babel support for evaluating LaTeX source code.
;;
;; Currently on evaluation this returns raw LaTeX code, unless a :file
;; header argument is given in which case small png or pdf files will
;; be created directly form the latex source code.

;;; Code:

(require 'org-macs)
(org-assert-version)

(require 'ob)
(require 'org-macs)

(declare-function org-latex-preview-create-image "org-latex-preview" (string tofile options buffer &optional type))
(declare-function org-latex-compile "ox-latex" (texfile &optional snippet))
(declare-function org-latex-guess-inputenc "ox-latex" (header))
(declare-function org-splice-latex-header "org" (tpl def-pkg pkg snippets-p &optional extra))
(declare-function org-at-heading-p "org" (&optional _))
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-next-visible-heading "org" (arg))

(defvar org-babel-tangle-lang-exts)
(add-to-list 'org-babel-tangle-lang-exts '("latex" . "tex"))

(defvar org-latex-preview-header)             ; From org-latex-preview.el
(defvar org-latex-preview-appearance-options) ; From org-latex-preview.el
(defvar org-latex-default-packages-alist)     ; From org-latex-preview.el
(defvar org-latex-packages-alist)             ; From org-latex-preview.el

(defvar org-babel-default-header-args:latex
  '((:results . "latex") (:exports . "results"))
  "Default arguments to use when evaluating a LaTeX source block.")

(defconst org-babel-header-args:latex
  '((border	  . :any)
    (fit          . :any)
    (imagemagick  . ((nil t)))
    (iminoptions  . :any)
    (imoutoptions . :any)
    (packages     . :any)
    (pdfheight    . :any)
    (pdfpng       . :any)
    (pdfwidth     . :any)
    (headers      . :any)
    (buffer       . ((yes no))))
  "LaTeX-specific header arguments.")

(defcustom org-babel-latex-htlatex "htlatex"
  "The htlatex command to enable conversion of LaTeX to SVG or HTML."
  :group 'org-babel
  :type 'string)

(defcustom org-babel-latex-preamble
  (lambda (_)
    "\\documentclass[preview]{standalone}
\\def\\pgfsysdriver{pgfsys-tex4ht.def}
")
  "Closure which evaluates at runtime to the LaTeX preamble.

It takes 1 argument which is the parameters of the source block."
  :group 'org-babel
  :type 'function)

(defcustom org-babel-latex-begin-env
  (lambda (_)
    "\\begin{document}")
  "Function that evaluates to the begin part of the document environment.

It takes 1 argument which is the parameters of the source block.
This allows adding additional code that will be ignored when
exporting the literal LaTeX source."
  :group 'org-babel
  :type 'function)

(defcustom org-babel-latex-end-env
  (lambda (_)
    "\\end{document}")
  "Closure which evaluates at runtime to the end part of the document environment.

It takes 1 argument which is the parameters of the source block.
This allows adding additional code that will be ignored when
exporting the literal LaTeX source."
  :group 'org-babel
  :type 'function)

(defcustom org-babel-latex-pdf-svg-process
  "inkscape \
--pdf-poppler \
--export-area-drawing \
--export-text-to-path \
--export-plain-svg \
--export-filename=%O \
%f"
  "Command to convert a PDF file to an SVG file."
  :group 'org-babel
  :type 'string
  :package-version '(Org . "9.6"))

(defcustom org-babel-latex-htlatex-packages
  '("[usenames]{color}" "{tikz}" "{color}" "{listings}" "{amsmath}")
  "Packages to use for htlatex export."
  :group 'org-babel
  :type '(repeat (string)))

(defcustom org-babel-latex-process-alist
  `((png :programs ("latex" "dvipng") :description "dvi > png"
	 :message
	 "you need to install the programs: latex and dvipng."
	 :image-input-type "dvi" :image-output-type "png"
	 :image-size-adjust (1.0 . 1.0) :latex-compiler
         ,(if (executable-find "latexmk")
              '("latexmk -f -pdf -latex -interaction=nonstopmode -output-directory=%o %f")
            '("latex -interaction nonstopmode -output-directory %o %f"
              "latex -interaction nonstopmode -output-directory %o %f"
              "latex -interaction nonstopmode -output-directory %o %f"))
	 :image-converter ("dvipng -D %D -T tight -o %O %f")
	 :transparent-image-converter
	 ("dvipng -D %D -T tight -bg Transparent -o %O %f")))
  "Definitions of external processes for LaTeX result generation.
See `org-preview-latex-process-alist' for more details.

The following process symbols are recognized:
- `png' :: Process used to produce .png output."
  :group 'org-babel
  :package-version '(Org . "9.8")
  :type '(alist :tag "LaTeX to image backends"
		:value-type (plist)))

(defun org-babel-expand-body:latex (body params)
  "Expand BODY according to PARAMS, return the expanded body."
  (mapc (lambda (pair) ;; replace variables
          (setq body
                (replace-regexp-in-string
                 (regexp-quote (format "%S" (car pair)))
                 (if (stringp (cdr pair))
                     (cdr pair) (format "%S" (cdr pair)))
                 body t t)))
	(org-babel--get-vars params))
  (let ((prologue (cdr (assq :prologue params)))
        (epilogue (cdr (assq :epilogue params))))
    (org-trim
     (concat
      (and prologue (concat prologue "\n"))
      body
      (and epilogue (concat "\n" epilogue "\n"))))))

(defun org-babel-execute:latex (body params)
  "Execute LaTeX BODY according to PARAMS.
This function is called by `org-babel-execute-src-block'."
  (setq body (org-babel-expand-body:latex body params))
  (if (cdr (assq :file params))
      (let* ((out-file (cdr (assq :file params)))
	     (extension (file-name-extension out-file))
	     (tex-file (org-babel-temp-file "latex-" ".tex"))
	     (border (cdr (assq :border params)))
	     (imagemagick (cdr (assq :imagemagick params)))
	     (im-in-options (cdr (assq :iminoptions params)))
	     (im-out-options (cdr (assq :imoutoptions params)))
	     (fit (or (cdr (assq :fit params)) border))
	     (height (and fit (cdr (assq :pdfheight params))))
	     (width (and fit (cdr (assq :pdfwidth params))))
	     (headers (cdr (assq :headers params)))
	     (in-buffer (not (string= "no" (cdr (assq :buffer params)))))
	     (org-latex-packages-alist
	      (append (cdr (assq :packages params)) org-latex-packages-alist)))
        (cond
         ((and (string-suffix-p ".png" out-file) (not imagemagick))
          (let ((org-latex-preview-header
		 (concat org-latex-preview-header "\n"
			 (mapconcat #'identity headers "\n"))))
	    (org-latex-preview-create-image
             body out-file org-latex-preview-appearance-options in-buffer)))
	 ((string= "svg" extension)
	  (with-temp-file tex-file
	    (insert (concat (funcall org-babel-latex-preamble params)
			    (mapconcat #'identity headers "\n")
			    (funcall org-babel-latex-begin-env params)
			    body
			    (funcall org-babel-latex-end-env params))))
	  (let ((tmp-pdf (org-babel-latex-tex-to-pdf tex-file)))
            (let* ((log-buf (get-buffer-create "*Org Babel LaTeX Output*"))
                   (err-msg "org babel latex failed")
                   (img-out (org-compile-file
	                     tmp-pdf
                             (list org-babel-latex-pdf-svg-process)
                             extension err-msg log-buf)))
              (rename-file img-out out-file t))))
         ((string-suffix-p ".tikz" out-file)
	  (when (file-exists-p out-file) (delete-file out-file))
	  (with-temp-file out-file
	    (insert body)))
	 ((and (string= "html" extension)
	       (executable-find org-babel-latex-htlatex))
	  ;; TODO: this is a very different way of generating the
	  ;; frame latex document than in the pdf case.  Ideally, both
	  ;; would be unified.  This would prevent bugs creeping in
	  ;; such as the one fixed on Aug 16 2014 whereby :headers was
	  ;; not included in the SVG/HTML case.
	  (with-temp-file tex-file
	    (insert (concat
		     "\\documentclass[preview]{standalone}
\\def\\pgfsysdriver{pgfsys-tex4ht.def}
"
		     (mapconcat (lambda (pkg)
				  (concat "\\usepackage" pkg))
				org-babel-latex-htlatex-packages
				"\n")
		     (if headers
			 (concat "\n"
				 (if (listp headers)
				     (mapconcat #'identity headers "\n")
				   headers) "\n")
		       "")
		     "\\begin{document}"
		     body
		     "\\end{document}")))
	  (when (file-exists-p out-file) (delete-file out-file))
	  (let ((default-directory (file-name-directory tex-file)))
	    (shell-command (format "%s %s" org-babel-latex-htlatex tex-file)))
	  (cond
	   ((file-exists-p (concat (file-name-sans-extension tex-file) "-1.svg"))
	    (if (string-suffix-p ".svg" out-file)
		(progn
		  (shell-command "pwd")
                  (rename-file (concat (file-name-sans-extension tex-file) "-1.svg")
                               out-file t))
	      (error "SVG file produced but HTML file requested")))
	   ((file-exists-p (concat (file-name-sans-extension tex-file) ".html"))
	    (if (string-suffix-p ".html" out-file)
                (rename-file (concat (file-name-sans-extension tex-file) ".html")
                             out-file t)
              (error "HTML file produced but SVG file requested")))))
	 ((or (string= "pdf" extension) imagemagick)
	  (with-temp-file tex-file
	    (require 'ox-latex)
            (defvar org-latex-compiler)
            (declare-function org-latex--remove-packages "ox-latex" (pkg-alist info))
	    (insert
	     (org-latex-guess-inputenc
	      (org-splice-latex-header
	       org-latex-preview-header
	       (delq
		nil
		(mapcar
		 (lambda (el)
		   (unless (and (listp el) (string= "hyperref" (cadr el)))
		     el))
		 (org-latex--remove-packages
                  org-latex-default-packages-alist
                  (list :latex-compiler org-latex-compiler))))
               (org-latex--remove-packages
	        org-latex-packages-alist
                (list :latex-compiler org-latex-compiler))
	       nil))
	     (if fit "\n\\usepackage[active, tightpage]{preview}\n" "")
	     (if border (format "\\setlength{\\PreviewBorder}{%s}" border) "")
	     (if height (concat "\n" (format "\\pdfpageheight %s" height)) "")
	     (if width  (concat "\n" (format "\\pdfpagewidth %s" width))   "")
	     (if headers
		 (concat "\n"
			 (if (listp headers)
			     (mapconcat #'identity headers "\n")
			   headers) "\n")
	       "")
	     (if fit
		 (concat "\n\\begin{document}\n\\begin{preview}\n" body
			 "\n\\end{preview}\n\\end{document}\n")
	       (concat "\n\\begin{document}\n" body "\n\\end{document}\n"))))
          (when (file-exists-p out-file) (delete-file out-file))
	  (let ((transient-pdf-file (org-babel-latex-tex-to-pdf tex-file)))
	    (cond
	     ((string= "pdf" extension)
	      (rename-file transient-pdf-file out-file))
	     (imagemagick
	      (org-babel-latex-convert-pdf
	       transient-pdf-file out-file im-in-options im-out-options)
	      (when (file-exists-p transient-pdf-file)
		(delete-file transient-pdf-file)))
	     (t
	      (error "Can not create %s files, please specify a .png or .pdf file or try the :imagemagick header argument"
		     extension))))))
        nil) ;; signal that output has already been written to file
    body))

(defun org-babel-latex-convert-pdf (pdffile out-file im-in-options im-out-options)
  "Generate OUT-FILE from PDFFILE using imagemagick.
IM-IN-OPTIONS are command line options for input file, as a string;
and IM-OUT-OPTIONS are the output file options."
  (let ((cmd (concat "convert " im-in-options " " pdffile " "
		     im-out-options " " out-file)))
    (message "Converting pdffile file %s..." cmd)
    (shell-command cmd)))

(defun org-babel-latex-tex-to-pdf (file)
  "Generate a pdf file according to the contents FILE."
  (require 'ox-latex)
  (org-latex-compile file))

(defun org-babel-prep-session:latex (_session _params)
  "Return an error because LaTeX doesn't support sessions."
  (error "LaTeX does not support sessions"))

(provide 'ob-latex)

;;; ob-latex.el ends here
