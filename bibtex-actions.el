;;; bibtex-actions.el --- Biblographic commands based on completing-read -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2021 Bruce D'Arcus
;;
;; Author: Bruce D'Arcus <https://github.com/bdarcus>
;; Maintainer: Bruce D'Arcus <https://github.com/bdarcus>
;; Created: February 27, 2021
;; License: GPL-3.0-or-later
;; Version: 0.4
;; Homepage: https://github.com/bdarcus/bibtex-actions
;; Package-Requires: ((emacs "26.3") (bibtex-completion "1.0") (parsebib "3.0"))
;;
;; This file is not part of GNU Emacs.
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;;  A completing-read front-end to bibtex-completion.
;;
;;  This package turns bibtex-completion functions into completing-read-based
;;  Emacs commands.  When used with selectrum/icomplete-vertical, embark, and
;;  marginalia, it provides similar functionality to helm-bibtex and ivy-bibtex:
;;  quick filtering and selecting of bibliographic entries from the minibuffer,
;;  and the option to run different commands against them.
;;
;;; Code:

(require 'bibtex-actions-utils)
(require 'bibtex-completion)
(require 'parsebib)
(require 'filenotify)
(require 's)

(declare-function bibtex-actions-open-files "bibtex-actions")
(declare-function org-element-context "org-element")
(declare-function org-element-property "org-element")
(declare-function org-element-type "org-element")
(declare-function org-cite-get-references "org-cite")
(declare-function org-cite-register-processor "org-cite")
(declare-function org-cite-make-insert-processor "org-cite")
(declare-function org-cite-basic--complete-style "org-cite")
(declare-function embark-act "ext:embark")

;;; Declare variables for byte compiler

(defvar crm-separator)
(defvar embark-keymap-alist)
(defvar embark-target-finders)
(defvar embark-general-map)
(defvar embark-meta-map)

;;; Variables

(defface bibtex-actions
  '((t :inherit font-lock-doc-face))
  "Default Face for `bibtex-actions' candidates."
  :group 'bibtex-actions)

(defface bibtex-actions-highlight
  '((t :weight bold))
  "Face used to highlight content in `bibtex-actions' candidates."
  :group 'bibtex-actions)

(defcustom bibtex-actions-bibliography
  (bibtex-actions--normalize-paths bibtex-completion-bibliography)
  "A list of bibliography files."
  ;; The bibtex-completion default is likely to be removed in the future.
  :group 'bibtex-actions
  :type '(repeat file))

(defcustom bibtex-actions-library-paths
  (bibtex-actions--normalize-paths bibtex-completion-library-path)
  "A list of files paths for related PDFs, etc."
  ;; The bibtex-completion default is likely to be removed in the future.
  :group 'bibtex-actions
  :type '(repeat path))

(defcustom bibtex-actions-file-extensions '("pdf" "org" "md")
  "A list of file extensions to recognize for related files."
  :group 'bibtex-actions
  :type '(repeat string))

(defcustom bibtex-actions-notes-paths
  (bibtex-actions--normalize-paths bibtex-completion-notes-path)
  "A list of file paths for bibliographic notes."
  ;; The bibtex-completion default is likely to be removed in the future.
  :group 'bibtex-actions
  :type '(repeat path))

(defcustom  bibtex-actions-file-variable "file"
  "The field key to look for in an entry for PDF, etc."
  :group 'bibtex-actions
  :type '(string))

(defcustom bibtex-actions-open-file-function 'find-file
  "Function to use to open files."
  ;; tODO maybe this should be higher-level; eg:
  ;; 'bibtex-actions-open-file?
  :group 'bibtex-actions
  :type '(function))

(defcustom bibtex-actions-open-library-file-external t
  "Whether to open a library file in an external application."
  :group 'bibtex-actions
  :type '(boolean))


(defcustom bibtex-actions-template
  '((t . "${author:30}   ${date:8}  ${title:48}"))
  "Configures formatting for the BibTeX entry.
When combined with the suffix, the same string is used for
display and for search."
    :group 'bibtex-actions
    :type  '(alist :key-type symbol :value-type function))

(defcustom bibtex-actions-template-suffix
  '((t . "          ${=key=:15}    ${=type=:12}    ${tags:*}"))
  "Configures formatting for the BibTeX entry suffix.
When combined with the main template, the same string is used for
display and for search."
    :group 'bibtex-actions
    :type  '(alist :key-type symbol :value-type function))

(defcustom bibtex-actions-link-symbol "🔗"
  "Symbol to indicate a DOI or URL link is available for a publication.
This should be a single character."
  :group 'bibtex-actions
  :type 'string)

(defcustom bibtex-actions-symbols
  `((file  .     (,bibtex-completion-pdf-symbol . " "))
    (note .     (,bibtex-completion-notes-symbol . " "))
    (link .     (,bibtex-actions-link-symbol . " ")))
  "Configuration alist specifying which symbol or icon to pick for a bib entry.
This leaves room for configurations where the absense of an item
may be indicated with the same icon but a different face."
  :group 'bibtex-actions
  :type '(alist :key-type string
                :value-type (choice (string :tag "Symbol"))))

(defcustom bibtex-actions-symbol-separator " "
  "The padding between prefix symbols."
  :group 'bibtex-actions
  :type 'string)

(defcustom bibtex-actions-force-refresh-hook nil
  "Hook run when user forces a (re-) building of the candidates cache.
This hook is only called when the user explicitly requests the
cache to be rebuilt.  It is intended for 'heavy' operations which
recreate entire bibliography files using an external reference
manager like Zotero or JabRef."
  :group 'bibtex-actions
  :type '(repeat function))

(defvar bibtex-actions-field-map
  '(("date" "year" "issued")
    ("=key=" "id")
    ("=type=" "type")
    ("tags" "keywords" "keyword")
    ("booktitle" "container-title")
    ("journaltitle" "journal" "container-title")
    ("number" "issue")))

(defvar bibtex-actions-field-mapping
  '(("issued" "date" "year")
    ("=key=" "id")
    ("=type=" "type")
    ("keyword" "tags" "keywords")
    ("container-title" "booktitle" "journaltitle" "journal")
    ("issue" "number")))

(defcustom bibtex-actions-default-action 'bibtex-actions-open
  "The default action for the `bibtex-actions-at-point' command."
  :group 'bibtex-actions
  :type 'function)

(defcustom bibtex-actions-at-point-fallback 'prompt
  "Fallback action for `bibtex-actions-at-point'.
The action is used when no citation key is found at point.
`prompt' means choosing entries via `bibtex-actions-read' and nil
means no action."
  :group 'bibtex-actions
  :type '(choice (const :tag "Prompt" 'prompt)
                 (const :tag "Ignore" nil)))

(defcustom bibtex-actions-at-point-function 'bibtex-actions-dwim
  "The function to run for 'bibtex-actions-at-point'."
  :group 'bibtex-actions
  :type 'function)

(defcustom bibtex-actions-filenotify-callback 'invalidate-cache
  "The callback that is run when the bibliography related files change.
Its value can be either 'invalidate-cache, 'refresh-cache or else a function.
The function takes two arguments. The first is the scope, which is `global' when
the changed file is in `bibtex-actions-filenotify-files' and `local' otherwise.
The second is the change that occured. This is the argument that the callback of
`file-notify-add-watch' accepts. This argument must be optional. The callback is
called without it when `bibtex-actions-filenotify-refresh' is run"
  :group 'bibtex-actions
  :type '(choice (const invalidate-cache)
                 (const refresh-cache)
                 function))

(defcustom bibtex-actions-filenotify-files '(bibliography)
  "The files to watch using filenotify."
  :group 'bibtex-actions
  :type '(repeat (choice (const bibliogrpahy)
                         (const library)
                         (const notes)
                         string)))

;;; History, including future history list.

(defvar bibtex-actions-history nil
  "Search history for `bibtex-actions'.")

(defcustom bibtex-actions-presets nil
  "List of predefined searches."
  :group 'bibtex-actions
  :type '(repeat string))

;;; Keymaps

(defvar bibtex-actions-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "t") '("add pdf attachment" . bibtex-actions-add-pdf-attachment))
    (define-key map (kbd "a") '("add pdf to library" . bibtex-actions-add-pdf-to-library))
    (define-key map (kbd "b") '("insert bibtex" . bibtex-actions-insert-bibtex))
    (define-key map (kbd "c") '("insert citation" . bibtex-actions-insert-citation))
    (define-key map (kbd "k") '("insert key" . bibtex-actions-insert-key))
    (define-key map (kbd "f") '("insert formatted reference" . bibtex-actions-insert-reference))
    (define-key map (kbd "o") '("open source document" . bibtex-actions-open))
    (define-key map (kbd "e") '("open bibtex entry" . bibtex-actions-open-entry))
    (define-key map (kbd "l") '("open source URL or DOI" . bibtex-actions-open-link))
    (define-key map (kbd "n") '("open notes" . bibtex-actions-open-notes))
    (define-key map (kbd "p") '("open library files" . bibtex-actions-open-library-files))
    (define-key map (kbd "r") '("refresh" . bibtex-actions-refresh))
    ;; Embark doesn't currently use the menu description.
    ;; https://github.com/oantolin/embark/issues/251
    (define-key map (kbd "RET") '("default action" . bibtex-actions-run-default-action))
    map)
  "Keymap for 'bibtex-actions'.")

(defvar bibtex-actions-buffer-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "o") '("open source document" . bibtex-actions-open))
    (define-key map (kbd "e") '("open bibtex entry" . bibtex-actions-open-entry))
    (define-key map (kbd "l") '("open source URL or DOI" . bibtex-actions-open-link))
    (define-key map (kbd "n") '("open notes" . bibtex-actions-open-notes))
    (define-key map (kbd "p") '("open library files" . bibtex-actions-open-library-files))
    (define-key map (kbd "r") '("refresh library" . bibtex-actions-refresh))
    ;; Embark doesn't currently use the menu description.
    ;; https://github.com/oantolin/embark/issues/251
    (define-key map (kbd "RET") '("default action" . bibtex-actions-run-default-action))
    map)
  "Keymap for Embark citation-key actions.")

;;; Completion functions
(cl-defun bibtex-actions-read (&optional &key multiple rebuild-cache)
  "Read bibtex-completion entries.

Provides a wrapper around 'completing-read' and
'completing-read-multiple', with the following optional
arguments:

MULTIPLE uses 'completing-read-multiple'; default is
'completing-read'.

'REBUILD-CACHE' if t, forces rebuilding the cache before
offering the selection candidates"
  (let* ((crm-separator "\\s-*&\\s-*")
	 (candidates (bibtex-actions--get-candidates rebuild-cache))
         (chosen
          (if multiple
              (completing-read-multiple
               "References: "
               (lambda (string predicate action)
                 (if (eq action 'metadata)
                     `(metadata
                       (affixation-function . bibtex-actions--affixation)
                       (category . bibtex))
                   (complete-with-action action candidates string predicate)))
               nil
               nil
               'bibtex-actions-history bibtex-actions-presets nil)
            (completing-read
             "References: "
             (lambda (string predicate action)
               (if (eq action 'metadata)
                   '(metadata
                     (affixation-function . bibtex-actions--affixation)
                     (category . bibtex))
                 (complete-with-action action candidates string predicate)))))))
    (if (not multiple)
        (cdr (assoc chosen candidates))
      (cl-loop for choice in chosen
               ;; Collect citation keys of selected candidate(s).
               collect (cdr (assoc choice candidates))))))

(defun bibtex-actions--local-files-to-cache ()
  "The local bibliographic files not included in the global bibliography."
  ;; We cache these locally to the buffer.
  (let* ((local-bib-files
          (bibtex-actions--normalize-paths
           (bibtex-completion-find-local-bibliography))))
    (seq-difference local-bib-files bibtex-actions-bibliography)))

(defun bibtex-actions-get-value (field item &optional default)
  "Return biblatex FIELD value for ITEM.
When nil, return DEFAULT."
  (or (cdr (assoc-string field item 'case-fold))
      (cl-loop for fname in (cdr (assoc field bibtex-actions-field-map))
               when (cdr (assoc-string fname item 'case-fold))
                         return (cdr (assoc-string fname item 'case-fold)))
      default))

(defun bibtex-actions-shorten-names (names)
  "Return a list of family names from a list of full NAMES.

To better accomomodate corporate names, this will only shorten
personal names of the form 'family, given'."
  (when (stringp names)
    (mapconcat
     (lambda (name)
       (if (eq 1 (length name))
           (cdr (split-string name " "))
         (car (split-string name ", "))))
     (split-string names " and ") ", ")))

(defun bibtex-actions--format-candidates (files &optional context)
  "Format candidates from FILES, with optional hidden CONTEXT metadata.
This both propertizes the candidates for display, and grabs the
key associated with each one."
  (let* ((main-template
         (bibtex-actions--process-display-formats
          bibtex-actions-template))
         (suffix-template
          (bibtex-actions--process-display-formats
           bibtex-actions-template-suffix))
         (main-width (truncate (* (frame-width) 0.65)))
         (suffix-width (truncate (* (frame-width) 0.34))))
    (cl-loop for candidate being the hash-values of (parsebib-parse files)
             collect
             (let* ((files
                     (when (or (bibtex-actions-get-value
                                bibtex-actions-file-variable candidate)
                               (bibtex-actions--files-for-key
                                (bibtex-actions-get-value "=key=" candidate)
                                bibtex-actions-library-paths bibtex-actions-file-extensions))
                       " has:files"))
                    (notes
                     (when (bibtex-actions--files-for-key
                            (bibtex-actions-get-value "=key=" candidate)
                            bibtex-actions-notes-paths bibtex-actions-file-extensions)
                           " has:notes"))
                    (link (when (or (assoc "doi" (cdr candidate))
                                  (assoc "url" (cdr candidate))) "has:link"))
                    (citekey (bibtex-actions-get-value "=key=" candidate))
                    (candidate-main
                     (bibtex-actions--format-entry
                      candidate
                      main-width
                      main-template))
                    (candidate-suffix
                     (bibtex-actions--format-entry
                      candidate
                      suffix-width
                      suffix-template))
                    ;; We display this content already using symbols; here we add back
                    ;; text to allow it to be searched, and citekey to ensure uniqueness
                    ;; of the candidate.
                    (candidate-hidden (s-join " " (list files notes link context citekey))))
               (cons
                ;; If we don't trim the trailing whitespace,
                ;; 'completing-read-multiple' will get confused when there are
                ;; multiple selected candidates.
                (s-trim-right
                 (concat
                  ;; We need all of these searchable:
                  ;;   1. the 'candidate-main' variable to be displayed
                  ;;   2. the 'candidate-suffix' variable to be displayed with a different face
                  ;;   3. the 'candidate-hidden' variable to be hidden
                  (propertize candidate-main 'face 'bibtex-actions-highlight) " "
                  (propertize candidate-suffix 'face 'bibtex-actions) " "
                  (propertize candidate-hidden 'invisible t)))
                citekey)))))

(defun bibtex-actions--affixation (cands)
  "Add affixation prefix to CANDS."
  (cl-loop
   for candidate in cands
   collect
   (let ((files (if (string-match "has:files" candidate)
                  (cadr (assoc 'file bibtex-actions-symbols))
                (cddr (assoc 'file bibtex-actions-symbols))))
         (link (if (string-match "has:link" candidate)
                   (cadr (assoc 'link bibtex-actions-symbols))
                 (cddr (assoc 'link bibtex-actions-symbols))))
         (note
          (if (string-match "has:note" candidate)
                  (cadr (assoc 'note bibtex-actions-symbols))
                (cddr (assoc 'note bibtex-actions-symbols))))
         (suffix ""))
   (list candidate (concat
                    (s-join bibtex-actions-symbol-separator
                            (list files note link))"	") suffix))))

(defvar bibtex-actions--candidates-cache 'uninitialized
  "Store the global candidates list.

Default value of 'uninitialized is used to indicate that cache
has not yet been created")

(defvar-local bibtex-actions--local-candidates-cache 'uninitialized
  ;; We use defvar-local so can maintain per-buffer candidate caches.
  "Store the local (per-buffer) candidates list.")

(defun bibtex-actions--get-candidates (&optional force-rebuild-cache)
  "Get the cached candidates.
If the cache is unintialized, this will load the cache.
If FORCE-REBUILD-CACHE is t, force reload the cache."
  (when (or force-rebuild-cache
            (eq 'uninitialized bibtex-actions--candidates-cache)
            (eq 'uninitialized bibtex-actions--local-candidates-cache))
    (bibtex-actions-refresh force-rebuild-cache))
  (seq-concatenate 'list
                   bibtex-actions--local-candidates-cache
                   bibtex-actions--candidates-cache))

;;;###autoload
(defun bibtex-actions-refresh (&optional force-rebuild-cache scope)
  "Reload the candidates cache.

If called interactively with a prefix or if FORCE-REBUILD-CACHE
is non-nil, also run the `bibtex-actions-before-refresh-hook' hook.

If SCOPE is `global' only global cache is refreshed, if it is
`local' only local cache is refreshed. With any other value both
are refreshed."
  (interactive (list current-prefix-arg nil))
  (when force-rebuild-cache
    (run-hooks 'bibtex-actions-force-refresh-hook))
  (unless (eq 'local scope)
    (setq bibtex-actions--candidates-cache
      (bibtex-actions--format-candidates
       bibtex-actions-bibliography)))
  (unless (eq 'global scope)
    (setq bibtex-actions--local-candidates-cache
          (bibtex-actions--format-candidates
           (bibtex-actions--local-files-to-cache) "is:local"))))

;;;###autoload
(defun bibtex-actions-insert-preset ()
  "Prompt for and insert a predefined search."
  (interactive)
  (unless (minibufferp)
    (user-error "Command can only be used in minibuffer"))
  (when-let ((enable-recursive-minibuffers t)
             (search (completing-read "Preset: " bibtex-actions-presets)))
    (insert search)))

;;; Formatting functions
;;  NOTE this section will be removed, or dramatically simplified, if and
;;  when this PR is merged:
;;    https://github.com/tmalsburg/helm-bibtex/pull/367

(defun bibtex-actions--process-display-formats (formats)
  "Pre-calculate minimal widths needed by the FORMATS strings for various entry types."
  ;; Adapted from bibtex-completion.
  (cl-loop
   for format in formats
   collect
   (let* ((format-string (cdr format))
          (fields-width 0)
          (string-width
           (string-width
            (s-format
             format-string
             (lambda (field)
               (setq fields-width
                     (+ fields-width
                        (string-to-number
                         (or (cadr (split-string field ":"))
                             ""))))
               "")))))
     (cons (car format) (cons format-string (+ fields-width string-width))))))

(defun bibtex-actions--format-entry (entry width template)
  "Formats a BibTeX ENTRY for display in results list.
WIDTH is the width of the results list, and the display format is governed by
TEMPLATE."
  ;; Adapted from bibtex-completion.
  (let* ((format
          (or
           ;; If there's a template specific to the type, use that.
           (assoc-string
            (bibtex-actions-get-value "=type=" entry) template 'case-fold)
           ;; Otherwise, use the generic template.
           (assoc t template)))
         (format-string (cadr format)))
    (s-format
     format-string
     (lambda (raw-field)
       (let* ((field (split-string raw-field ":"))
              (field-name (car field))
              (field-width (string-to-number (cadr field)))
              (display-width (if (> field-width 0)
                                 ;; If user specifies field width of "*", use
                                 ;; WIDTH; else use the explicit 'field-width'.
                                 field-width
                               width))
              ;; Make sure we always return a string, even if empty.
              (field-value (bibtex-completion-clean-string
                            (or (bibtex-actions--field-value-for-formatting field-name entry)
                                " "))))
         (truncate-string-to-width field-value display-width 0 ?\s))))))

(defun bibtex-actions--field-value-for-formatting (field-name entry)
  "Field formatting for ENTRY FIELD-NAME."
  (let ((field-value (bibtex-actions-get-value field-name entry)))
    (pcase field-name
      ("author" (if field-value
                    (bibtex-actions-shorten-names field-value)
                  (bibtex-actions--field-value-for-formatting "editor" entry)))
      ("editor" (bibtex-actions-shorten-names field-value))
      ("date" (string-limit field-value 4))
      (_ field-value))))

;;; At-point functions

;;; Org-cite

;; This function will likely be removed if and when bibtex-completions adds
;; something equivalent.
(defun bibtex-actions-get-key-org-cite ()
  "Return key at point for org-cite citation-reference."
  (when-let (((eq major-mode 'org-mode))
             (elt (org-element-context)))
    (pcase (org-element-type elt)
      ('citation-reference
       (org-element-property :key elt))
      ('citation
       (org-cite-get-references elt t)))))

;;; Embark

(defun bibtex-actions--stringify-keys (keys)
  "Return a list of KEYS as a crm-string for `embark'."
  (if (listp keys) (string-join keys " & ") keys))

(defun bibtex-actions-citation-key-at-point ()
  "Return citation keys at point as a list for `embark'."
  (when-let ((keys (or (bibtex-actions-get-key-org-cite)
                      (bibtex-completion-key-at-point))))
    (cons 'citation-key (bibtex-actions--stringify-keys keys))))


;;; Command wrappers for bibtex-completion functions

;;;###autoload
(defun bibtex-actions-open (keys)
 "Open PDF, or URL or DOI link.
Opens the PDF(s) associated with the KEYS.  If multiple PDFs are
found, ask for the one to open using ‘completing-read’.  If no
PDF is found, try to open a URL or DOI in the browser instead.
With prefix, rebuild the cache before offering candidates."
 ;; TODO make this is a CRM interface, with grouping
 ;;      files, links, notes
  (interactive (list (bibtex-actions-read :rebuild-cache current-prefix-arg)))
  (bibtex-completion-open-any keys))

;;;###autoload
(defun bibtex-actions-open-library-files (key)
 "Open library files associated with the KEY.

With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-read
                      :rebuild-cache current-prefix-arg)))
  (bibtex-actions-open-files
   key bibtex-actions-library-paths
   :external bibtex-actions-open-library-file-external))

(make-obsolete 'bibtex-actions-open-pdf
               'bibtex-actions-open-library-files "1.0")

;;;###autoload
(defun bibtex-actions-open-notes (keys)
  "Open notes associated with the KEYS.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-read :rebuild-cache current-prefix-arg)))
  ;; TODO this doesn't work
  (bibtex-actions-open-files
   keys bibtex-actions-notes-paths :create 'note))

;;;###autoload
(defun bibtex-actions-open-entry (keys)
  "Open BibTeX entry associated with the KEYS.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-read :rebuild-cache current-prefix-arg)))
 (bibtex-completion-show-entry keys))

;;;###autoload
(defun bibtex-actions-open-link (keys)
  "Open URL or DOI link associated with the KEYS in a browser.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-read :rebuild-cache current-prefix-arg)))
 (bibtex-completion-open-url-or-doi keys))

;;;###autoload
(defun bibtex-actions-insert-citation (keys)
  "Insert citation for the KEYS.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-read :rebuild-cache current-prefix-arg)))
 (bibtex-completion-insert-citation keys))

;;;###autoload
(defun bibtex-actions-insert-reference (keys)
  "Insert formatted reference(s) associated with the KEYS.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-read :rebuild-cache current-prefix-arg)))
  (bibtex-completion-insert-reference keys))

;;;###autoload
(defun bibtex-actions-insert-key (keys)
  "Insert BibTeX KEYS.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-read :rebuild-cache current-prefix-arg)))
 (bibtex-completion-insert-key keys))

;;;###autoload
(defun bibtex-actions-insert-bibtex (keys)
  "Insert BibTeX entry associated with the KEYS.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-read :rebuild-cache current-prefix-arg)))
 (bibtex-completion-insert-bibtex keys))

;;;###autoload
(defun bibtex-actions-add-pdf-attachment (keys)
  "Attach PDF(s) associated with the KEYS to email.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-read :rebuild-cache current-prefix-arg)))
 (bibtex-completion-add-PDF-attachment keys))

;;;###autoload
(defun bibtex-actions-add-pdf-to-library (keys)
 "Add PDF associated with the KEYS to library.
The PDF can be added either from an open buffer, a file, or a
URL.
With prefix, rebuild the cache before offering candidates."
  (interactive (list (bibtex-actions-read :rebuild-cache current-prefix-arg)))
  (bibtex-completion-add-pdf-to-library keys))

(defun bibtex-actions-run-default-action (keys)
  "Run the default action `bibtex-actions-default-action' on KEYS."
  (funcall bibtex-actions-default-action
           (if (stringp keys)
               (split-string keys " & ")
             (split-string (cdr keys) " & "))))

;;;###autoload
(defun bibtex-actions-dwim ()
  "Run the default action on citation keys found at point."
  (interactive)
  (if-let ((keys (cdr (bibtex-actions-citation-key-at-point))))
      (bibtex-actions-run-default-action keys)))

;;;###autoload
(defun bibtex-actions-filenotify-setup (mode-hooks)
  "Setup filenotify watches for local and global bibliography related files.

This functions adds watches to the files in
`bibtex-actions-filenotify-files' and adds a hook to the
'major-mode' hooks in 'MODE-HOOKS' which adds watches for the
local bib files. These local watches are removed when the buffer
closes."
  (bibtex-actions-filenotify-global-watches)
  (mapc (lambda (mode)
          (add-hook mode #'bibtex-actions-filenotify-local-watches)) mode-hooks))

(provide 'bibtex-actions)
;;; bibtex-actions.el ends here
