;; Tekuti
;; Copyright (C) 2008 Andy Wingo <wingo at pobox dot com>

;; This program is free software; you can redistribute it and/or    
;; modify it under the terms of the GNU General Public License as   
;; published by the Free Software Foundation; either version 3 of   
;; the License, or (at your option) any later version.              
;;                                                                  
;; This program is distributed in the hope that it will be useful,  
;; but WITHOUT ANY WARRANTY; without even the implied warranty of   
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the    
;; GNU General Public License for more details.                     
;;                                                                  
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, contact:
;;
;; Free Software Foundation           Voice:  +1-617-542-5942
;; 59 Temple Place - Suite 330        Fax:    +1-617-542-2652
;; Boston, MA  02111-1307,  USA       gnu@gnu.org

;;; Commentary:
;;
;; This is the main script that will launch tekuti.
;;
;;; Code:

(define-module (tekuti git)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 popen)
  #:use-module (tekuti util)
  #:use-module (tekuti config)
  #:use-module (scheme kwargs)
  #:use-module (match-bind)
  #:use-module (ice-9 regex) ; hack
  #:export (git git* ensure-git-repo git-ls-tree git-ls-subdirs
            parse-metadata parse-commit commit-utc-timestamp
            commit-parents make-tree fetch-heads))

(define (call-with-pipe pipe proc)
  (unwind-protect
   (proc pipe)
   (let ((ret (close-pipe pipe)))
     (if (not (eq? (status:exit-val ret) 0))
         (throw 'pipe-error proc ret)))))

(define (call-with-temp-file contents proc)
  (let* ((template (string-copy "/tmp/tekutiXXXXXX"))
         (tmp (mkstemp! template)))
    (display input tmp)
    (close tmp)
    (unwind-protect
     (proc template)
     (delete-file template))))

(define/kwargs (git* args (input #f) (env '()))
  ;; foolishness regarding env
  (define (nyam-nyam-nyam pipe)
    (read-delimited "" pipe))
  (cond
   (input
    (call-with-temp-file
     input
     (lambda (tempname)
       (let ((cmd (string-join `("env" ,@env ,*git* "--bare" ,@args "<" ,input) " ")))
         (pk cmd)
         (call-with-pipe
          (open-pipe* OPEN_BOTH "/bin/sh" "-c" cmd)
          nyam-nyam-nyam)))))
   (else
    (pk args)
    (call-with-pipe
     (apply open-pipe* OPEN_READ *git* "--bare" args)
     nyam-nyam-nyam))))

(define (git . args)
  (git* args))

(define (is-dir? path)
  (catch 'system-error
         (lambda () (eq? (stat:type (stat path)) 'directory))
         (lambda args #f)))

(define (ensure-git-repo)
  (let ((d (expanduser *git-dir*)))
    (if (not (is-dir? d))
        (begin
          (mkdir d)
          (chdir d)
          (git "init"))
        (chdir d))))

(define (git-ls-tree treeish path)
  (match-lines (git "ls-tree" treeish (or path "."))
               "^(.+) (.+) (.+)\t(.+)$" (_ mode type object name)
               (list mode type object name)))

(define (git-ls-subdirs treeish path)
  (match-lines (git "ls-tree" treeish (or path "."))
               "^(.+) tree (.+)\t(.+)$" (_ mode object name)
               (cons name object)))

(define (parse-metadata treeish . specs)
  (filter
   identity
   (match-lines (git "cat-file" "blob" treeish)
                "^([^: ]+): +(.*)$" (_ k v)
                (let* ((k (string->symbol k))
                       (parse (assq-ref k specs)))
                  (if parse
                      (catch 'parse-error
                             (lambda ()
                               (cons k (parse v)))
                             (lambda args #f))
                      (cons k v))))))

(define (parse-commit commit)
  (let ((text (git "cat-file" "commit" commit)))
    (match-bind
     "\n\n(.*)$" text (_ message)
     (acons
      'message message
      (match-lines (substring text 0 (- (string-length text) (string-length _)))
                   "^([^ ]+) (.*)$" (_ k v)
                   (cons (string->symbol k) v))))))

(define (commit-utc-timestamp commit)
  (match-bind
   "^(.*) ([0-9]+) ([+-][0-9]+)" (assq-ref (parse-commit commit) 'committer)
   (_ who ts tz)
   (let ((ts (string->number ts)) (tz (string->number tz)))
     (- ts (* (+ (* (quotient tz 100) 60) (remainder tz 100)) 60)))))

(define (commit-parents commit)
  (map cdr
       (filter
        (lambda (x) (eq? (car x) 'parent))
        (parse-commit commit))))

(define (make-tree alist)
  (string-trim-both
   (git* '("mktree")
         #:input (string-join
                  (map (lambda (pair)
                         (let ((name (car pair)) (sha (cdr pair)))
                           (format #f "040000 tree ~a\t~a" sha name)))
                       alist)
                  "\n" 'suffix))))

(define (git-rev-parse rev)
  (string-trim-both (git "rev-parse" rev)))

(define (fetch-heads . heads)
  (let ((master (git-rev-parse "master")))
    (acons
     'master master
     (map (lambda (spec)
            (let ((ref (car spec)) (reindex (cdr spec)))
              (let ((head (false-if-exception
                           (git-rev-parse (car spec)))))
                (cons
                 ref
                 (if (and head (member master (commit-parents head)))
                     head
                     (and=> (reindex master)
                            (lambda (new)
                              (if (not (false-if-exception 
                                        (if head
                                            (git "update-ref" ref new head)
                                            (git "branch" ref new))))
                                  (dbg "couldn't update ref ~a to ~a" ref new))
                              new)))))))
          heads))))
