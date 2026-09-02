;;; run-panel-graphical.el --- Graphical panel stress entry point -*- lexical-binding: t; -*-

;;; Commentary:
;; Load this file in a live graphical Emacs and call
;; `ejn-ag3-run-graphical-panel-gate'.  Unlike the batch ERT entry points, it
;; leaves lifecycle control with the caller (for example, emacsclient).

;;; Code:

(require 'ert)
(require 'emacs-jupyter-notebook-panel-stress)

(defun ejn-ag3-run-graphical-panel-gate ()
  "Run the graphical 100-publication panel gate and return bounded evidence."
  (unless (display-graphic-p)
    (error "The graphical panel gate requires a live graphical frame"))
  (let (failure)
    (let ((stats
           (ert-run-tests
            "^ejn-ag3-panel-100-publications-retire-with-bounded-state$"
            (lambda (event &rest arguments)
              (when (eq event 'test-ended)
                (let ((test (nth 1 arguments))
                      (result (nth 2 arguments)))
                  (unless (ert-test-result-expected-p test result)
                    (setq failure
                          (list :name (ert-test-name test)
                                :type (type-of result)
                                :reason (ert-reason-for-test-result result))))))))))
      (list :graphic t
            :total (ert-stats-total stats)
            :expected (ert-stats-completed-expected stats)
            :unexpected (ert-stats-completed-unexpected stats)
            :failure failure))))

(provide 'run-panel-graphical)
;;; run-panel-graphical.el ends here
