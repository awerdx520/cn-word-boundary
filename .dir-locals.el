;;; Directory Local Variables            -*- no-byte-compile: t -*-
;;; For more information see (info "(emacs) Directory Variables")

;; 与宿主配置同策略：自制 elisp 保持不编译，避免陈旧 .elc 优先加载。
;; test/ 尤其必须不编译，否则新增断言「未执行却显示全绿」。
((nil . ((vc-directory-exclusion-list . (".git" ".local"))))
 ("." . ((emacs-lisp-mode . ((no-byte-compile . t)))))
 ("test" . ((emacs-lisp-mode . ((no-byte-compile . t))))))
