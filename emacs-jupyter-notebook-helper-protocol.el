;;; emacs-jupyter-notebook-helper-protocol.el --- EJN helper framing -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)

(defconst ejn-helper-protocol-version 1)
(defconst ejn-helper-protocol-max-to-emacs-frame 262144)
(defconst ejn-helper-protocol-max-to-helper-frame 1048576)
(defconst ejn-helper-protocol-max-raw-accumulator 1048576)

(define-error 'ejn-helper-protocol-error "EJN helper protocol error")
(define-error 'ejn-helper-protocol-frame-too-large "EJN frame too large" 'ejn-helper-protocol-error)
(define-error 'ejn-helper-protocol-invalid-json "Invalid EJN JSON" 'ejn-helper-protocol-error)

(cl-defstruct (ejn-helper-protocol-decoder
               (:constructor ejn-helper-protocol--make-decoder))
  max-frame accumulator-limit chunks tail head-offset buffered need partial failed)

(defun ejn-helper-protocol--fail (decoder code message)
  (setf (ejn-helper-protocol-decoder-chunks decoder) nil
        (ejn-helper-protocol-decoder-tail decoder) nil
        (ejn-helper-protocol-decoder-head-offset decoder) 0
        (ejn-helper-protocol-decoder-buffered decoder) 0
        (ejn-helper-protocol-decoder-need decoder) nil
        (ejn-helper-protocol-decoder-partial decoder) nil
        (ejn-helper-protocol-decoder-failed decoder) t)
  (signal 'ejn-helper-protocol-error (list code message)))

(defun ejn-helper-protocol-make-decoder (max-frame &optional accumulator-limit)
  "Create a decoder with complete-wire MAX-FRAME ceiling."
  (unless (and (integerp max-frame) (> max-frame 4))
    (error "max-frame must be a positive complete-frame size"))
  (setq accumulator-limit (or accumulator-limit max-frame))
  (unless (and (integerp accumulator-limit) (>= accumulator-limit max-frame))
    (error "accumulator-limit must be at least max-frame"))
  (ejn-helper-protocol--make-decoder :max-frame max-frame
                                      :accumulator-limit accumulator-limit
                                      :chunks nil :tail nil :head-offset 0 :buffered 0))

(defun ejn-helper-protocol--json-bytes (object)
  (unless (hash-table-p object)
    (signal 'ejn-helper-protocol-error '(invalid-request "envelope must be object")))
  (condition-case nil
      (encode-coding-string (json-serialize object :null-object :null
                                           :false-object :false)
                            'utf-8 t)
    (error (signal 'ejn-helper-protocol-error '(protocol-error "cannot encode JSON")))))

(defun ejn-helper-protocol-encode (object max-frame)
  "Encode OBJECT as a complete frame, enforcing MAX-FRAME bytes."
  (unless (and (integerp max-frame) (> max-frame 4))
    (error "max-frame must be a positive complete-frame size"))
  (let* ((payload (ejn-helper-protocol--json-bytes object))
         (length (length payload)))
    (when (> (+ length 4) max-frame)
      (signal 'ejn-helper-protocol-error '(frame-too-large "frame exceeds limit")))
    (concat (unibyte-string (logand (ash length -24) 255)
                            (logand (ash length -16) 255)
                            (logand (ash length -8) 255)
                            (logand length 255))
            payload)))

(defun ejn-helper-protocol--parse (decoder payload)
  (condition-case nil
      (let* ((text (decode-coding-string payload 'utf-8 nil))
             (_roundtrip (unless (string= payload (encode-coding-string text 'utf-8 t))
                           (error "invalid UTF-8")))
             (object (json-parse-string text :object-type 'hash-table
                                        :null-object :null :false-object :false)))
        (unless (hash-table-p object)
          (ejn-helper-protocol--fail decoder 'protocol-error "JSON payload must be object"))
        object)
    (error (ejn-helper-protocol--fail decoder 'protocol-error "invalid UTF-8 or JSON"))))

(defun ejn-helper-protocol-decoder-feed (decoder bytes)
  "Feed unibyte BYTES and return complete decoded JSON objects."
  (when (ejn-helper-protocol-decoder-failed decoder)
    (ejn-helper-protocol--fail decoder 'protocol-error "decoder is closed"))
  (unless (and (stringp bytes) (not (multibyte-string-p bytes)))
    (ejn-helper-protocol--fail decoder 'protocol-error "decoder accepts unibyte bytes only"))
  (when (> (+ (ejn-helper-protocol-decoder-buffered decoder) (length bytes))
           (ejn-helper-protocol-decoder-accumulator-limit decoder))
    (ejn-helper-protocol--fail decoder 'protocol-error "raw accumulator exceeded"))
  (when (> (length bytes) 0)
    (let ((cell (list (copy-sequence bytes))))
      (if (ejn-helper-protocol-decoder-tail decoder)
          (setcdr (ejn-helper-protocol-decoder-tail decoder) cell)
        (setf (ejn-helper-protocol-decoder-chunks decoder) cell))
      (setf (ejn-helper-protocol-decoder-tail decoder) cell)
      (cl-incf (ejn-helper-protocol-decoder-buffered decoder) (length bytes))))
  (let (objects done)
    (while (and (not done)
                (or (ejn-helper-protocol-decoder-need decoder)
                    (>= (ejn-helper-protocol-decoder-buffered decoder) 4)))
      (unless (ejn-helper-protocol-decoder-need decoder)
        (let ((prefix (ejn-helper-protocol--take decoder 4)))
          (setf (ejn-helper-protocol-decoder-need decoder)
                (+ (ash (aref prefix 0) 24) (ash (aref prefix 1) 16)
                   (ash (aref prefix 2) 8) (aref prefix 3)))
          (when (> (+ 4 (ejn-helper-protocol-decoder-need decoder))
                   (ejn-helper-protocol-decoder-max-frame decoder))
            (ejn-helper-protocol--fail decoder 'frame-too-large "frame exceeds limit"))))
      (if (and (ejn-helper-protocol-decoder-need decoder)
               (>= (ejn-helper-protocol-decoder-buffered decoder)
                   (ejn-helper-protocol-decoder-need decoder)))
          (progn
            (push (ejn-helper-protocol--parse decoder
                                              (ejn-helper-protocol--take decoder (ejn-helper-protocol-decoder-need decoder)))
                  objects)
            (setf (ejn-helper-protocol-decoder-need decoder) nil))
        (setq done t)))
    (setf (ejn-helper-protocol-decoder-partial decoder)
          (or (ejn-helper-protocol-decoder-need decoder)
              (> (ejn-helper-protocol-decoder-buffered decoder) 0)))
    (nreverse objects)))

(defun ejn-helper-protocol--take (decoder count)
  "Consume COUNT bytes from DECODER's FIFO with bounded chunk copies."
  (let ((result (make-string count 0)) (position 0))
    (while (> count 0)
      (let* ((cell (ejn-helper-protocol-decoder-chunks decoder))
             (chunk (car cell))
             (offset (ejn-helper-protocol-decoder-head-offset decoder))
             (available (- (length chunk) offset))
             (amount (min count available)))
        (store-substring result position (substring chunk offset (+ offset amount)))
        (setq position (+ position amount) count (- count amount))
        (cl-decf (ejn-helper-protocol-decoder-buffered decoder) amount)
        (if (= amount available)
            (setf (ejn-helper-protocol-decoder-chunks decoder) (cdr cell)
                  (ejn-helper-protocol-decoder-head-offset decoder) 0)
          (cl-incf (ejn-helper-protocol-decoder-head-offset decoder) amount))))
    (unless (ejn-helper-protocol-decoder-chunks decoder)
      (setf (ejn-helper-protocol-decoder-tail decoder) nil))
    result))

(defun ejn-helper-protocol-decoder-unconsumed-bytes (decoder)
  "Materialize, without consuming, the currently buffered bytes."
  (let ((result (make-string (ejn-helper-protocol-decoder-buffered decoder) 0))
        (position 0) (first t)
        (tail (ejn-helper-protocol-decoder-chunks decoder)))
    (while tail
      (let* ((cell tail) (chunk (car cell))
             (offset (if first (ejn-helper-protocol-decoder-head-offset decoder) 0)))
        (setq first nil)
        (store-substring result position (substring chunk offset))
        (cl-incf position (- (length chunk) offset))
        (setq tail (cdr cell))))
    result))

(defun ejn-helper-protocol-decoder-partial-p (decoder)
  "Return non-nil when DECODER retains an incomplete frame."
  (ejn-helper-protocol-decoder-partial decoder))

(defun ejn-helper-protocol-decoder-buffered-bytes (decoder)
  (ejn-helper-protocol-decoder-buffered decoder))

(defun ejn-helper-protocol-decoder-expire-partial (decoder)
  "Fail closed when a caller's partial-frame deadline expires."
  (when (ejn-helper-protocol-decoder-partial decoder)
    (ejn-helper-protocol--fail decoder 'protocol-error "partial frame timeout")))

(provide 'emacs-jupyter-notebook-helper-protocol)
;;; emacs-jupyter-notebook-helper-protocol.el ends here
