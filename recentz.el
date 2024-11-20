;;; recentz.el --- Minimalized and KISS replacements of built-in recentf  -*- lexical-binding: t; -*-

;; Copyright (C) 2024 kuanyui

;; Author: kuanyui <azazabc123@gmail.com>
;; License: GPLv3
;; Version: 0.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: files
;; Url: https://github.com/kuanyui/recentz.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
;; MA 02110-1301, USA.

;;; Commentary:

;; A KISS, DWIM replacement of `recentf'.
;;
;;  - Minimalized, no confusing behavior, no extra dependency.
;;  - Fuzzy-search is provided by Ido (Emacs built-in) or Helm (optional).
;;  - Never cache, even never store anything in memory. (Everything are stored as a plaintext file in =~/.emacs.d/.recentz-data=.)
;;  - Never lost any item after exiting Emacs. (Even unexpectedly exit)
;;  - Always synchronize recents list between multiple Emacs instances.
;;  - Supported list: files / directories / projects (directories controlled by VC, ex: =git=)
;;
;; Installation
;;
;;     (require 'recentz)
;;     (setq recentz-ignore-path-patterns '("/COMMIT_EDITMSG$" "~$" "/node_modules/"))
;;
;;     ;; Choose prefered completion UI. Available options: 'helm, 'ido
;;     ;; (if helm is installed, helm will be selected by default.)
;;     (setq recentz-ui 'ido)
;;
;;     (global-set-key (kbd "C-x C-r") 'recentz-files)   ;; Add universal argument prefix "C-u" (that is "C-u C-x C-r") can open the recent TRAMP-opened files instead.
;;     (global-set-key (kbd "C-x C-d") 'recentz-directories)
;;     (global-set-key (kbd "C-x C-p") 'recentz-projects)
;;     (global-set-key (kbd "C-x C-S-r") 'recentz-tramp-files)         ;; (Optional, because it's equivalient to C-u C-x C-r)
;;     (global-set-key (kbd "C-x C-S-d") 'recentz-tramp-directories)   ;; (Optional, the reason is same above)
;;     (global-set-key (kbd "C-x C-S-p") 'recentz-tramp-projects)      ;; (Optional, the reason is same above)
;;
;;

(require 'cl-lib)
(require 'pp)

(defvar recentz-vc-directory-names '(".git" ".hg" ".bzr")
  "The folder name or file name to detect if a directory path is a
  VC-controlled folder. If so, this folder will be seems as a
  project.")
(defvar recentz-data-file-path (file-name-concat user-emacs-directory ".recentz-data")
  "The path to store recents list file."
  )
(defvar recentz-max-history
  '((files . 150)
    (directories . 50)
    (projects . 50)
    (tramp-files . 200)
    (tramp-directories . 50)
    (tramp-projects . 50)
    )
  "The maximum items amount for each types of recent items.")

(defvar recentz-ignore-path-patterns
  '(
    "/COMMIT_EDITMSG$"
    "~$"
    ".+org-clock-save\\.el$"
    "\\.eln$"
    "\\.elc$"
    "\\.emacs\\.d/session\\.[a-z0-9]\\{10\\}"
    "\\.git/objects/"
    )
  "Exclude the item from recents list if its path match any of the
  regexp patterns.")

(defvar recentz-tramp-path-patterns
  '(
    "/-:"
    "^/\\(su\\|sudo\\|doas\\|sg\\|sudoedit\\):"
    "^/rsh:"
    "^/sshx?:"
    "^/\\(docker\\|ksu\\|kubernetes\\|podman\\):"
    "^/\\(rsync\\|rcp\\|scp\\|scpx\\|pscp\\):"
    "^/\\(ftp\\|psftp\\|fcp\\|smb\\):"
    "^/adb:"
    "^/\\(afp\\|davs?\\|mtp\\):"
    "^/\\(gdrive\\|nextcloud\\|sftp\\):"
    )
  "Remote / tramp file paths list, ex: TRAMP, SSH, sudo, rsync.
  These file pathes will be stored in an independent list, and
  recentz will never check the availability of them.")

(defvar recentz-data-file-modes #o666
  "The file permission (file mode) of data-file (See
						 `recent-data-file-path'). This is important if you mean to let
  multiple users write the same data-file, or TRAMP... etc."
  )

(defvar recentz-ui (if (featurep 'helm-core) 'helm 'ido)
  "The prefered UI (frontend for completion). Available choices: `helm', `ido'

- Helm requires manual installation, but itself has a built-in fuzzy-search engine. (recommended)
- Ido is Emacs built-in package. Itself provides basic string matching, but more powerful fuzzy-search requires other 3rd party package.
")

(defun recentz-is-vc-root (&optional dirpath)
  (if (null dirpath) (setq dirpath default-directory))
  (cl-some (lambda (vc-dir-name)
	     (file-exists-p (file-name-concat dirpath vc-dir-name)))
	   recentz-vc-directory-names))

(defun recentz-find-vc-root (&optional filepath)
  "If the FILEPATH (or dirpath) is inside in, or itself is, a
  version control repo, return the path of repo root folder."
  (if (null filepath) (setq filepath default-directory))
  (let ((path (cl-some (lambda (vc-dir-name)
			 (locate-dominating-file filepath vc-dir-name))
		       recentz-vc-directory-names)))
    (if path (recentz-formalize-path path))))

(defun recentz-formalize-path (path &optional skip-tramp)
  "1. Expand \"~\" . 2. if PATH is a dir, append a slash."
  (setq path (expand-file-name path))
  (cond ((and skip-tramp (recentz-path-is-tramp-path path))
	 path)
	((file-directory-p path)
	 (file-name-as-directory path))
	(t
	 path)))

(defmacro recentz-ensure-data-file-permission (&rest body)
  `(cond ((file-directory-p recentz-data-file-path)
	  (message "You has set `recentz-data-file-path' as \"%s\" but it is a directory (expected a text file), please resolve it manually." recentz-data-file-path))
	 ((and (file-exists-p recentz-data-file-path)
	       (not (file-readable-p recentz-data-file-path)))
	  (message "You have no permission to read recentz's data-file (\"%s\", defined in variable \"recentz-data-file-path\"), please resolve it manually." recentz-data-file-path))
	 ((and (file-exists-p recentz-data-file-path)
	       (not (file-writable-p recentz-data-file-path)))
	  (message "You have no permission to write recentz's data-file (\"%s\", defined in variable \"recentz-data-file-path\"), please resolve it manually." recentz-data-file-path))
	 (t ,@body)))

(defun recentz--write-data-to-file (data)
  (recentz-ensure-data-file-permission
   (with-temp-file recentz-data-file-path
     (insert ";; -*- mode: lisp-data -*-\n")
  (insert (pp-to-string data))  ;; prin1-to-string is too hard to read
  )
   (ignore-errors
     (set-file-modes recentz-data-file-path recentz-data-file-modes))))

(defun recentz--read-data-from-file ()
  (recentz-ensure-data-file-permission
   (if (not (file-exists-p recentz-data-file-path))
       (recentz--write-data-to-file (recentz-fix-data nil)))
   (recentz-fix-data (with-temp-buffer
		       (insert-file-contents recentz-data-file-path)
		       (ignore-errors (read (current-buffer)))))))

(defun recentz-fix-data (data)
  "DATA should be in the format of `recentz-data-file-path' (a assoc
list). This function will validate the data structure of this
DATA and try to fix it to a valid structure then returns it.

Note this function never check the content (e.g. whether the file
path exists or not)"
  (let ((final (if (listp data) data '())))
    (mapc (lambda (type)
	    (if (not (assoc type final))
		(push (cons type '()) final)
	      (progn
		(if (not (listp (alist-get type final)))
		    (setf (alist-get type final) '()))
		(cl-delete-if-not #'stringp (alist-get type final))  ; FIXME: potential error due to "destructive" cl-delete ...?
		)))
	  '(files directories projects tramp-files tramp-directories tramp-projects))  ; types
    final))

(defun recentz-path-should-be-ignore (path)
  (cl-some (lambda (patt)
	     (string-match patt path))
	   recentz-ignore-path-patterns))

(defun recentz-path-is-tramp-path (path)
  "Returns t if file PATH is a TRAMP path."
  (cl-some (lambda (patt)
	     (string-match patt path))
	   recentz-tramp-path-patterns))

(defun recentz-file-exists-p (path)
  "Always returns t if the PATH is a TRAMP path."
  (if (recentz-path-is-tramp-path path)
      t
    (file-exists-p path)))

(defun recentz-push (type path)
  (cond ((recentz-path-should-be-ignore path)
	 ())
	(t
	 (let* ((all-data (recentz--read-data-from-file))
		(paths (alist-get type all-data))
		(expected-len (alist-get type recentz-max-history 30)))
	   (setq path (recentz-formalize-path path))
	   ;; setq again. Fuck the useless "destructive function". Indeed, destructive for user.
	   (setq paths (cl-delete-duplicates paths :test #'equal))
	   (setq paths (cl-delete path paths :test #'equal))
	   (push path paths)
	   (nbutlast paths (- (length paths) expected-len))  ; trim the list and keep expected length in head.
	   (setf (alist-get type all-data) paths)
	   (recentz--write-data-to-file all-data)
	   ))))

(defun recentz-get (type)
  (let* ((all-data (recentz--read-data-from-file))
	 (ori-paths (alist-get type all-data))
	 ;; Remove inexistent items from list.
	 (new-paths (cl-delete-if (lambda (path) (or (not (recentz-file-exists-p path))
						     (recentz-path-should-be-ignore path)))
				  ori-paths))
	 (new-paths (mapcar (lambda (p) (recentz-formalize-path p :skip-tramp)) new-paths))   ; migration from old version
	 (new-paths (cl-delete-duplicates new-paths :test #'equal))   ; migration from old version
	 )
    ;; If two paths list are not equal (NOTE: Lisp's `equal' can compare list elements), write new data
    (when (not (equal ori-paths new-paths))
      (setf (alist-get type all-data) new-paths)
      (recentz--write-data-to-file all-data))
    new-paths))

(defun recentz-clear (&optional type)
  "Manually clear recentz list by type.

  If call interactively, this supports the following types only:
  - tramp-files
  - tramp-directories
  - tramp-projects
  "
  (interactive)
  (let* ((type (or type (intern (completing-read "Clear Recentz List: " '(tramp-files tramp-directories tramp-projects) nil t))))
	 (all-data (recentz--read-data-from-file)))
    (if (null type) (error "Please specify type."))
    (setf (alist-get type all-data) '())
    (recentz--write-data-to-file all-data)
    (message "Clear list \"%s\"" type)))

(defun recentz-get-helm-candidates (type)
  (mapcar (lambda (path)
	    (cond ())
	    )
	  (recentz-get type)))

(defun recentz-push-proxy (type path)
  "Adapter for TRAMP and regular local file."
  (if (recentz-path-is-tramp-path path)
      (setq type (intern (format "tramp-%s" type))))
  (recentz-push type path))

(defun recentz--hookfn-find-file ()
  (recentz-push-proxy 'files (buffer-file-name))
  ;; If current file is inside a VCS repo, also add the repo directory as project.
  (let* ((cur-dir (file-name-directory (buffer-file-name)))
	 (repo-dir (recentz-find-vc-root cur-dir)))
    (if repo-dir
	(recentz-push-proxy 'projects repo-dir))))

(defun recentz--hookfn-dired (&optional dirpath)
  (if dirpath
      (setq dirpath (expand-file-name dirpath))
    (setq dirpath default-directory))
  (recentz-push-proxy 'directories dirpath)
  (let ((vc-root (recentz-find-vc-root dirpath)))
    (if vc-root
	(recentz-push-proxy 'projects vc-root))))

(defun recentz--hookfn-vc (&optional dirpath)
  (if dirpath
      (setq dirpath (expand-file-name dirpath))
    (setq dirpath default-directory))
  (recentz-push-proxy 'directories dirpath)
  (let ((vc-root (recentz-find-vc-root dirpath)))
    (if vc-root
	(recentz-push-proxy 'projects vc-root))))

(defun recentz--hookfn-emacs-startup ()
  ;;   (message "====================
  ;; %S
  ;; file name: %s
  ;; major mode: %s
  ;; ========================"
  ;;   command-line-args
  ;;   (buffer-file-name)
  ;;   major-mode)
  (let ((is-folder (equal major-mode 'dired-mode))
	(is-file (buffer-file-name)))
    (cond (is-folder (recentz--hookfn-dired default-directory))
	  (is-file (recentz--hookfn-find-file (buffer-file-name))))))

(add-hook 'find-file-hook 'recentz--hookfn-find-file)
(add-hook 'find-directory-functions 'recentz--hookfn-dired)
(with-eval-after-load 'magit
  (add-hook 'magit-status-mode-hook 'recentz--hookfn-vc)
  )
(add-hook 'emacs-startup-hook 'recentz--hookfn-emacs-startup)

(defun recentz-ido-completing-read (prompt type)
  (require 'ido)
  (let ((file-path (ido-completing-read "Recentz Files: " (recentz-get type) nil t)))
    (if file-path (recentz-push type file-path))
    file-path))

;;;###autoload
(defun recentz--ido-files (&optional arg)
  "[Ido] List recently opened files."
  (interactive "P")
  (if arg
      (recentz-tramp-files)
    (find-file (recentz-ido-completing-read "Recentz Files: " 'files))))

;;;###autoload
(defun recentz--ido-projects (&optional arg)
  "[Ido] List recently opened projects."
  (interactive "P")
  (if arg
      (recentz-tramp-projects)
    (find-file (recentz-ido-completing-read "Recentz Projects: " 'projects))))

;;;###autoload
(defun recentz--ido-directories (&optional arg)
  "[Ido] List recently opened directories."
  (interactive "P")
  (if arg
      (recentz-tramp-directories)
    (find-file (recentz-ido-completing-read "Recentz Directories: " 'directories))))

;;;###autoload
(defun recentz--ido-tramp-files ()
  "[Ido] List recent files opened via TRAMP. Notice this will not automatically clear inexistent item from list."
  (interactive)
  (find-file (recentz-ido-completing-read "Recentz Files in TRAMP: " 'tramp-files)))

;;;###autoload
(defun recentz--ido-tramp-projects ()
  "[Ido] List recent projects opened via TRAMP. Notice this will not automatically clear inexistent item from list."
  (interactive)
  (find-file (recentz-ido-completing-read "Recentz Projects in TRAMP: " 'tramp-projects)))

;;;###autoload
(defun recentz--ido-tramp-directories ()
  "[Ido] List recent directories opened via TRAMP. Notice this will not automatically clear inexistent item from list."
  (interactive)
  (find-file (recentz-ido-completing-read "Recentz Directories in TRAMP: " 'tramp-directories)))

(defun recentz-helm-completing-find-file (source-name prompt type)
  (if (not (featurep 'helm-core))
      (message "This feature requires helm-core, but it's not installed on your Emacs yet. Please install helm, or use ido version (M-x recentz-*) instead.")
    (progn
      (require 'helm-core)
      (let ((file-path (helm :sources (helm-build-sync-source source-name
					:candidates (lambda () (recentz-get type))
					:volatile t
					:action (lambda (str) (find-file str) str)   ;; Returns str to helm explicitly, otherwise `find-file' will returns something like #<buffer recentz.el>
					)
			     :buffer "*Recentz*"
			     :prompt prompt)))
	(if file-path (recentz-push type file-path))
	file-path))))

;;;###autoload
(defun recentz--helm-files (&optional arg)
  "[Helm] List recently opened files."
  (interactive "P")
  (if arg
      (recentz--helm-tramp-files)
    (recentz-helm-completing-find-file "recentz-source-files" "Recent files: " 'files)))

;;;###autoload
(defun recentz--helm-projects (&optional arg)
  "[Helm] List recently opened projects."
  (interactive "P")
  (if arg
      (recentz--helm-tramp-projects)
    (recentz-helm-completing-find-file "recentz-source-projects" "Recent projects: " 'projects)))

;;;###autoload
(defun recentz--helm-directories (&optional arg)
  "[Helm] List recently opened directories."
  (interactive "P")
  (if arg
      (recentz--helm-tramp-directories)
    (recentz-helm-completing-find-file "recentz-source-directories" "Recent directories: " 'directories)))

;;;###autoload
(defun recentz--helm-tramp-files ()
  "[Helm] List recent files opened via TRAMP. Notice this will not automatically clear inexistent item from list."
  (interactive)
  (recentz-helm-completing-find-file "recentz-source-files-in-tramp" "Recent files via TRAMP: " 'tramp-files))

;;;###autoload
(defun recentz--helm-tramp-projects ()
  "[Helm] List recent projects opened via TRAMP. Notice this will not automatically clear inexistent item from list."
  (interactive)
  (recentz-helm-completing-find-file "recentz-source-projects-in-tramp" "Recent projects via TRAMP: " 'tramp-projects))

;;;###autoload
(defun recentz--helm-tramp-directories ()
  "[Helm] List recent directories opened via TRAMP. Notice this will not automatically clear inexistent item from list."
  (interactive)
  (recentz-helm-completing-find-file "recentz-source-directories-in-tramp" "Recent directories via TRAMP: " 'tramp-directories))


(defun recentz-call-process-to-string-list (program &rest args)
  "`shell-command-to-string' is too slow for simple task, so use this."
  (with-temp-buffer
    (apply #'call-process program (append '(nil t nil) args))
    ;; Remove the trailing empty line
    (if (> (point-max) 1)
	(delete-region (1- (point-max)) (point-max)))
    (split-string (buffer-string) "\n")))

(defun recentz-get-file-list-in-project (patt &optional dir)
  "Returns a string list, all are relative path. Never starts with slash."
  (let* ((vc-root (recentz-find-vc-root dir))
	 (default-directory vc-root)
	 (ignore-args (mapcan (lambda (x) (list "--ignore" (concat x "/"))) recentz-vc-directory-names))
	 ;; --hidden:   include files starts with .
	 (all-files-in-project-relpath (apply #'recentz-call-process-to-string-list `("ag" "--nocolor" "--hidden" ,@ignore-args "--filename-pattern" ,(shell-quote-argument patt))))
	 (recent-files-abspath (cl-remove-if-not (lambda (r) (string-prefix-p vc-root r)) (recentz-get 'files)))
	 (recent-files-relpath (mapcar (lambda (x) (substring x (length vc-root))) recent-files-abspath))
	 (final-files-relpath (append recent-files-relpath (cl-remove-if (lambda (x) (member x recent-files-relpath)) all-files-in-project-relpath))))
    final-files-relpath))

(defun recentz-find-file-by-relpath (relative-path)
  "Open file by calling `find-file'"
  (let ((abs-path (concat (recentz-find-vc-root) relative-path)))
    (find-file abs-path)))

;;;###autoload
(defun recentz--helm-find-file-in-project (&optional dir)
  (interactive)
  (let ((vc-root (recentz-find-vc-root (or dir default-directory))))
    (if vc-root
        (helm :sources (helm-build-sync-source "recentz-find-file-in-project"
                         :candidates (lambda () (recentz-get-file-list-in-project helm-pattern vc-root))
                         :volatile t
                         :action #'recentz-find-file-by-relpath
                         :candidate-number-limit 300
                         :header-name (lambda (_) (format "Project: %s"
							  (file-name-base (directory-file-name vc-root))))
                         )
	      :buffer "*Recentz in Project*"
	      :prompt "File name in project: ")
      (message "Not in a project. Abort."))))


;; ======================================================
;; Alias for helm- namespace convention
;; ======================================================

(defalias 'helm-recentz-files                'recentz--helm-files)
(defalias 'helm-recentz-projects             'recentz--helm-projects)
(defalias 'helm-recentz-directories          'recentz--helm-directories)
(defalias 'helm-recentz-tramp-files          'recentz--helm-tramp-files)
(defalias 'helm-recentz-tramp-projects       'recentz--helm-tramp-projects)
(defalias 'helm-recentz-tramp-directories    'recentz--helm-tramp-directories)
(defalias 'helm-recentz-find-file-in-project 'recentz--helm-find-file-in-project)

;; ======================================================
;; Entry points (auto select helm / ido)
;; ======================================================
;;;###autoload
(defun recentz-files (&optional arg)
  "List recently opened files."
  (interactive "P")
  (funcall (intern (format "recentz--%s-files" recentz-ui)) arg))

;;;###autoload
(defun recentz-projects (&optional arg)
  "List recently opened projects."
  (interactive "P")
  (funcall (intern (format "recentz--%s-projects" recentz-ui)) arg))

;;;###autoload
(defun recentz-directories (&optional arg)
  "List recently opened directories."
  (interactive "P")
  (funcall (intern (format "recentz--%s-directories" recentz-ui)) arg))

;;;###autoload
(defun recentz-tramp-files ()
  "List recent files opened via TRAMP. Notice this will not automatically clear inexistent item from list."
  (interactive)
  (funcall (intern (format "recentz--%s-tramp-files" recentz-ui))))

;;;###autoload
(defun recentz-tramp-projects ()
  "List recent projects opened via TRAMP. Notice this will not automatically clear inexistent item from list."
  (interactive)
  (funcall (intern (format "recentz--%s-tramp-projects" recentz-ui))))

;;;###autoload
(defun recentz-tramp-directories ()
  "List recent directories opened via TRAMP. Notice this will not automatically clear inexistent item from list."
  (interactive)
  (funcall (intern (format "recentz--%s-tramp-directories" recentz-ui))))

  (provide 'recentz)
