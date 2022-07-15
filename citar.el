;;; citar.el --- Citation-related commands for org, latex, markdown -*- lexical-binding: t; -*-

;; Copyright (C) 2021 Bruce D'Arcus

;; Author: Bruce D'Arcus <https://github.com/bdarcus>
;; Maintainer: Bruce D'Arcus <https://github.com/bdarcus>
;; Created: February 27, 2021
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.9.7
;; Homepage: https://github.com/emacs-citar/citar
;; Package-Requires: ((emacs "27.1") (parsebib "3.0") (org "9.5") (citeproc "0.9"))

;; This file is not part of GNU Emacs.
;;
;;; Commentary:

;;  A completing-read front-end to browse, filter and act on BibTeX, BibLaTeX,
;;  and CSL JSON bibliographic data, including LaTeX, markdown, and org-cite
;;  citation editing support.
;;
;;; Code:

(eval-when-compile
  (require 'cl-lib)
  (require 'subr-x))
(require 'seq)
(require 'map)
(require 'browse-url)
(require 'citar-cache)
(require 'citar-format)
(require 'citar-file)

;;; pre-1.0 API cleanup

;; make public
;; (make-obsolete 'citar--get-candidates 'citar-get-candidates "1.0")

;; Renamed in 1.0
(make-obsolete 'citar-has-file #'citar-has-files "1.0")
(make-obsolete 'citar-has-note #'citar-has-notes "1.0")
(make-obsolete 'citar-open-library-file #'citar-open-files "1.0")
(make-obsolete 'citar-attach-library-file #'citar-attach-files "1.0")
(make-obsolete 'citar-open-link #'citar-open-links "1.0")
(make-obsolete 'citar-get-link #'citar-get-links "1.0") ; now returns list
(make-obsolete 'citar-display-value 'citar-get-display-value "1.0")

;; make all these private
(make-obsolete 'citar-clean-string 'citar--clean-string "1.0")
(make-obsolete 'citar-shorten-names 'citar--shorten-names "1.0")
(make-obsolete 'citar-get-template 'citar--get-template "1.0")
(make-obsolete 'citar-open-multi 'citar--open-multi "1.0")
(make-obsolete 'citar-select-group-related-resources
               'citar--select-group-related-resources "1.0")
(make-obsolete 'citar-select-resource 'citar--select-resource "1.0")

;; also rename
(make-obsolete 'citar-has-a-value 'citar-get-field-with-value "0.9.5") ; now returns cons pair
(make-obsolete 'citar-field-with-value 'citar-get-field-with-value "1.0") ; now returns cons pair
(make-obsolete 'citar--open-note 'citar-file--open-note "1.0")

;;(make-obsolete-variable 'citar-format-note-function "1.0")

;;; Declare variables and functions for byte compiler

(defvar embark-default-action-overrides)
(declare-function citar-org-format-note-default "citar-org")

;;; Variables

(defvar-local citar--entries nil
  "Override currently active citar entries.

When non-nil, should be a hash table mapping citation keys to
entries, as returned by `citar-get-entries'. Then all citar
functions will use that hash table as the source of bibliography
data instead of accessing the cache.

This variable should only be let-bound locally for the duration
of individual functions or operations. This is useful when using
multiple Citar functions in quick succession, to guarantee that
all potential cache accesses and updates are performed up-front.
In such cases, use a pattern like this:

  (let ((citar--entries (citar-get-entries)))
    ...)

Note that this variable is buffer-local, since Citar has a
different list of bibliographies (and hence entries) for each
buffer.")

;;;; Faces

(defgroup citar nil
  "Citations and bibliography management."
  :group 'editing)

(defface citar
  '((t :inherit font-lock-doc-face))
  "Default Face for `citar' candidates."
  :group 'citar)

(defface citar-highlight
  '((t :weight bold))
  "Face used to highlight content in `citar' candidates."
  :group 'citar)

(defface citar-selection
  '((t :inherit highlight :slant italic))
  "Face used for the currently selected candidates."
  :group 'citar)

;;;; Bibliography, file, and note paths

(defcustom citar-bibliography nil
  "A list of bibliography files."
  :group 'citar
  :type '(repeat file))

(defcustom citar-library-paths nil
  "A list of files paths for related PDFs, etc."
  :group 'citar
  :type '(repeat directory))

(defcustom citar-library-file-extensions nil
  "List of file extensions to filter for related files.

These are the extensions the `citar-file-open-function'
will open, via `citar-file-open'.

When nil, the function will not filter the list of files."
  :group 'citar
  :type '(repeat string))

(defcustom citar-notes-paths nil
  "A list of file paths for bibliographic notes."
  :group 'citar
  :type '(repeat directory))

(defcustom citar-crossref-variable "crossref"
  "The bibliography field to look for cross-referenced entries.

When non-nil, find associated files and notes not only in the
original entry, but also in entries specified in the field named
by this variable."
  :group 'citar
  :type '(choice (const "crossref")
                 (string :tag "Field name")
                 (const :tag "Ignore cross-references" nil)))

(defcustom citar-additional-fields '("doi" "url" "pmcid" "pmid")
  "A list of fields to add to parsed data.

By default, citar filters parsed data based on the fields
specified in `citar-templates'. This specifies additional fields
to include."
  :group 'citar
  :type '(repeat string))

;;;; Displaying completions and formatting

(defcustom citar-templates
  '((main . "${author editor:30}     ${date year issued:4}     ${title:48}")
    (suffix . "          ${=key= id:15}    ${=type=:12}    ${tags keywords keywords:*}")
    (preview . "${author editor} (${year issued date}) ${title}, \
${journal journaltitle publisher container-title collection-title}.\n")
    (note . "Notes on ${author editor}, ${title}"))
  "Configures formatting for the bibliographic entry.

The main and suffix templates are for candidate display, and note
for the title field for new notes."
  :group 'citar
  :type  '(alist :key-type symbol
                 :value-type string
                 :options (main suffix preview note)))

(defcustom citar-ellipsis nil
  "Ellipsis string to mark ending of truncated display fields.

If t, use the value of `truncate-string-ellipsis'.  If nil, no
ellipsis will be used.  Otherwise, this should be a non-empty
string specifying the ellipsis."
  :group 'citar
  :type '(choice (const :tag "Use `truncate-string-ellipsis'" t)
                 (const :tag "No ellipsis" nil)
                 (const "…")
                 (const "...")
                 (string :tag "Ellipsis string")))

(defcustom citar-format-reference-function
  #'citar-format-reference
  "Function used to render formatted references.

This function is called by `citar-insert-reference' and
`citar-copy-reference'. The default value,
`citar-format-reference', formats references using the `preview'
template set in `citar-template'. To use `citeproc-el' to format
references according to CSL styles, set the value to
`citar-citeproc-format-reference'. Alternatively, set to a custom
function that takes a list of (KEY . ENTRY) and returns formatted
references as a string."
  :group 'citar
  :type '(choice (function-item :tag "Use 'citar-template'" citar-format-reference)
                 (function-item :tag "Use 'citeproc-el'" citar-citeproc-format-reference)
                 (function :tag "Other")))

(defcustom citar-display-transform-functions
  ;; TODO change this name, as it might be confusing?
  '((t  . citar--clean-string)
    (("author" "editor") . citar--shorten-names))
  "Configure transformation of field display values from raw values.

All functions that match a particular field are run in order."
  :group 'citar
  :type '(alist :key-type   (choice (const t) (repeat string))
                :value-type function))

(defcustom citar-symbols
  `((file  .  ("F" . " "))
    (note .   ("N" . " "))
    (link .   ("L" . " ")))
  "Configuration alist specifying which symbol or icon to pick for a bib entry.
This leaves room for configurations where the absense of an item
may be indicated with the same icon but a different face.

To avoid alignment issues make sure that both the car and cdr of a symbol have
the same width."
  :group 'citar
  :type '(alist :key-type symbol
                :value-type (cons (string :tag "Present")
                                  (string :tag "Absent"))
                :options (file note link)))

(defcustom citar-symbol-separator " "
  "The padding between prefix symbols."
  :group 'citar
  :type 'string)

;;;; Citar actions and other miscellany

(defcustom citar-default-action #'citar-open
  "The default action for the `citar-at-point' command.
Should be a function that takes one argument, a list with each
entry being either a citation KEY or a (KEY . ENTRY) pair."
  :group 'citar
  :type 'function)

(defcustom citar-at-point-fallback 'prompt
  "Fallback action for `citar-at-point'.
The action is used when no citation key is found at point.
`prompt' means choosing entries via `citar-select-keys'
and nil means no action."
  :group 'citar
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Ignore" nil)))

(defcustom citar-open-prompt t
  "Always prompt for selection files with `citar-open'.
If nil, single resources will open without prompting."
  :group 'citar
  :type '(boolean))

;;;; File, note, and URL handling

(defcustom citar-has-files-functions (list #'citar-file--has-file-field
                                           #'citar-file--has-library-files)
  "List of functions to test if an entry has associated files."
  :group 'citar
  :type '(repeat function))

(defcustom citar-get-files-functions (list #'citar-file--get-from-file-field
                                           #'citar-file--get-library-files)
  "List of functions to find files associated with entries."
  :group 'citar
  :type '(repeat function))

(defcustom citar-notes-sources
  `((citar-file .
                ,(list :name "Notes"
                       :category 'file
                       :items #'citar-file--get-notes
                       :hasitems #'citar-file--has-notes
                       :open #'find-file
                       :create #'citar-file--create-note
                       :transform #'file-name-nondirectory)))
  "The alist of notes backends available for configuration.

The format of the cons should be (NAME . PLIST), where the
plist has the following properties:

  :name the group display name

  :category the completion category

  :hasitems function to test for keys with notes

  :open function to open a given note candidate

  :items function to return candidate strings for keys

  :annotate annotation function (optional)

  :transform transformation function (optional)"
  :group 'citar
  :type '(alist :key-type symbol :value-type plist))

(defcustom citar-notes-source 'citar-file
  "The notes backend."
  :group 'citar
  :type 'symbol)

;; TODO should this be a major mode function?
(defcustom citar-note-format-function #'citar-org-format-note-default
  "Function used by `citar-file' note source to format new notes."
  :group 'citar
  :type 'function)

;;;; Major mode functions

;; TODO Move this to `citar-org', since it's only used there?
;; Otherwise it seems to overlap with `citar-default-action'
(defcustom citar-at-point-function #'citar-dwim
  "The function to run for `citar-at-point'."
  :group 'citar
  :type 'function)

(defcustom citar-major-mode-functions
  '(((org-mode) .
     ((local-bib-files . citar-org-local-bib-files)
      (insert-citation . citar-org-insert-citation)
      (insert-edit . citar-org-insert-edit)
      (key-at-point . citar-org-key-at-point)
      (citation-at-point . citar-org-citation-at-point)
      (list-keys . citar-org-list-keys)))
    ((latex-mode) .
     ((local-bib-files . citar-latex-local-bib-files)
      (insert-citation . citar-latex-insert-citation)
      (insert-edit . citar-latex-insert-edit)
      (key-at-point . citar-latex-key-at-point)
      (citation-at-point . citar-latex-citation-at-point)
      (list-keys . reftex-all-used-citation-keys)))
    ((markdown-mode) .
     ((insert-keys . citar-markdown-insert-keys)
      (insert-citation . citar-markdown-insert-citation)
      (insert-edit . citar-markdown-insert-edit)
      (key-at-point . citar-markdown-key-at-point)
      (citation-at-point . citar-markdown-citation-at-point)
      (list-keys . citar-markdown-list-keys)))
    (t .
       ((insert-keys . citar--insert-keys-comma-separated))))
  "The variable determining the major mode specific functionality.

It is alist with keys being a list of major modes.

The value is an alist with values being functions to be used for
these modes while the keys are symbols used to lookup them up.
The keys are:

local-bib-files: the corresponding functions should return the list of
local bibliography files.

insert-keys: the corresponding function should insert the list of keys given
to as the argument at point in the buffer.

insert-citation: the corresponding function should insert a
complete citation from a list of keys at point.  If the point is
in a citation, new keys should be added to the citation.

insert-edit: the corresponding function should accept an optional
prefix argument and interactively edit the citation or key at
point.

key-at-point: the corresponding function should return the
citation key at point or nil if there is none.  The return value
should be (KEY . BOUNDS), where KEY is a string and BOUNDS is a
pair of buffer positions indicating the start and end of the key.

citation-at-point: the corresponding function should return the
keys of the citation at point, or nil if there is none.  The
return value should be (KEYS . BOUNDS), where KEYS is a list of
strings and BOUNDS is pair of buffer positions indicating the
start and end of the citation.

list-keys: the corresponding function should return the keys
of all citations in the current buffer."
  :group 'citar
  :type 'alist)

;;;; History, including future history list.

(defvar citar-history nil
  "Search history for `citar'.")

(defcustom citar-presets nil
  "List of predefined searches."
  :group 'citar
  :type '(repeat string))

(defcustom citar-select-multiple t
  "Use `completing-read-multiple' for selecting citation keys.
When nil, all citar commands will use `completing-read'."
  :type 'boolean
  :group 'citar)

;;;; Keymaps

(defvar citar-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'citar-insert-citation)
    (define-key map (kbd "k") #'citar-insert-keys)
    (define-key map (kbd "r") #'citar-copy-reference)
    (define-key map (kbd "R") #'citar-insert-reference)
    (define-key map (kbd "b") #'citar-insert-bibtex)
    (define-key map (kbd "o") #'citar-open)
    (define-key map (kbd "e") #'citar-open-entry)
    (define-key map (kbd "l") #'citar-open-links)
    (define-key map (kbd "n") #'citar-open-notes)
    (define-key map (kbd "f") #'citar-open-files)
    (define-key map (kbd "RET") #'citar-run-default-action)
    map)
  "Keymap for Embark minibuffer actions.")

(defvar citar-citation-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "i") #'citar-insert-edit)
    (define-key map (kbd "o") #'citar-open)
    (define-key map (kbd "e") #'citar-open-entry)
    (define-key map (kbd "l") #'citar-open-links)
    (define-key map (kbd "n") #'citar-open-notes)
    (define-key map (kbd "f") #'citar-open-files)
    (define-key map (kbd "r") #'citar-copy-reference)
    (define-key map (kbd "RET") #'citar-run-default-action)
    map)
  "Keymap for Embark citation-key actions.")

;;; Bibliography cache

(defun citar--bibliography-files (&rest buffers)
  "Bibliography file names for BUFFERS.
The elements of BUFFERS are either buffers or the symbol 'global.
Returns the absolute file names of the bibliographies in all
these contexts.

When BUFFERS is nil, return local bibliographies for the current
buffer and global bibliographies."
  (citar-file--normalize-paths
   (mapcan (lambda (buffer)
             (if (eq buffer 'global)
                 (if (listp citar-bibliography) citar-bibliography
                   (list citar-bibliography))
               (with-current-buffer buffer
                 (citar--major-mode-function 'local-bib-files #'ignore))))
           (or buffers (list (current-buffer) 'global)))))

(defun citar--bibliographies (&rest buffers)
  "Return bibliographies for BUFFERS."
  (delete-dups
   (mapcan
    (lambda (buffer)
      (citar-cache--get-bibliographies (citar--bibliography-files buffer) buffer))
    (or buffers (list (current-buffer) 'global)))))

;;; Completion functions

(defun citar--completion-table (candidates &optional filter &rest metadata)
  "Return a completion table for CANDIDATES.

CANDIDATES is a hash with references CAND as key and CITEKEY as value,
  where CAND is a display string for the bibliography item.

FILTER, if non-nil, should be a predicate function taking
  argument KEY. Only candidates for which this function returns
  non-nil will be offered for completion.

By default the metadata of the table contains the category and
affixation function. METADATA are extra entries for metadata of
the form (KEY . VAL).

The returned completion table can be used with `completing-read'
and other completion functions."
  (let ((metadata `(metadata . ((category . citar-candidate)
                                . ((affixation-function . ,#'citar--ref-affix)
                                   . ,metadata)))))
    (lambda (string predicate action)
      (if (eq action 'metadata)
          metadata
        ;; REVIEW this now works, but probably needs refinement
        (let ((predicate
               (when (or filter predicate)
                 (lambda (_ key)
                   (and (or (null filter) (funcall filter key))
                        (or (null predicate) (funcall predicate string)))))))
          (complete-with-action action candidates string predicate))))))

(cl-defun citar-select-refs (&key (multiple t) filter)
  "Select bibliographic references.

A wrapper around `completing-read' that returns (KEY . ENTRY),
where ENTRY is a field-value alist.  Therefore `car' of the
return value is the cite key, and `cdr' is an alist of structured
data.

Takes the following optional keyword arguments:

MULTIPLE: if t, calls `completing-read-multiple' and returns an
  alist of (KEY . ENTRY) pairs.

FILTER: if non-nil, should be a predicate function taking
  arguments KEY and ENTRY.  Only candidates for which this
  function returns non-nil will be offered for completion.  For
  example:

  (citar-select-ref :filter (citar-has-note))

  (citar-select-ref :filter (citar-has-file))"
  (let* ((candidates (or (citar--format-candidates)
                         (user-error "No bibliography set")))
         (chosen (if (and multiple citar-select-multiple)
                     (citar--select-multiple "References: " candidates
                                             filter 'citar-history citar-presets)
                   (completing-read "Reference: " (citar--completion-table candidates filter)
                                    nil nil nil 'citar-history citar-presets nil))))
    ;; If CAND is not in CANDIDATES, treat it as a citekey (e.g. inserted into the minibuffer by `embark-act')
    (cl-flet ((candkey (cand) (or (gethash cand candidates) cand)))
      ;; Return a list of keys regardless of 1 or many
      (if (listp chosen)
          (mapcar #'candkey chosen)
        (list (candkey chosen))))))

(cl-defun citar-select-ref (&key filter)
  "Select bibliographic references.

Call 'citar-select-ref' with argument ':multiple, and optional
FILTER; see its documentation for the return value."
  (car (citar-select-refs :multiple nil :filter filter)))

(defun citar--multiple-completion-table (selected-hash candidates filter)
  "Return a completion table for multiple selection.
SELECTED-HASH is the hash-table containing selected candidates.
CANDIDATES is the list of completion candidates, FILTER is the function
to filter them."
  (citar--completion-table
   candidates filter
   `(group-function . (lambda (cand transform)
                        (pcase (list (not (not transform))
                                     (gethash (substring-no-properties cand) ,selected-hash))
                          ('(nil nil) "Select Multiple")
                          ('(nil t)   "Selected")
                          ('(t nil) cand)
                          ('(t t)
                           (add-face-text-property 0 (length cand) 'citar-selection nil (copy-sequence cand))
                           cand))))))

(defvar citar--multiple-setup '("TAB" . "RET")
  "Variable whose value should be a cons (SEL . EXIT)
SEL is the key which should be used for selection. EXIT is the key which
is used for exiting the minibuffer during completing read.")

(defun citar--multiple-exit ()
  "Exit with the currently selected candidates."
  (interactive)
  (setq unread-command-events (listify-key-sequence (kbd (car citar--multiple-setup)))))

(defun citar--setup-multiple-keymap ()
  "Make a keymap suitable for `citar--select-multiple'."
  (let ((keymap (make-composed-keymap nil (current-local-map)))
        (kbdselect (kbd (car citar--multiple-setup)))
        (kbdexit (kbd (cdr citar--multiple-setup))))
    (define-key keymap kbdselect (lookup-key keymap kbdexit))
    (define-key keymap kbdexit #'citar--multiple-exit)
    (use-local-map keymap)))

(defun citar--select-multiple (prompt candidates &optional filter history def)
  "Select multiple CANDIDATES with PROMPT.
HISTORY is the `completing-read' history argument."
  ;; Because completing-read-multiple just does not work for long candidate
  ;; strings, and IMO is a poor UI.
  (let* ((selected-hash (make-hash-table :test 'equal)))
    (while (let ((item (minibuffer-with-setup-hook #'citar--setup-multiple-keymap
                         (completing-read
                          (format "%s (%s/%s): " prompt
                                  (hash-table-count selected-hash)
                                  (hash-table-count candidates))
                          (citar--multiple-completion-table selected-hash candidates filter)
                          nil t nil history `("" . ,def)))))
             (unless (string-empty-p item)
               (if (not (gethash item selected-hash))
                   (puthash item t selected-hash)
                 (remhash item selected-hash)
                 (pop (symbol-value history))))
             (not (or (eq last-command #'citar--multiple-exit)
                      (string-empty-p item)))))
    (hash-table-keys selected-hash)))

(cl-defun citar--get-resource-candidates (key-or-keys &key files links notes)
  "Return related resource candidates for KEY-OR-KEYS.

Return a list (CATEGORY . CANDIDATES), where CATEGORY is a
completion category and CANDIDATES is a list of resources
associated with KEY-OR-KEYS. Return nil if there are no
associated resources.

The resources include:
 * FILES: a list of files or t to use `citar-get-files'.
 * LINKS: a list of links or t to use `citar-get-links'.
 * NOTES: a list of notes or t to use `citar-get-notes'.

If any of FILES, LINKS, or NOTES is nil, that resource type is
omitted from CANDIDATES.

CATEGORY is either `file' when returning only files, `url' when
returning only links, or the category specified by
`citar-notes-source' if returning only notes. When CANDIDATES has
resources of multiple types, CATEGORY is `multi-category' and the
`multi-category' text property is applied to each element of
CANDIDATES."
  (cl-flet ((withtype (type cands) (mapcar (lambda (cand) (propertize cand 'citar--resource type)) cands)))
    (let* ((citar--entries (citar-get-entries))
           (files (if (listp files) files (citar-get-files key-or-keys)))
           (links (if (listp links) links (citar-get-links key-or-keys)))
           (notes (if (listp notes) notes (citar-get-notes key-or-keys)))
           (notecat (citar--get-notes-config :category))
           (sources (nconc (when files (list (cons 'file (withtype 'file files))))
                           (when links (list (cons 'url (withtype 'url links))))
                           (when notes (list (cons notecat (withtype 'note notes)))))))
      (if (null (cdr sources))        ; if sources is nil or singleton list,
          (car sources)               ; return either nil or the only source.
        (cons 'multi-category         ; otherwise, combine all sources
              (mapcan
               (pcase-lambda (`(,cat . ,cands))
                 (if (not cat)
                     cands
                   (mapcar (lambda (cand) (propertize cand 'multi-category (cons cat cand))) cands)))
               sources))))))

(defun citar--annotate-note (candidate)
  "Annotate note CANDIDATE."
  (when-let (((eq 'note (get-text-property 0 'citar--resource candidate)))
             (annotate (citar--get-notes-config :annotate)))
    (funcall annotate (substring-no-properties candidate))))

(cl-defun citar--select-resource (keys &key files notes links (always-prompt t))
  ;; FIX the arg list above is not smart
  "Select related FILES, NOTES, or LINKS resource for KEYS.

Return (TYPE . RESOURCE), where TYPE is `file', `link', or `note'
and RESOURCE is the selected resource string. Return nil if there
are no resources.

Use `completing-read' to prompt for a resource, unless there is
only one resource and ALWAYS-PROMPT is nil. Return nil if the
user declined to choose."
  (when-let ((resources (citar--get-resource-candidates keys :files files :notes notes :links links)))
    (pcase-let ((`(,category . ,cands) resources))
      (when-let ((selected
                  (if (and (not always-prompt) (null (cdr cands)))
                      (car cands)
                    (let* ((metadata `(metadata
                                       (group-function . ,#'citar--select-group-related-resources)
                                       (annotation-function . ,#'citar--annotate-note)
                                       ,@(when category `((category . ,category)))))
                           (table (lambda (string predicate action)
                                    (if (eq action 'metadata)
                                        metadata
                                      (complete-with-action action cands string predicate))))
                           (selected (completing-read "Select resource: " table nil t)))
                      (car (member selected cands))))))
        (cons (get-text-property 0 'citar--resource selected) (substring-no-properties selected))))))

(defun citar--select-group-related-resources (resource transform)
  "Group RESOURCE by type or TRANSFORM."
  (pcase (get-text-property 0 'citar--resource resource)
    ('file (if transform
               (file-name-nondirectory resource)
             "Library Files"))
    ('url (if transform
              resource
            "Links"))
    ('note (if transform
               (funcall (or (citar--get-notes-config :transform) #'identity) resource)
             (or (citar--get-notes-config :name) "Notes")))
    (_ (if transform
           resource
         nil))))

(defun citar--format-candidates ()
  "Format completion candidates for bibliography entries.

Return a hash table with the keys being completion candidate
strings and values being citation keys.

Return nil if `citar-bibliographies' returns nil."
  ;; Populate bibliography cache.
  (when-let ((bibs (citar--bibliographies)))
    (let* ((citar--entries (citar-cache--entries bibs))
           (preformatted (citar-cache--preformatted bibs))
           (hasfilesp (citar-has-files))
           (hasnotesp (citar-has-notes))
           (haslinksp (citar-has-links))
           (hasfilestag (propertize " has:files" 'invisible t))
           (hasnotestag (propertize " has:notes" 'invisible t))
           (haslinkstag (propertize " has:links" 'invisible t))
           (symbolswidth (string-width (citar--symbols-string t t t)))
           (width (- (frame-width) symbolswidth 2))
           (completions (make-hash-table :test 'equal :size (hash-table-count citar--entries))))
      (prog1 completions
        (maphash
         (lambda (citekey _entry)
           (let* ((hasfiles (and hasfilesp (funcall hasfilesp citekey)))
                  (hasnotes (and hasnotesp (funcall hasnotesp citekey)))
                  (haslinks (and haslinksp (funcall haslinksp citekey)))
                  (preform (or (gethash citekey preformatted)
                               (error "No preformatted candidate string: %s" citekey)))
                  (display (citar-format--star-widths
                            (- width (car preform)) (cdr preform)
                            t citar-ellipsis))
                  (tagged (if (not (or hasfiles hasnotes haslinks))
                              display
                            (concat display
                                    (when hasfiles hasfilestag)
                                    (when hasnotes hasnotestag)
                                    (when haslinks haslinkstag)))))
             (puthash tagged citekey completions)))
         citar--entries)))))

(defun citar--extract-candidate-citekey (candidate)
  "Extract the citation key from string CANDIDATE."
  (unless (string-empty-p candidate)
    (if (= ?\" (aref candidate 0))
        (read candidate)
      (substring-no-properties candidate 0 (seq-position candidate ?\s #'=)))))

(defun citar--key-at-point ()
  "Return bibliography key at point in current buffer, along with its bounds.
Return (KEY . BOUNDS), where KEY is a string and BOUNDS is either
nil or a (BEG . END) pair indicating the location of KEY in the
buffer. Return nil if there is no key at point or the current
major mode is not supported."
  (citar--major-mode-function 'key-at-point #'ignore))

(defun citar--citation-at-point ()
  "Return citation at point in current buffer, along with its bounds.
Return (KEYS . BOUNDS), where KEYS is a list of citation keys and
BOUNDS is either nil or a (BEG . END) pair indicating the
location of the citation in the buffer. Return nil if there is no
citation at point or the current major mode is not supported."
  (citar--major-mode-function 'citation-at-point #'ignore))

(defun citar-key-at-point ()
  "Return the citation key at point in the current buffer.
Return nil if there is no key at point or the major mode is not
supported."
  (car (citar--key-at-point)))

(defun citar-citation-at-point ()
  "Return a list of keys comprising the citation at point in the current buffer.
Return nil if there is no citation at point or the major mode is
not supported."
  (car (citar--citation-at-point)))

;;; Major-mode functions

(defun citar--get-major-mode-function (key &optional default)
  "Return function associated with KEY in `major-mode-functions'.
If no function is found matching KEY for the current major mode,
return DEFAULT."
  (alist-get
   key
   (cdr (seq-find
         (pcase-lambda (`(,modes . ,_functions))
           (or (eq t modes)
               (apply #'derived-mode-p (if (listp modes) modes (list modes)))))
         citar-major-mode-functions))
   default))

(defun citar--major-mode-function (key default &rest args)
  "Function for the major mode corresponding to KEY applied to ARGS.
If no function is found, the DEFAULT function is called."
  (apply (citar--get-major-mode-function key default) args))

;;; Data access functions

(defun citar-get-entry (key)
  "Return entry for reference KEY, as an association list.
Note: this function accesses the bibliography cache and should
not be used for retreiving a large number of entries. Instead,
prefer `citar--get-entries'."
  (if citar--entries
      (gethash key citar--entries)
    (citar-cache--entry key (citar--bibliographies))))

(defun citar-get-entries ()
  "Return all entries for currently active bibliographies.
Return a hash table whose keys are citation keys and values are
the corresponding entries."
  (or citar--entries (citar-cache--entries (citar--bibliographies))))

(defun citar-get-value (field key-or-entry)
  "Return value of FIELD in reference KEY-OR-ENTRY.
KEY-OR-ENTRY should be either a string key, or an entry alist as
returned by `citar-get-entry'. Return nil if the FIELD is not
present in KEY-OR-ENTRY."
  (let ((entry (if (stringp key-or-entry)
                   (citar-get-entry key-or-entry)
                 key-or-entry)))
    (cdr (assoc-string field entry))))

(defun citar-get-field-with-value (fields key-or-entry)
  "Find the first field among FIELDS that has a value in KEY-OR-ENTRY.
Return (FIELD . VALUE), where FIELD is the element of FIELDS that
was found to have a value, and VALUE is its value."
  (let ((entry (if (stringp key-or-entry)
                   (citar-get-entry key-or-entry)
                 key-or-entry)))
    (seq-some (lambda (field)
                (when-let ((value (citar-get-value field entry)))
                  (cons field value)))
              fields)))

(defun citar-get-display-value (fields key-or-entry)
  "Return the first non nil value for KEY-OR-ENTRY among FIELDS .

The value is transformed using `citar-display-transform-functions'"
  (let ((fieldvalue (citar-get-field-with-value fields key-or-entry)))
    (seq-reduce (lambda (string fun)
                  (if (or (eq t (car fun))
                          (seq-contains-p (car fun) (car fieldvalue) #'string=))
                      (funcall (cdr fun) string)
                    string))
                citar-display-transform-functions
                ;; Make sure we always return a string, even if empty.
                (or (cdr fieldvalue) ""))))

;;;; File, notes, and links

(defun citar--get-notes-config (property)
  "Return PROPERTY value for configured notes backend."
  (plist-get
   (alist-get citar-notes-source citar-notes-sources) property))

(defun citar-register-notes-source (name config)
  "Register note backend.

NAME is a symbol, and CONFIG is a plist."
  (citar--check-notes-source name config)
  (setf (alist-get name citar-notes-sources) config))

(defun citar-remove-notes-source (name)
  "Remove note backend NAME."
  (cl-callf2 assq-delete-all name citar-notes-sources))

(cl-defun citar-get-notes (&optional (key-or-keys nil filter-p))
  "Return list of notes associated with KEY-OR-KEYS.
If KEY-OR-KEYS is omitted, return all notes."
  (let* ((citar--entries (citar-get-entries))
         (keys (citar--with-crossref-keys key-or-keys)))
    (unless (and filter-p (null keys))    ; return nil if KEY-OR-KEYS was given, but is nil
      (delete-dups (funcall (citar--get-notes-config :items) keys)))))

(defun citar-create-note (key &optional entry)
  "Create a note for KEY and ENTRY.
If ENTRY is nil, use `citar-get-entry' with KEY."
  (interactive (list (citar-select-ref)))
  (funcall (citar--get-notes-config :create) key (or entry (citar-get-entry key))))

(defun citar-get-files (key-or-keys)
  "Return list of files associated with KEY-OR-KEYS.
Find files using `citar-get-files-functions'. Include files
associated with cross-referenced keys."
  (let ((citar--entries (citar-get-entries)))
    (when-let ((keys (citar--with-crossref-keys key-or-keys)))
      (delete-dups (mapcan (lambda (func) (funcall func keys)) citar-get-files-functions)))))


(defun citar-get-links (key-or-keys)
  "Return list of links associated with KEY-OR-KEYS.
Include files associated with cross-referenced keys."
  (let* ((citar--entries (citar-get-entries))
         (keys (citar--with-crossref-keys key-or-keys)))
    (delete-dups
     (mapcan
      (lambda (key)
        (when-let ((entry (citar-get-entry key)))
          (mapcan
           (pcase-lambda (`(,fieldname . ,urlformat))
             (when-let ((fieldvalue (citar-get-value fieldname entry)))
               (list (format urlformat fieldvalue))))
           '((doi . "https://doi.org/%s")
             (pmid . "https://www.ncbi.nlm.nih.gov/pubmed/%s")
             (pmcid . "https://www.ncbi.nlm.nih.gov/pmc/articles/%s")
             (url . "%s")))))
      keys))))


(defun citar-has-files ()
  "Return predicate testing whether entry has associated files.

Return a function that takes KEY and returns non-nil when the
corresponding bibliography entry has associated files. The
returned predicated may by nil if no entries have associated
files.

For example, to test whether KEY has associated files:

  (when-let ((hasfilesp (citar-has-files)))
    (funcall hasfilesp KEY))

When testing many keys, call this function once and use the
returned predicate repeatedly.

Files are detected using `citar-has-files-functions', which see.
Also check any bibliography entries that are cross-referenced
from the given KEY; see `citar-crossref-variable'."
  (citar--has-resources
   (mapcar #'funcall citar-has-files-functions)))


(defun citar-has-notes ()
  "Return predicate testing whether entry has associated notes.

Return a function that takes KEY and returns non-nil when the
corresponding bibliography entry has associated notes. The
returned predicate may be nil if no entries have associated
notes.

For example, to test whether KEY has associated notes:

  (let ((hasnotesp (citar-has-notes)))
    (funcall hasnotesp KEY))

When testing many keys, call this function once and use the
returned predicate repeatedly.

Notes are detected using `citar-has-notes-functions', which see.
Also check any bibliography entries that are cross-referenced
from the given KEY; see `citar-crossref-variable'."
  (citar--has-resources
   (funcall (citar--get-notes-config :hasitems))))


(defun citar-has-links ()
  "Return predicate testing whether entry has links.

Return a function that takes KEY and returns non-nil when the
corresponding bibliography entry has associated links. See the
documentation of `citar-has-files' and `citar-has-notes', which
have similar usage."
  (citar--has-resources
   (apply-partially #'citar-get-field-with-value '(doi pmid pmcid url))))


(defun citar--has-resources (predicates)
  "Combine PREDICATES into a single resource predicate.

PREDICATES should be a list of functions that take a bibliography
KEY and return non-nil if the item has a resource. It may also be
a single such function.

Return a predicate that returns non-nil for a given KEY when any
of the elements of PREDICATES return non-nil for that KEY. If
PREDICATES is empty or all its elements are nil, then the
returned predicate is nil.

When `citar-crossref-variable' is the name of a crossref field,
the returned predicate also tests if an entry cross-references
another entry in ENTRIES that has associated resources."
  (when-let ((hasresourcep (if (functionp predicates)
                               predicates
                             (let ((predicates (remq nil predicates)))
                               (if (null (cdr predicates))
                                   ;; optimization for single predicate; just use it directly
                                   (car predicates)
                                 ;; otherwise, call all predicates until one returns non-nil
                                 (lambda (citekey)
                                   (seq-some (lambda (predicate)
                                               (funcall predicate citekey))
                                             predicates)))))))
    (if-let ((xref citar-crossref-variable))
        (lambda (citekey)
          (or (funcall hasresourcep citekey)
              (when-let ((xkey (citar-get-value xref citekey)))
                (funcall hasresourcep xkey))))
      hasresourcep)))

;;; Format and display field values

;; Lifted from bibtex-completion
(defun citar--clean-string (s)
  "Remove quoting brackets and superfluous whitespace from string S."
  (replace-regexp-in-string "[\n\t ]+" " "
                            (replace-regexp-in-string "[\"{}]+" "" s)))

(defun citar--shorten-names (names)
  "Return a list of family names from a list of full NAMES.

To better accommodate corporate names, this will only shorten
personal names of the form \"family, given\"."
  (when (stringp names)
    (mapconcat
     (lambda (name)
       (if (eq 1 (length name))
           (cdr (split-string name " "))
         (car (split-string name ", "))))
     (split-string names " and ") ", ")))

(defun citar--fields-for-format (template)
  "Return list of fields for TEMPLATE."
  (mapcan (lambda (fieldspec) (when (consp fieldspec) (cdr fieldspec)))
          (citar-format--parse template)))

(defun citar--fields-in-formats ()
  "Find the fields to mentioned in the templates."
  (seq-mapcat #'citar--fields-for-format
              (list (citar--get-template 'main)
                    (citar--get-template 'suffix)
                    (citar--get-template 'preview)
                    (citar--get-template 'note))))

(defun citar--fields-to-parse ()
  "Determine the fields to parse from the template."
  (delete-dups `(,@(citar--fields-in-formats)
                 ,@(when citar-file-variable
                     (list citar-file-variable))
                 ,@(when citar-crossref-variable
                     (list citar-crossref-variable))
                 . ,citar-additional-fields)))

(defun citar--with-crossref-keys (key-or-keys)
  "Return KEY-OR-KEYS augmented with cross-referenced items.

KEY-OR-KEYS is either a list KEYS or a single key, which is
converted into KEYS. Return a list containing the elements of
KEYS, with each element followed by the corresponding
cross-referenced keys, if any.

Duplicate keys are removed from the returned list."
  (let ((xref citar-crossref-variable)
        (keys (if (listp key-or-keys) key-or-keys (list key-or-keys))))
    (delete-dups
     (if (not xref)
         keys
       (mapcan (lambda (key)
                 (cons key (when-let ((xkey (citar-get-value xref key)))
                             (list xkey))))
               keys)))))

;;; Affixations and annotations

(defun citar--ref-affix (cands)
  "Add affixation prefix to CANDS."
  (seq-map
   (lambda (candidate)
     (let ((symbols (citar--ref-make-symbols candidate)))
       (list candidate symbols "")))
   cands))

(defun citar--ref-make-symbols (cand)
  "Make CAND annotation or affixation string for has-symbols."
  (let ((candidate-symbols (citar--symbols-string
                            (string-match-p "has:files" cand)
                            (string-match-p "has:notes" cand)
                            (string-match-p "has:links" cand))))
    candidate-symbols))

(defun citar--ref-annotate (cand)
  "Add annotation to CAND."
  ;; REVIEW/TODO we don't currently use this, but could, for Emacs 27.
  (citar--ref-make-symbols cand))

(defun citar--symbols-string (has-files has-note has-link)
  "String for display from booleans HAS-FILES HAS-LINK HAS-NOTE."
  (cl-flet ((thing-string (has-thing thing-symbol)
                          (if has-thing
                              (cadr (assoc thing-symbol citar-symbols))
                            (cddr (assoc thing-symbol citar-symbols)))))
    (seq-reduce (lambda (constructed newpart)
                  (let* ((str (concat constructed newpart
                                      citar-symbol-separator))
                         (pos (length str)))
                    (put-text-property (- pos 1) pos 'display
                                       (cons 'space (list :align-to (string-width str)))
                                       str)
                    str))
                (list (thing-string has-files 'file)
                      (thing-string has-note 'note)
                      (thing-string has-link 'link)
                      "")
                "")))

(defun citar--get-template (template-name)
  "Return template string for TEMPLATE-NAME."
  (or
   (cdr (assq template-name citar-templates))
   (when (eq template-name 'completion)
     (concat (propertize (citar--get-template 'main) 'face 'citar-highlight)
             (propertize (citar--get-template 'suffix) 'face 'citar)))
   (error "No template for \"%s\" - check variable 'citar-templates'" template-name)))

;;;###autoload
(defun citar-insert-preset ()
  "Prompt for and insert a predefined search."
  (interactive)
  (unless (minibufferp)
    (user-error "Command can only be used in minibuffer"))
  (when-let ((enable-recursive-minibuffers t)
             (search (completing-read "Preset: " citar-presets)))
    (insert search)))

(defun citar--stringify-keys (keys)
  "Encode a list of KEYS as a single string."
  (combine-and-quote-strings (if (listp keys) keys (list keys)) " & "))

(defun citar--unstringify-keys (keystring)
  "Split KEYSTRING into a list of keys."
  (split-string-and-unquote keystring " & "))

;;; Commands

;;;###autoload
(defun citar-open (keys)
  "Open related resources (links or files) for KEYS."
  (interactive (list (citar-select-refs)))
  (if-let ((selected (let* ((actions (bound-and-true-p embark-default-action-overrides))
                            (embark-default-action-overrides `((t . ,#'citar--open-resource) . ,actions)))
                       (citar--select-resource keys :files t :links t :notes t
                                               :always-prompt citar-open-prompt))))
      (citar--open-resource (cdr selected) (car selected))
    (error "No associated resources: %s" keys)))

(defun citar--open-resource (resource &optional type)
  "Open RESOURCE of TYPE, which should be `file', `url', or `note'.
If TYPE is nil, then RESOURCE must have a `citar--resource' text
property specifying TYPE."
  (if-let* ((type (or type (get-text-property 0 'citar--resource resource)))
            (open (pcase type
                    ('file #'citar-file-open)
                    ('url #'browse-url)
                    ('note (citar--get-notes-config :open)))))
      (funcall open (substring-no-properties resource))
    (error "Could not open resource of type `%s': %S" type resource)))

;; TODO Rename? This also opens files in bib field, not just library files
;;;###autoload
(defun citar-open-files (key-or-keys)
  "Open library file associated with KEY-OR-KEYS."
  (interactive (list (citar-select-refs)))
  ;; TODO filter to refs have files?
  (citar--library-file-action key-or-keys #'citar-file-open))

;;;###autoload
(defun citar-attach-files (key-or-keys)
  "Attach library file associated with KEY-OR-KEYS to outgoing MIME message."
  (interactive (list (citar-select-ref)))
  (citar--library-file-action key-or-keys #'mml-attach-file))

(defun citar--library-file-action (key-or-keys action)
  "Run ACTION on file associated with KEY-OR-KEYS.
If KEY-OR-KEYS have multiple files, use `completing-read' to
select a single file."
  (let ((citar--entries (citar-get-entries)))
    (if-let ((resource (let* ((actions (bound-and-true-p embark-default-action-overrides))
                              (embark-default-action-overrides `(((file . ,this-command) . ,action)
                                                                 . ,actions)))
                         (citar--select-resource key-or-keys :files t))))
        (if (eq 'file (car resource))
            (funcall action (cdr resource))
          (error "Expected resource of type `file', got `%s': %S" (car resource) (cdr resource)))
      (ignore
       ;; If some key had files according to `citar-has-files', but `citar-get-files' returned nothing, then
       ;; don't print the following message. The appropriate function in `citar-get-files-functions' is
       ;; responsible for telling the user why it failed, and we want that explanation to appear in the echo
       ;; area.
       (let ((keys (if (listp key-or-keys) key-or-keys (list key-or-keys)))
             (hasfilep (citar-has-files)))
         (unless (and hasfilep (seq-some hasfilep keys))
           (message "No associated files for %s" key-or-keys)))))))

;;;###autoload
(defun citar-open-notes (keys)
  "Open notes associated with the KEYS."
  (interactive (list (citar-select-refs)))
  (if-let ((notes (citar-get-notes keys)))
      (progn (mapc (citar--get-notes-config :open) notes)
             (let ((count (length notes)))
               (when (> count 1)
                 (message "Opened %d notes" count))))
    (when keys
      (if (null (cdr keys))
          (citar-create-note (car keys))
        (message "No notes found. Select one key to create note: %s" keys)))))

;;;###autoload
(defun citar-open-links (key-or-keys)
  "Open URL or DOI link associated with KEY-OR-KEYS in a browser."
  (interactive (list (citar-select-refs)))
  (if-let ((resource (let* ((actions (bound-and-true-p embark-default-action-overrides))
                            (embark-default-action-overrides `(((url . ,this-command) . ,#'browse-url)
                                                               . ,actions)))
                       (citar--select-resource key-or-keys :links t))))
      (if (eq 'url (car resource))
          (browse-url (cdr resource))
        (error "Expected resource of type `url', got `%s': %S" (car resource) (cdr resource)))
    (message "No link found for %s" key-or-keys)))

;;;###autoload
(defun citar-open-entry (key)
  "Open bibliographic entry associated with the KEY."
  (interactive (list (citar-select-ref)))
  (when-let ((bibtex-files (citar--bibliography-files)))
    (bibtex-search-entry key t nil t)))

;;;###autoload
(defun citar-insert-bibtex (keys)
  "Insert bibliographic entry associated with the KEYS."
  (interactive (list (citar-select-refs)))
  (dolist (key keys)
    (citar--insert-bibtex key)))

(defun citar--insert-bibtex (key)
  "Insert the bibtex entry for KEY at point."
  (let* ((bibtex-files
          (citar--bibliography-files))
         (entry
          (with-temp-buffer
            (bibtex-set-dialect)
            (dolist (bib-file bibtex-files)
              (insert-file-contents bib-file))
            (bibtex-search-entry key)
            (let ((beg (bibtex-beginning-of-entry))
                  (end (bibtex-end-of-entry)))
              (buffer-substring-no-properties beg end)))))
    (unless (equal entry "")
      (insert entry "\n\n"))))

;;;###autoload
(defun citar-export-local-bib-file ()
  "Create a new bibliography file from citations in current buffer.

The file is titled \"local-bib\", given the same extention as
the first entry in `citar-bibliography', and created in the same
directory as current buffer."
  (interactive)
  (let* ((keys (citar--major-mode-function 'list-keys #'ignore))
         (ext (file-name-extension (car citar-bibliography)))
         (file (format "%slocal-bib.%s" (file-name-directory buffer-file-name) ext)))
    (with-temp-file file
      (dolist (key keys)
        (citar--insert-bibtex key)))))

;;;###autoload
(defun citar-insert-citation (keys &optional arg)
  "Insert citation for the KEYS.

Prefix ARG is passed to the mode-specific insertion function. It
should invert the default behaviour for that mode with respect to
citation styles. See specific functions for more detail."
  (interactive
   (if (citar--get-major-mode-function 'insert-citation)
       (list (citar-select-refs) current-prefix-arg)
     (error "Citation insertion is not supported for %s" major-mode)))
  (citar--major-mode-function
   'insert-citation
   #'ignore
   keys
   arg))

(defun citar-insert-edit (&optional arg)
  "Edit the citation at point.
ARG is forwarded to the mode-specific insertion function given in
`citar-major-mode-functions'."
  (interactive "P")
  (citar--major-mode-function
   'insert-edit
   (lambda (&rest _)
     (message "Citation editing is not supported for %s" major-mode))
   arg))

;;;###autoload
(defun citar-insert-reference (keys)
  "Insert formatted reference(s) associated with the KEYS."
  (interactive (list (citar-select-refs)))
  (insert (funcall citar-format-reference-function keys)))

;;;###autoload
(defun citar-copy-reference (keys)
  "Copy formatted reference(s) associated with the KEYS."
  (interactive (list (citar-select-refs)))
  (let ((references (funcall citar-format-reference-function keys)))
    (if (not (equal "" references))
        (progn
          (kill-new references)
          (message (format "Copied:\n%s" references)))
      (message "Key not found."))))

(defun citar-format-reference (keys)
  "Return formatted reference(s) for the elements of KEYS."
  (let* ((entries (mapcar #'citar-get-entry keys))
         (template (citar--get-template 'preview)))
    (with-temp-buffer
      (dolist (entry entries)
        (insert (citar-format--entry template entry)))
      (buffer-string))))

;;;###autoload
(defun citar-insert-keys (keys)
  "Insert KEYS citekeys."
  (interactive (list (citar-select-refs)))
  (citar--major-mode-function
   'insert-keys
   #'citar--insert-keys-comma-separated
   keys))

(defun citar--insert-keys-comma-separated (keys)
  "Insert comma separated KEYS."
  (insert (string-join keys ", ")))

(defun citar--add-file-to-library (key)
  "Add a file to the library for KEY.
The FILE can be added from an open buffer, a file path, or a
URL."
  (citar--check-configuration 'citar-library-paths)
  (let* ((source
          (char-to-string
           (read-char-choice
            "Add file from [b]uffer, [f]ile, or [u]rl? " '(?b ?f ?u))))
         (directory (if (cdr citar-library-paths)
                        (completing-read "Directory: " citar-library-paths)
                      (car citar-library-paths)))
         (file-path
          ;; Create the path without extension here.
          (expand-file-name key directory)))
    (pcase source
      ("b"
       (with-current-buffer (read-buffer-to-switch "Add file buffer: ")
         (let ((extension (file-name-extension (buffer-file-name))))
           (write-file (concat file-path "." extension) t))))
      ("f"
       (let* ((file (read-file-name "Add file: " nil nil t))
              (extension (file-name-extension file)))
         (copy-file file
                    (concat file-path "." extension) 1)))
      ("u"
       (let* ((url (read-string "Add file URL: "))
              (extension (url-file-extension url)))
         (when (< 1 extension)
           ;; TODO what if there is no extension?
           (url-copy-file url (concat file-path extension) 1)))))))

;;;###autoload
(defun citar-add-file-to-library (key)
  "Add a file to the library for KEY.
The FILE can be added either from an open buffer, a file, or a
URL."
  ;; Why is there a separate citar--add-file-to-library?
  (interactive (list (citar-select-ref)))
  (citar--add-file-to-library key))

;;;###autoload
(defun citar-run-default-action (keys)
  "Run the default action `citar-default-action' on KEYS."
  (funcall citar-default-action keys))

;;;###autoload
(defun citar-dwim ()
  "Run the default action on citation keys found at point."
  (interactive)
  (if-let ((keys (or (citar-key-at-point) (citar-citation-at-point))))
      (citar-run-default-action (if (listp keys) keys (list keys)))
    (user-error "No citation keys found")))

(defun citar--check-configuration (&rest variables)
  "Signal error if any VARIABLES have values of the wrong type.
VARIABLES should be the names of Citar customization variables."
  (dolist (variable variables)
    (unless (boundp variable)
      (error "Unbound variable in citar--check-configuration: %s" variable))
    (let ((value (symbol-value variable)))
      (pcase variable
        ((or 'citar-library-paths 'citar-notes-paths)
         (unless (and (listp value)
                      (seq-every-p #'stringp value))
           (error "`%s' should be a list of directories: %S" variable `',value)))
        ((or 'citar-library-file-extensions 'citar-file-note-extensions)
         (unless (and (listp value)
                      (seq-every-p #'stringp value))
           (error "`%s' should be a list of strings: %S" variable `',value)))
        ((or 'citar-has-files-functions 'citar-get-files-functions 'citar-file-parser-functions)
         (unless (and (listp value) (seq-every-p #'functionp value))
           (error "`%s' should be a list of functions: %S" variable `',value)))
        ((or 'citar-note-format-function)
         (unless (functionp value)
           (error "`%s' should be a function: %S" variable `',value)))
        (_
         (error "Unknown variable in citar--check-configuration: %s" variable))))))

(defun citar--check-notes-source (name config)
  "Signal error if notes source plist CONFIG has incorrect keys or values.
SOURCE must be a plist representing a notes source with NAME. See
`citar-notes-sources' for the list of valid keys and types."

  (let ((required '(:items :hasitems :open))
        (optional '(:name :category :create :transform :annotate))
        (keys (map-keys config)))
    (when-let ((missing (cl-set-difference required keys)))
      (error "Note source `%s' missing required keys: %s" name missing))
    (when-let ((extra (cl-set-difference keys (append required optional))))
      (warn "Note source `%s' has unknown keys: %s" name extra)))

  (pcase-dolist (`(,type . ,props)
                 '((functionp :items :hasitems :open :create :transform :annotate)
                   (stringp :name)
                   (symbolp :category)))
    (when-let ((wrongtype (seq-filter (lambda (prop)
                                        (when-let ((value (plist-get config prop)))
                                          (not (funcall type value)))) props)))
      (error "Note source `%s' keys must be of type %s: %s" name type wrongtype))))

(provide 'citar)
;;; citar.el ends here
