;;; with-wireguard.el --- namespaced wireguard management -*- lexical-binding: t -*-

;; This is free and unencumbered software released into the public domain.

;; Author: Bas Alberts <bas@anti.computer>
;; URL: https://github.com/anticomputer/with-wireguard.el

;; Version: 0.1.0-pre
;; Package-Requires: ((emacs "25") (cl-lib "0.5"))

;; Keywords: comm

;;; Commentary

;; with-wireguard.el provides primitives for managing a wireguard vpn
;; inside a dedicated network namespace, this is useful to e.g. spawn
;; a browser or terminal that requires access to certain network
;; resources, without affecting any routing on main network namespace

;; It is compatible with wg-quick style configuration files.

;; Tips and Tricks

;; If this misbehaves on your system you likely need:
;;
;; (connection-local-set-profile-variables
;;  'remote-without-auth-sources '((auth-sources . nil)))
;;
;; (connection-local-set-profiles
;;  '(:application tramp) 'remote-without-auth-sources)
;;
;; In your TRAMP configuration, to prevent local sudo timeouts.

;; Disclaimer

;; This is experimental software written for my personal use and subject
;; to heavy feature iteration, use at your own discretion

;;; Code
(eval-when-compile (require 'subr-x))
(eval-when-compile (require 'cl-lib))

;; only use this for safety critical commands
(defun with-wg--assert-shell-command (cmd buffer)
  "Assert that a 'shell-command' CMD did not return error."
  (cl-assert (equal 0 (shell-command cmd buffer)) t
             (format "Error executing: %s" cmd)))

(defun with-wg--sudo-process (name buffer &rest args)
  "Sudo exec a command ARGS as NAME and output to BUFFER."
  ;; in case we want to juggle any buffer local state
  (with-current-buffer buffer
    (message "Executing: %s" args)
    (let* ((tramp-connection-properties '((nil "session-timeout" nil)))
           (default-directory "/sudo:root@localhost:/tmp")
           (process (apply #'start-file-process name buffer args)))
      (when (process-live-p process)
        (set-process-filter
         process #'(lambda (_proc string)
                     (mapc 'message (split-string string "\n"))))))))

(defun with-wg--sudo-shell-command (cmd buffer)
  "Sudo exec a shell command CMD and output to BUFFER."
  ;; in case we want to juggle any buffer local state
  (with-current-buffer buffer
    (message "Executing: %s" cmd)
    (let* ((tramp-connection-properties '((nil "session-timeout" nil)))
           (default-directory "/sudo:root@localhost:/tmp"))
      (with-wg--assert-shell-command cmd buffer))))

(defun with-wg-quick-conf (config)
  "Pull Address and DNS from wg-quick CONFIG.
Returns a setconf compatible configuration."
  (with-temp-buffer
    (insert-file-contents-literally (expand-file-name config) nil)
    (let
        ((lines
          (cl-loop while (not (eobp))
                   collect
                   (prog1 (buffer-substring-no-properties
                           (line-beginning-position)
                           (line-end-position))
                     (forward-line 1)))))
      (let ((conf (make-temp-file "wg"))
            (address nil)
            (dns nil))
        (with-temp-file conf
          (cl-loop for line in lines
                   do
                   ;; filter any crud that's not wg-quick compatible
                   (cond ((string-match "Address *= *\\(.*\\)? *\n*" line)
                          (setq address (match-string 1 line)))
                         ((string-match "DNS *= *\\(.*\\)? *\n*" line)
                          (setq dns (match-string 1 line)))
                         (t (insert (concat line "\n"))))))
        ;; return conf, address, dns
        (list conf address dns)))))

;; XXX: TODO make this create a /etc/netns/namespace/resolv.conf if dns is set
(defun with-wg--inflate-ns (config &optional address dns)
  "Create a namespace for wireguard CONFIG.

Optionally, override CONFIG with ADDRESS and DNS."
  (cl-destructuring-bind (tmp-config conf-address conf-dns) (with-wg-quick-conf config)
    ;; allow user to override if they want, default to quick conf compatibility
    (let* ((address (or address conf-address))
           (_dns (or dns conf-dns))
           (interface (make-temp-name "if"))
           (namespace (make-temp-name "ns"))
           (procbuf (get-buffer-create (format " *with-wireguard-%s*" namespace)))
           ;; deal with systems where root might not have these in PATH
           (ip (executable-find "ip"))
           (wg (executable-find "wg"))
           (inflate-cmds
            `((,ip "netns" "add" ,namespace)
              (,ip "link" "add" ,interface "type" "wireguard")
              (,ip "link" "set" ,interface "netns" ,namespace)
              (,ip "-n" ,namespace "addr" "add" ,address "dev" ,interface)
              (,ip "netns" "exec" ,namespace ,wg "setconf" ,interface ,tmp-config)
              (,ip "-n" ,namespace "link" "set" ,interface "up")
              (,ip "-n" ,namespace "route" "add" "default" "dev" ,interface))))
      (cl-loop for args in inflate-cmds
               for cmd = (string-join args " ")
               do (with-wg--sudo-shell-command cmd procbuf))
      ;; delete the temporary config copy
      (delete-file tmp-config)
      ;; return the namespace
      namespace)))

(defun with-wg--deflate-ns (namespace)
  "Delete wireguard NAMESPACE."
  (let* ((procbuf (get-buffer-create (format " *with-wireguard-%s*" namespace)))
         (ip (executable-find "ip"))
         ;; keep this as a list in case we want to add additional teardowns
         (deflate-cmds `((,ip "netns" "delete" ,namespace))))
    (cl-loop for args in deflate-cmds
             for cmd = (string-join args " ")
             do (with-wg--sudo-shell-command cmd procbuf))
    (kill-buffer procbuf)))

(defun with-wg-shell-command (cmd namespace &optional user)
  "Run shell command CMD in NAMESPACE as USER."
  (let ((user (or user (user-real-login-name)))
        (procbuf (get-buffer-create (format " *with-wireguard-%s*" namespace))))
    (with-wg--sudo-process
     "wg: exec" procbuf
     "/bin/sh" "-c"
     (format "ip netns exec %s sudo -u %s /bin/sh -c \"%s\""
             namespace user (shell-quote-argument cmd)))))

;; this expects lexical-binding to be t
(cl-defmacro with-wg ((config) ns &body body)
  "Evaluate BODY with WIREGUARD-CONFIG with symbol NS bound to active namespace."
  `(let ((,ns (with-wg--inflate-ns (expand-file-name ,config))))
     ,@body))

(defun with-wg-execute (config cmd)
  "Execute shell command CMD in a network namespace for wireguard CONFIG."
  (interactive "fWireguard config: \nsShell command: ")
  (with-wg (config) namespace
           (with-wg-shell-command cmd namespace)
           namespace))

(provide 'with-wireguard)
;;; with-wireguard.el ends here
