;;; project-explorer.el --- A project explorer sidebar -*- lexical-binding: t -*-
;;; Version: 0.1
;;; Author: sabof
;;; URL: https://github.com/sabof/project-explorer
;;; Package-Requires: ((cl-lib "1.0") (es-lib "0.3"))

;;; Commentary:

;; The project is hosted at https://github.com/sabof/project-explorer
;; The latest version, and all the relevant information can be found there.

;;; License:

;; This file is NOT part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program ; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Code:

(require 'cl-lib)
(require 'es-lib)
(require 'hideshow)
(require 'dired)

(defgroup project-explorer nil
  "A project explorer sidebar."
  :group 'convenience)

(defvar pe/directory-files-function
  'pe/get-directory-tree-simple)

(defcustom pe/side 'left
  "On which side to display the sidebar."
  :group 'project-explorer
  :type '(radio
          (const :tag "Left" left)
          (const :tag "Right" right)))

(defcustom pe/width 40
  "Width of the side-bar."
  :group 'project-explorer
  :type 'integer)

(defcustom pe/omit-regex "^\\.\\|^#\\|~$"
  "Specify which files to omit"
  :group 'project-explorer
  :type '(choice
          (const :tag "Show all files" nil)
          (string :tag "Files matching this regex won't be shown")))

(defvar-local pe/data nil)
(defvar-local pe/folds-open nil)
(defvar-local pe/previous-directory nil)
(defvar-local pe/project-root nil)

(defvar pe/project-root-function
  (lambda ()
    (if (fboundp 'projectile-project-root)
        (projectile-project-root)
      (expand-file-name
       (locate-dominating-file default-directory ".git")))))

(cl-defun pe/get-directory-tree-simple (dir done-func)
  (let (walker)
    (setq walker
          (lambda (dir)
            (let (( files (cl-remove-if
                           (lambda (file)
                             (or (member file '("." ".."))
                                 (not (pe/file-interesting-p file))))
                           (directory-files dir))))
              (cons (file-name-nondirectory (directory-file-name dir))
                    (mapcar (lambda (file)
                              (if (file-directory-p (concat dir file))
                                  (funcall walker (concat dir file "/"))
                                file))
                            files)))))
    (funcall done-func (funcall walker dir))))

(defun pe/get-project-explorer-buffers ()
  (es-buffers-with-mode 'project-explorer-mode))

(cl-defun pe/revert-buffer (&rest ignore)
  (let (( inhibit-read-only t)
        ( project-explorer-buffer (current-buffer))
        ( starting-name
          (let ((\default-directory
                 (or pe/previous-directory
                     default-directory)))
            (pe/get-filename)))
        ( window-start (window-start))
        ( starting-column (current-column)))
    (erase-buffer)
    (delete-all-overlays)
    (insert "Searching for files...")
    (funcall pe/directory-files-function
             default-directory
             (lambda (result)
               (when result
                 (with-current-buffer project-explorer-buffer
                   (setq pe/data result)
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (pe/print-indented-tree
                      (pe/compress-tree
                       (pe/sort result)))
                     (font-lock-fontify-buffer)
                     (goto-char (point-min)))
                   ))))
    (if (not (string-equal pe/previous-directory
                           default-directory))
        (pe/folds-reset)
      (pe/folds-restore)
      (set-window-start nil window-start)
      (when starting-name
        (pe/goto-file starting-name nil t)
        (move-to-column starting-column)))
    (setq pe/previous-directory default-directory)
    (when (eq this-command 'revert-buffer)
      (message "Refresh complete"))
    ))

(defun pe/file-interesting-p (name)
  (if pe/omit-regex
      (not (string-match-p pe/omit-regex name))
    t))

(cl-defun pe/compress-tree (branch)
  (cond ( (not (consp branch))
          branch)
        ( (= (length branch) 1)
          branch)
        ( (and (= (length branch) 2)
               (consp (cl-second branch)))
          (pe/compress-tree
           (cons (concat (car branch) "/" (cl-caadr branch))
                 (cl-cdadr branch))))
        ( t (cons (car branch)
                  (mapcar 'pe/compress-tree (cdr branch))))))

(cl-defun pe/sort (branch)
  (when (stringp branch)
    (cl-return-from pe/sort branch))
  (let (( new-rest
          (sort (cdr branch)
                (lambda (a b)
                  (cond ( (and (consp a)
                               (stringp b))
                          t)
                        ( (and (stringp a)
                               (consp b))
                          nil)
                        ( (and (consp a) (consp b))
                          (string< (car a) (car b)))
                        ( t (string< a b)))))))
    (setcdr branch (mapcar 'pe/sort new-rest))
    branch
    ))

(cl-defun pe/print-indented-tree (branch &optional (depth -1))
  (let (start)
    (cond ( (stringp branch)
            (insert (make-string depth ?\t)
                    branch
                    ?\n))
          ( t (when (>= depth 0)
                (insert (make-string depth ?\t)
                        (car branch) "/\n")
                (setq start (point)))
              (cl-dolist (item (cdr branch))
                (pe/print-indented-tree item (1+ depth)))
              (when (and start (> (point) start))
                ;; (message "ran %s %s" start (point))
                (pe/make-hiding-overlay (1- start) (1- (point)))
                )
              ))))

(defun pe/folds-add (file-name)
  (cl-assert (file-exists-p file-name) t)
  (prog1 (setq pe/folds-open
               (cons file-name
                     (cl-remove-if
                      (lambda (listed-file-name)
                        (string-prefix-p listed-file-name file-name))
                      pe/folds-open)))
    (cl-assert (cl-every 'file-exists-p pe/folds-open) t)
    ))

(defun pe/folds-remove (file-name)
  (let* (( parent
           (file-name-directory
            (directory-file-name
             file-name)))
         ( new-folds
           (cl-remove-if
            (lambda (listed-file-name)
              (string-prefix-p file-name listed-file-name))
            pe/folds-open))
         ( removed-folds
           (cl-sort (cl-set-difference
                     pe/folds-open
                     new-folds
                     :test 'string-equal)
                    '>
                    :key (lambda (it) (length (split-string it "/" t)))
                    )))
    (setq pe/folds-open new-folds)
    (when (and parent
               (not (string-equal parent default-directory))
               (not (cl-find-if (lambda (file-name)
                                  (string-prefix-p parent file-name))
                                pe/folds-open)))
      (push parent pe/folds-open))
    removed-folds))

(defun pe/folds-reset ()
  (setq pe/folds-open))

(defun pe/folds-restore ()
  (let ((old-folds pe/folds-open))
    (pe/folds-reset)
    (cl-dolist (fold old-folds)
      (pe/goto-file fold nil t)
      (pe/unfold-internal))))

(defun pe/current-indnetation ()
  (- (pe/tab-ending)
     (line-beginning-position)))

(defun pe/tab-ending ()
  (save-excursion
    (goto-char (line-beginning-position))
    (skip-chars-forward "\t")
    (point)))

(cl-defun pe/unfold-internal ()
  (pe/folds-add (pe/get-filename-internal))
  (save-excursion
    (while (let* (( line-end (line-end-position))
                  ( ov (car (cl-remove-if-not
                             (lambda (ov)
                               (= line-end (overlay-start ov)))
                             (overlays-at line-end)))))
             (when ov
               (delete-overlay ov)
               t))
      (pe/up-element-internal))
    ))

(defun pe/unfold-expanded-internal ()
  (save-excursion
    (goto-char (line-beginning-position))
    (let (( end (save-excursion (pe/forward-element))))
      (while (re-search-forward "/$" end t)
        (pe/unfold-internal)))))

(cl-defun pe/unfold (&optional expanded)
  (interactive "P")
  (message "u")
  (let (( line-beginning
          (es-total-line-beginning-position))

        )
    (when (/= (line-number-at-pos)
              (line-number-at-pos
               line-beginning))
      (goto-char line-beginning)
      (goto-char (1- (line-end-position)))
      ))
  (when expanded
    (pe/unfold-expanded-internal)
    (cl-return-from pe/unfold))
  (unless (pe/folded-p)
    (cl-return-from pe/unfold))
  (pe/unfold-internal))

(defun pe/make-hiding-overlay (from to)
  (let ((ov (make-overlay from to)))
    (overlay-put ov 'isearch-open-invisible-temporary
                 'hs-isearch-show-temporary)
    (overlay-put ov 'isearch-open-invisible
                 'hs-isearch-show)
    (overlay-put ov 'invisible 'hs)
    (overlay-put ov 'display "...")
    (overlay-put ov 'hs 'code)
    (overlay-put ov 'is-tf-hider t)
    (overlay-put ov 'evaporate t)
    )
  )

(defun pe/goto-file (file-name &optional on-each-semgent-function use-best-match)
  (let* (( segments (split-string
                     (if (file-name-absolute-p file-name)
                         (substring file-name (length default-directory))
                       file-name)
                     "/" t))
         ( init-pos (point))
         best-match
         found)
    (goto-char (point-min))
    (save-match-data
      (cl-loop with limit
               for segment in segments
               for iter = 0 then (1+ iter)
               ;; for is-final = (= iter (1- (length segments)))
               do (cond ( (and (cl-plusp iter)
                               (save-excursion
                                 (goto-char (match-end 1))
                                 (looking-at-p (concat (regexp-quote segment) "/$"))))
                          (goto-char (match-end 1))
                          (setq best-match (match-end 1))
                          (cl-decf iter))
                        ( (re-search-forward
                           (format "^\t\\{%s\\}\\(?1:%s/?\\)"
                                   (int-to-string iter) segment)
                           limit t)
                          ;; (goto-char (match-beginning 1))
                          (setq limit (save-excursion
                                        (pe/forward-element)))
                          (setq best-match (match-beginning 1))
                          (when on-each-semgent-function
                            (save-excursion
                              (goto-char (match-beginning 1))
                              (funcall on-each-semgent-function))))
                        ( t (cl-return)))
               finally (setq found t)))

    (if (and best-match (or found use-best-match))
        (goto-char best-match)
      (goto-char init-pos)
      nil)))

(defun pe/fold-internal ()
  (let* (( indent
           (save-excursion
             (goto-char (line-beginning-position))
             (skip-chars-forward "\t")
             (buffer-substring (line-beginning-position)
                               (point))))
         ( end
           (save-excursion
             (goto-char (line-end-position 1))
             (let (( regex
                     (format "^\t\\{0,%s\\}[^\t\n]"
                             (length indent))))
               (if (re-search-forward regex nil t)
                   (line-end-position 0)
                 (point-max))))))
    (pe/make-hiding-overlay (line-end-position 1)
                            end)
    ))

(defun pe/fold-until (root ancestor-list)
  (save-excursion
    (let* ((root-point (save-excursion (pe/goto-file root)))
           (locations-to-fold (list root-point)))
      (cl-assert root-point nil
                 "pe/goto-file returned nil for %s"
                 root)
      (cl-dolist (path ancestor-list)
        (cl-pushnew (pe/goto-file path) locations-to-fold)
        (cl-loop (pe/up-element)
                 (if (or (<= (point) root-point)
                         (memq (point) locations-to-fold))
                     (cl-return)
                   (cl-pushnew (point) locations-to-fold)))
        )
      (message "%s" locations-to-fold)
      (cl-dolist (location locations-to-fold)
        (goto-char location)
        (pe/fold-internal))
      )))

(defun pe/folded-p ()
  (let (( ovs (save-excursion
                (goto-char (es-total-line-beginning-position))
                (goto-char (line-end-position))
                (overlays-at (point)))))
    (cl-some (lambda (ov)
               (overlay-get ov 'is-tf-hider))
             ovs)))

(defun pe/up-element-internal ()
  (let (( indentation (pe/current-indnetation)))
    (and (not (zerop indentation))
         (re-search-backward (format
                              "^\\(?1:\t\\{0,%s\\}\\)[^\t\n]"
                              (1- indentation))
                             nil t)
         (goto-char (match-end 1)))))

(defun pe/get-filename-internal ()
  (save-excursion
    (let* (( get-line-text
             (lambda ()
               (goto-char (line-beginning-position))
               (skip-chars-forward "\t ")
               (buffer-substring-no-properties
                (point) (line-end-position))))
           ( result
             (funcall get-line-text)))
      (while (pe/up-element-internal)
        (setq result (concat (funcall get-line-text)
                             result)))
      (setq result (expand-file-name result))
      (when (file-directory-p result)
        (setq result (file-name-as-directory result)))
      (cl-assert (file-exists-p result) nil
                 "No such file %s\n\twith default-directory %s"
                 result default-directory)
      result)))

(defun pe/get-current-project-explorer-buffer ()
  (let (( project-root (funcall pe/project-root-function))
        ( project-explorer-buffers (pe/get-project-explorer-buffers)))
    (cl-find project-root
             project-explorer-buffers
             :key (lambda (project-project-explorer-buffer)
                    (with-current-buffer project-project-explorer-buffer
                      default-directory))
             :test 'string-equal)))

(defun pe/flatten-tree (tree &optional prefix)
  (let ((current-prefix (if prefix
                            (concat prefix "/" (car tree))
                          (car tree))))
    (cl-reduce 'append
               (mapcar (lambda (it)
                         (if (consp it)
                             (pe/flatten-tree it current-prefix)
                           (list (concat current-prefix "/" it))))
                       (cdr tree))))
  )

;; (defun pe/completing-read-files ()
;;   (let ((flat-tree (with-current-buffer pe/get-current-project-explorer-buffer
;;                      ))
;;         (completing-read ))
;;     ))

(defun pe/register-isearch-unfolding ()
  (unless isearch-mode-end-hook-quit
    (let ((file-name (pe/get-filename)))
      (unless (string-match-p "/$" file-name)
        (setq file-name (file-name-directory file-name)))
      (when file-name
        (pe/folds-add file-name)))))

(defun pe/occur-mode-find-occurrence-hook ()
  (save-excursion
    (pe/up-element-internal)
    (pe/unfold-internal)))

(define-derived-mode project-explorer-mode special-mode
  "Tree find"
  "Display results of find as a folding tree"
  (setq-local revert-buffer-function
              'pe/revert-buffer)
  (setq-local tab-width 2)
  (es-define-keys project-explorer-mode-map
    (kbd "u") 'pe/up-element
    (kbd "d") 'pe/set-directory
    (kbd "<tab>") 'pe/tab
    (kbd "M-}") 'pe/forward-element
    (kbd "M-{") 'pe/backward-element
    (kbd "]") 'pe/forward-element
    (kbd "[") 'pe/backward-element
    (kbd "n") 'next-line
    (kbd "p") 'previous-line
    (kbd "j") 'next-line
    (kbd "k") 'previous-line
    (kbd "l") 'forward-char
    (kbd "h") 'backward-char
    ;; (kbd "^") 'pe/up-directory
    (kbd "<return>") 'pe/return
    (kbd "<mouse-2>") 'pe/middle-click
    (kbd "q") 'pe/quit
    (kbd "s") 'isearch-forward
    (kbd "r") 'isearch-backward
    (kbd "f") 'pe/find-file
    )
  (add-hook 'isearch-mode-end-hook
            'pe/register-isearch-unfolding
            nil t)
  (add-hook 'occur-mode-find-occurrence-hook
            'pe/occur-mode-find-occurrence-hook
            nil t)
  (font-lock-add-keywords
   'project-explorer-mode '(("^.+/$" (0 'dired-directory append)))))

;;; Interface

(cl-defun pe/fold ()
  (interactive)
  (when (or (looking-at-p ".*\n?\\'")
            (pe/folded-p))
    (cl-return-from pe/fold))
  (let* (( file-name (pe/get-filename)))
    (pe/fold-until file-name (pe/folds-remove file-name))
    ))

(defun pe/quit ()
  (interactive)
  (let ((window (selected-window)))
    (quit-window)
    (when (window-live-p window)
      (delete-window))))

(defun pe/forward-element (&optional arg)
  (interactive "p")
  (setq arg (or arg 1))
  (save-match-data
    (let* (( initial-indentation
             (es-current-character-indentation))
           ( regex (format "^\t\\{0,%s\\}[^\t\n]"
                           initial-indentation)))
      (if (cl-minusp arg)
          (goto-char (line-beginning-position))
        (goto-char (line-end-position)))
      (when (re-search-forward regex nil t arg)
        (goto-char (match-end 0))
        (forward-char -1)
        (point)))))

(defun pe/backward-element (&optional arg)
  (interactive "p")
  (setq arg (or arg 1))
  (pe/forward-element (- arg)))

(defun pe/middle-click (event)
  (interactive "e")
  (mouse-set-point event)
  (pe/return))

(defun pe/return ()
  (interactive)
  (if (file-directory-p (pe/get-filename))
      (pe/tab)
    (pe/find-file)))

(defun pe/set-directory (dir)
  (interactive
   (let ((file-name (pe/get-filename)))
     (list (read-file-name
            "Set directory to: "
            (if (file-directory-p file-name)
                file-name
              (file-name-directory
               (directory-file-name
                file-name)))))))
  (unless (file-directory-p dir)
    (error "\"%s\" is not a directory"
           dir))
  (setq dir (file-name-as-directory dir))
  (setq default-directory (expand-file-name dir))
  (revert-buffer)
  )

(defun pe/find-file ()
  "Open the file or directory at point."
  (interactive)
  (let ((file-name (pe/get-filename))
        (win (cadr (window-list))))
    (select-window win)
    (find-file file-name)))

(defun pe/tab (&optional arg)
  "Toggle folding at point.
With a prefix argument, unfold all children."
  (interactive "P")
  (if (or arg (pe/folded-p))
      (pe/unfold arg)
    (pe/fold)))

(defun pe/up-element ()
  "Goto the parent element of the file at point.
Joined directories will be traversed as one."
  (interactive)
  (goto-char (es-total-line-beginning-position))
  (pe/up-element-internal))

(defun pe/get-filename ()
  "Return the aboslute file-name of the file at point."
  (interactive)
  (save-excursion
    (goto-char (es-total-line-beginning))
    (pe/get-filename-internal)))

(cl-defun project-explorer-open ()
  "Show the `project-explorer-buffer', of the current project."
  (interactive)
  (let* (( project-root (funcall pe/project-root-function))
         ( project-explorer-buffers (pe/get-project-explorer-buffers))
         ( project-project-explorer-existing-buffer
           (cl-find project-root
                    project-explorer-buffers
                    :key (lambda (project-project-explorer-buffer)
                           (with-current-buffer
                               project-project-explorer-buffer
                             pe/project-root))
                    :test 'string-equal))
         ( project-explorer-window
           (and project-project-explorer-existing-buffer
                (get-window-with-predicate
                 (lambda (project-explorer-window)
                   (eq (window-buffer project-explorer-window)
                       project-project-explorer-existing-buffer))
                 (window-list))))
         ( project-project-explorer-buffer
           (or project-project-explorer-existing-buffer
               (with-current-buffer
                   (generate-new-buffer "*project-explorer*")
                 (project-explorer-mode)
                 (setq default-directory
                       (setq pe/project-root
                             project-root))
                 (revert-buffer)
                 (current-buffer)
                 ))))

    (when project-explorer-window
      (select-window project-explorer-window)
      (cl-return-from project-explorer-open))

    (cl-dolist (window (window-list))
      (and (memq (window-buffer window) project-explorer-buffers)
           (> (length (window-list)) 1)
           (delete-window window)))
    (setq project-explorer-window (split-window (frame-root-window)
                                         (- (frame-width) pe/width) pe/side))
    (set-window-parameter project-explorer-window 'window-side pe/side)
    (set-window-buffer project-explorer-window project-project-explorer-buffer)
    (set-window-dedicated-p project-explorer-window t)
    (select-window project-explorer-window)
    ))

(provide 'project-explorer)
;;; project-explorer.el ends here
