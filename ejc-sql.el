;;; ejc-sql.el --- Emacs SQL client uses Clojure JDBC. -*- lexical-binding: t -*-

;;; Copyright © 2012-2018 - Kostafey <kostafey@gmail.com>

;; Author: Kostafey <kostafey@gmail.com>
;; URL: https://github.com/kostafey/ejc-sql
;; Keywords: sql, jdbc
;; Version: 0.0.1
;; Package-Requires: ((emacs "24.4")(clomacs "0.0.3")(dash "2.12.1")(auto-complete "1.5.1")(spinner "1.7.1")(direx "1.0.0"))

;; This file is not part of GNU Emacs.

;;; This program is free software; you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 2, or (at your option)
;;; any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program; if not, write to the Free Software Foundation,
;;; Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.  */

;;; Commentary:

;; ejc-sql turns Emacs into simple SQL client, it uses JDBC connection to
;; databases via clojure/java.jdbc lib.

;; See README.md for detailed description.

;;; Code:

(require 'sql)
(require 'dash)
(require 'cl-lib)
(require 'ejc-lib)
(require 'ejc-direx)
(require 'ejc-format)
(require 'ejc-interaction)
(require 'ejc-result-mode)
(require 'ejc-autocomplete)

(defvar-local ejc-db nil
  "JDBC connection info for current SQL buffer.")

(defvar ejc-connections nil
  "List of existing configured jdbc connections")

(defvar ejc-results-buffer nil
  "The results buffer.")

(defvar ejc-results-buffer-name "*ejc-sql-output*"
  "The results buffer name.")

(defvar ejc-temp-editor-buffer-name "*ejc-sql-editor*"
  "The buffer for conveniently edit ad-hoc SQL scripts.")

(defvar ejc-temp-editor-file (expand-file-name "~/tmp/ejc-sql-editor.sql"))

(defvar ejc-show-results-buffer t
  "When t show results in separate buffer, use minibuffer otherwise.")

(defcustom ejc-keymap-prefix (kbd "C-c e")
  "ejc-sql keymap prefix."
  :group 'ejc-sql
  :type 'string)

(defcustom ejc-date-output-format "%d.%m.%Y %H:%M:%S"
  "ejc-sql date output format."
  :group 'ejc-sql
  :type 'string)

(defvar ejc-sql-mode-keymap (make-keymap) "ejc-sql-mode keymap.")
(define-key ejc-sql-mode-keymap (kbd "C-c C-c") 'ejc-eval-user-sql-at-point)
(define-key ejc-sql-mode-keymap (kbd "C-h t") 'ejc-describe-table)
(define-key ejc-sql-mode-keymap (kbd "C-h T") 'ejc-describe-entity)
(define-key ejc-sql-mode-keymap (kbd "C-M-S-b") '(lambda() (interactive) (ejc-previous-sql t)))
(define-key ejc-sql-mode-keymap (kbd "C-M-S-f") '(lambda() (interactive) (ejc-next-sql t)))
(define-key ejc-sql-mode-keymap (kbd "C-M-b") 'ejc-previous-sql)
(define-key ejc-sql-mode-keymap (kbd "C-M-f") 'ejc-next-sql)

(defvar ejc-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<up>") #'ejc-show-last-result)
    (define-key map (kbd "t") #'ejc-show-tables-list)
    (define-key map (kbd "T") #'ejc-show-user-types-list)
    (define-key map (kbd "s") #'ejc-strinp-sql-at-point)
    (define-key map (kbd "S") #'ejc-dress-sql-at-point)
    (define-key map (kbd "p") #'ejc-pretty-print-sql-at-point)
    map)
  "Keymap for ejc-sql commands after `ejc-keymap-prefix'.")
(fset 'ejc-command-map ejc-command-map)

(define-key ejc-sql-mode-keymap ejc-keymap-prefix 'ejc-command-map)

(defvar ejc-sql-minor-mode-exit-hook nil
  "*Functions to be called when `ejc-sql-mode' is exited.")

(defvar ejc-sql-minor-mode-hook nil
  "*Functions to be called when `ejc-sql-mode' is entered.")

(defvar ejc-sql-mode nil)

(defvar ejc-conn-statistics (list)
  "Keep connection usage statistics and offer most frequently used first
 when `ejc-connect' is called.")

(defcustom ejc-conn-statistics-file (expand-file-name
                                     "~/.ejc-sql/connection-statistics.el")
  "Connection usage statistics data file location."
  :group 'ejc-sql
  :type 'string)

;;;###autoload
(define-minor-mode ejc-sql-mode
  "Toggle ejc-sql mode."
  :lighter " ejc"
  :keymap ejc-sql-mode-keymap
  :group 'ejc
  :global nil
  ;; :after-hook (ejc-create-menu)
  (if ejc-sql-mode
      (progn
        (ejc-ac-setup)
        (ejc-create-menu)
        (run-hooks 'ejc-sql-minor-mode-hook))
    (progn
      ;; (global-unset-key [menu-bar ejc-menu])
      (run-hooks 'ejc-sql-minor-mode-exit-hook))))

;;;###autoload
(defun ejc-create-menu ()
  (define-key-after
    ejc-sql-mode-keymap
    [menu-bar ejc-menu]
    (cons "ejc-sql" (make-sparse-keymap "ejc-sql mode"))
    'tools )
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu ev]
    '("Eval SQL" . ejc-eval-user-sql-at-point))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu fs]
    '("Format SQL" . ejc-format-sql-at-point))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu ms]
    '("Mark SQL" . ejc-mark-this-sql))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu tl]
    '("Show tables list" . ejc-show-tables-list))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu cl]
    '("Show constraints list" . ejc-show-constraints-list))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu pl]
    '("Show procedures list" . ejc-show-procedures-list))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu ss]
    '("Strip SQL" . ejc-strinp-sql-at-point))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu ds]
    '("Dress SQL" . ejc-dress-sql-at-point))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu ol]
    '("Open log" . ejc-open-log))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu sl]
    '("Show last result" . ejc-show-last-result))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu qc]
    '("Quit connection" . ejc-quit-connection)))

(cl-defun ejc-create-connection (connection-name
                                 &key
                                 classpath
                                 classname
                                 subprotocol
                                 subname
                                 subname
                                 user
                                 password
                                 database
                                 connection-uri
                                 separator)
  "Add new connection configuration named CONNECTION-NAME
to `ejc-connections' list or replace existing with the same CONNECTION-NAME."
  (setq ejc-connections (-remove (lambda (x) (equal (car x) connection-name))
                                 ejc-connections))
  (setq ejc-connections (cons (cons
                               connection-name
                               (make-ejc-db-conn
                                :classpath (file-truename classpath)
                                :classname classname
                                :subprotocol subprotocol
                                :subname subname
                                :user user
                                :password password
                                :database database
                                :connection-uri connection-uri
                                :separator separator))
                              ejc-connections)))

(defun ejc-find-connection (connection-name)
  "Return pair with name CONNECTION-NAME and db connection structure from
`ejc-connections'."
  (-find (lambda (x) (equal (car x) connection-name))
         ejc-connections))

(defvar ejc-product-assoc
  '((sqlserver . ms)))

(defun ejc-configure-sql-buffer (product-name)
  (sql-mode)
  (sql-set-product (or (cdr (assoc-string product-name ejc-product-assoc))
                       (car (assoc-string product-name sql-product-alist))
                       "ansi"))
  (auto-complete-mode t)
  (auto-fill-mode t)
  (ejc-sql-mode)
  (ejc-sql-mode t))

(defun ejc-load-conn-statistics ()
  "Load connection usage statistics to `ejc-conn-statistics' var."
  (condition-case nil
      (let ((dir (file-name-directory ejc-conn-statistics-file)))
        (if (not (file-accessible-directory-p dir))
            (make-directory dir))
        (load-file ejc-conn-statistics-file))
    (error
     (with-temp-file ejc-conn-statistics-file
       (insert "(setq ejc-conn-statistics (list))"))
     (load-file ejc-conn-statistics-file)))
  ejc-conn-statistics)

(defun ejc-update-conn-statistics (connection-name)
  "Update connection usage statistics, persist it in `ejc-conn-statistics-file'"
  (setq ejc-conn-statistics
        (lax-plist-put
         ejc-conn-statistics
         connection-name
         (1+ (or (lax-plist-get ejc-conn-statistics connection-name) 0))))
  (with-temp-file ejc-conn-statistics-file
    (insert "(setq ejc-conn-statistics '")
    (prin1 ejc-conn-statistics (current-buffer))
    (insert ")")))

;;;###autoload
(defun ejc-connect (connection-name)
  "Connect to selected db."
  (interactive
   (list
    (ido-completing-read
     "DataBase connection name: "
     (let ((conn-list (mapcar 'car ejc-connections))
           (conn-statistics (ejc-load-conn-statistics)))
       (-sort (lambda (c1 c2)
                (> (or (lax-plist-get conn-statistics c1) 0)
                   (or (lax-plist-get conn-statistics c2) 0)))
              conn-list)))))
  (let ((db (cdr (ejc-find-connection connection-name))))
    (ejc-update-conn-statistics connection-name)
    (ejc-configure-sql-buffer (ejc-db-conn-subprotocol db))
    (setq-local ejc-connection-name connection-name)
    (setq-local ejc-db (ejc-connection-struct-to-plist db))
    (message "Connection started...")
    (ejc-connect-to-db db)
    (setq mode-name (format "%s->[%s]" mode-name connection-name))
    (message "Connected.")))

;;;###autoload
(defun ejc-connect-existing-repl (host port)
  "Connect to existing ejc-sql nREPL running process.
You can `cd` to your ejc-sql project folder (typically
'~/.emacs.d/elpa/ejc-sql-<version>') and launch nREPL via `lein run`.
Then run in Emacs `ejc-connect-existing-repl', type HOST and PORT
from your `lein run` console output. Finally, use `ejc-connect' from
any SQL buffer to connect to exact database, as always. "
  (interactive (cider-select-endpoint))
  (cider-connect host port)
  (let ((current-repl-b-name
         (format nrepl-repl-buffer-name-template (concat " " host)))
        (ejc-repl-b-name
         (format nrepl-repl-buffer-name-template " ejc-sql")))
    (with-current-buffer current-repl-b-name
      (rename-buffer ejc-repl-b-name))))

(defun ejc-get-word-at-point (pos)
  "Return SQL word around the point."
  (interactive "d")
  (let* ((char (char-after pos))
         (str (char-to-string char)))
    (save-excursion
      (let* ((end (if (member str '(" " ")" "<" ">" "="))
                      (point)
                    (progn
                      (forward-sexp 1)
                      (point))))
             (beg (progn
                    (forward-sexp -1)
                    (point)))
             (sql-word (buffer-substring beg end)))
        sql-word))))

(defun ejc-get-prompt-symbol-under-point (msg)
  (let ((sql-symbol (if mark-active
                        (buffer-substring (mark) (point))
                      (ejc-get-word-at-point (point))))
        (enable-recursive-minibuffers t)
        val)
    (setq val (completing-read
               (if sql-symbol
                   (format "%s (default %s): " msg sql-symbol)
                 (format "%s: " msg))
               obarray))
    (list (if (equal val "")
              sql-symbol
            val))))

(defun ejc-check-connection ()
  (unless (ejc-buffer-connected-p)
    (error "Run M-x ejc-connect first!")))

(defun ejc-describe-table (table-name)
  "Describe SQL table TABLE-NAME (default table name - word around the point)."
  (interactive (ejc-get-prompt-symbol-under-point "Describe table"))
  (ejc-check-connection)
  (let* ((owner (car (split-string table-name "\\.")))
         (table (cadr (split-string table-name "\\."))))
    (when (not table)
      (setq table owner)
      (setq owner nil))
    (ejc-show-last-result
     (concat
      (ejc-get-table-meta ejc-db table-name)
      "\n"
      (let ((sql (ejc-select-db-meta-script ejc-db :constraints
                                            :owner owner
                                            :table table)))
        (if (ejc-not-nil-str sql)
            (let ((constraints (ejc-eval-sql-and-log ejc-db sql)))
              (if (and constraints
                       (not (equal (string-trim constraints) "nil")))
                  (concat
                   "Constraints:\n"
                   "------------\n"
                   constraints)
                  ""))
          ""))))))

(defun ejc-describe-entity (entity-name)
  "Describe SQL entity ENTITY-NAME - function, procedure, type or view
   (default entity name - word around the point)."
  (interactive (ejc-get-prompt-symbol-under-point "Describe entity"))
  (ejc-check-connection)
  (ejc-show-last-result
   (let ((entity-result
          ;; Try to get entity source code.
          (ejc-eval-sql-and-log
           ejc-db
           (ejc-select-db-meta-script ejc-db :entity
                                      :entity-name entity-name))))
     (if (not (equal entity-result "nil"))
         ;; Show entity text.
         ;; Assume there is no entity and view with the same names.
         entity-result
       ;; No entity with such name.
       ;; Try to get view source code.
       (ejc-eval-sql-and-log
        ejc-db
        (ejc-select-db-meta-script ejc-db :view
                                   :entity-name entity-name))))))

(cl-defun ejc-eval-user-sql (sql &key sync rows-limit)
  "Evaluate SQL by user: reload and show query results buffer, update log."
  (message "Processing SQL query...")
  (cl-labels ((msg-done (start-time res)
                        (if ejc-show-results-buffer
                            (message
                             "%s SQL query at %s. Exec time %.03f"
                             (if (not
                                  (and
                                   (>= (length res) 5)
                                   (equal
                                    (downcase (cl-subseq res 0 5)) "error")))
                                 (propertize
                                  "Done" 'face 'font-lock-keyword-face)
                               (propertize
                                "Error" 'face 'error))
                             (format-time-string ejc-date-output-format
                                                 (current-time))
                             (float-time (time-since start-time))))))
    (let ((start-time (current-time)))
      (if sync
          (progn
            (let ((res (ejc-eval-sql-and-log ejc-db
                                             sql
                                             :rows-limit rows-limit)))
              (ejc-show-last-result res)
              (msg-done start-time res)))
        (ejc-eval-sql-and-log  ejc-db
                               sql
                               :call-type :async
                               :callback (lambda (res)
                                           (ejc-show-last-result res)
                                           (msg-done start-time res))
                               :rows-limit rows-limit)))))

(defun ejc-eval-user-sql-region (beg end)
  "Evaluate SQL bounded by the selection area."
  (interactive "r")
  (ejc-check-connection)
  (let ((sql (buffer-substring beg end)))
    (ejc-eval-user-sql sql)))

(cl-defun ejc-eval-user-sql-at-point (&optional sync)
  "Evaluate SQL bounded by the `ejc-sql-separator' or/and buffer
boundaries."
  (interactive)
  (ejc-check-connection)
  (ejc-flash-this-sql)
  (ejc-eval-user-sql (ejc-get-sql-at-point) :sync sync))

(defun ejc-show-tables-list ()
  "Output tables list."
  (interactive)
  (ejc-check-connection)
  (ejc-eval-user-sql
   (ejc-select-db-meta-script ejc-db :all-tables)
   :rows-limit 0))

(defun ejc-show-user-types-list (&optional owner)
  "Output user types list."
  (interactive)
  (ejc-check-connection)
  (ejc-eval-user-sql (ejc-select-db-meta-script ejc-db :types
                                                :owner owner)))

(defun ejc-show-constraints-list (&optional owner table)
  "Output constraints list."
  (interactive)
  (ejc-check-connection)
  (ejc-eval-user-sql (ejc-select-db-meta-script ejc-db :constraints
                                                :owner owner
                                                :table table)))

(defun ejc-show-procedures-list (&optional owner)
  "Output procedures list."
  (interactive)
  (ejc-eval-user-sql (ejc-select-db-meta-script ejc-db :procedures
                                                :owner owner)))

;;-----------------------------------------------------------------------------
;; results buffer
;;
(defun ejc-create-output-buffer ()
  (set-buffer (get-buffer-create ejc-results-buffer-name))
  (setq ejc-results-buffer (current-buffer))
  (ejc-result-mode)
  ejc-results-buffer)

(defun ejc-get-buffer-or-create (buffer-or-name create-buffer-fn)
  "Return buffer passed in `buffer-or-name' parameter.
If this buffer is not exists or it was killed - create buffer via
`create-buffer-fn' function (this function must return buffer)."
  (let ((buf (if (bufferp buffer-or-name)
                 buffer-or-name
               (get-buffer buffer-or-name))))
    (if (and buf (buffer-live-p buf))
        buf
      (apply create-buffer-fn nil))))

(defun ejc-get-output-buffer ()
  (if (and ejc-results-buffer (buffer-live-p ejc-results-buffer))
      ejc-results-buffer
    (ejc-create-output-buffer)))

(defun ejc-toggle-show-results-buffer ()
  (interactive)
  (if ejc-show-results-buffer
      (setq ejc-show-results-buffer nil)
    (setq ejc-show-results-buffer t)))

(defun ejc-show-last-result (&optional result)
  "Popup buffer with last SQL execution result output."
  (interactive)
  (if ejc-show-results-buffer
      (let ((output-buffer (ejc-get-output-buffer))
            (old-split split-width-threshold))
        (set-buffer output-buffer)
        (when result
          (read-only-mode -1)
          (erase-buffer)
          (insert result))
        (read-only-mode 1)
        (beginning-of-buffer)
        (setq split-width-threshold nil)
        (display-buffer output-buffer)
        (setq split-width-threshold old-split))
    (let ((result-lines (split-string result "\n")))
      (message "%s"
               (if (<= (length result-lines) 3)
                   (apply 'concat (cl-subseq result-lines 0 3))
                 (concat (apply 'concat (cl-subseq result-lines 0 3))
                         "... ("
                         (number-to-string (- (length result-lines) 3))
                         " more)"))))))

(defun ejc-switch-to-sql-editor-buffer ()
  "Switch to buffer dedicated to ad-hoc edit and SQL scripts.
If the buffer is not exists - create it.
Buffer can be saved to file with `ejc-temp-editor-file' path."
  (interactive)
  (if (get-buffer ejc-temp-editor-buffer-name)
      (switch-to-buffer ejc-temp-editor-buffer-name)
    (progn
      (unless (file-exists-p
               (file-name-directory ejc-temp-editor-file))
        (make-directory (file-name-directory ejc-temp-editor-file) t))
      (find-file ejc-temp-editor-file)
      (rename-buffer ejc-temp-editor-buffer-name)
      (ejc-configure-sql-buffer "ansi"))))

(defun ejc-open-log ()
  (interactive)
  (find-file-read-only (ejc-get-log-file-path))
  (end-of-buffer))

(provide 'ejc-sql)

;;; ejc-sql.el ends here
