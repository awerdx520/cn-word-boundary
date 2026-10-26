;;; cn-word-boundary-cns.el --- cn-word-boundary 的 cns（cppjieba）后端适配  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; Author: thomas
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: wp, i18n
;; URL: https://github.com/awerdx520/cn-word-boundary

;;; Commentary:
;;
;; 把 cns（cppjieba 的 `cnws' 常驻进程）适配为 `cn-word-boundary' 的分词后端。
;; 主文件的 `cn-word-boundary-backend' 取 `cns' 时，`cn-word-boundary' 会按需
;; 加载本文件，并调用 `cn-word-boundary-cns--ensure' 校验可执行文件与词表、
;; 惰性 `require' cns 包、注入启动参数、拉起常驻进程。
;;
;; 本文件**不**在顶层 `require' cns：cns 只在 `cn-word-boundary-cns--ensure'
;; 里按需加载，因此单独加载本文件（例如 `emacs -Q --batch -l
;; cn-word-boundary-cns'）不会因 cns 未安装而失败。cns 未安装或不可用时由主
;; 文件把后端降级为逐字边界并只提示一次，功能继续可用。
;;
;; 重要约束：`cnws' 的 WIDE_CHAR_SIZE 硬编码为 3，段内长度按「字节数 / 3」
;; 计算，含 ASCII 或 emoji 的字符串会被算错，边界位置随之错位。因此送进
;; `cn-word-boundary-cns-segmenter' 的文本必须只含汉字——这一点由主文件的
;; 汉字段切分（`cn-word-boundary--han-run'）保证，本文件不做二次校验。

;;; Code:

;; cl-lib → `cl-every' / `cl-remove-if'
(require 'cl-lib)

;; 依赖方向恒为 cns 适配层 → 主文件，绝不反向。
(require 'cn-word-boundary)

;;; 编译期声明

;; 编译期声明 cns 侧的全局符号：cns 是延迟加载的第三方包，单文件字节编译时
;; 尚未加载，不声明会报 free-vars 噪音，掩盖本包真正的自由变量信号。
;; `(defvar SYMBOL)'（无初值）只标记 special、不建立值绑定，故
;; `(boundp 'cns-process)' 等守卫在运行期仍如实反映 cns 是否已加载。
(eval-when-compile
  (defvar cns-prog)
  (defvar cns-dict-directory)
  (defvar cns-process-type)
  (defvar cns-process-shell-command)
  (defvar cns-recent-segmentation)
  (defvar cns-recent-segmentation-limit)
  (defvar cns-process)
  (defvar cns-buffer-list))

;;; 配置

(defcustom cn-word-boundary-cns-prog (executable-find "cnws")
  "可执行文件 cnws 的路径.
默认在加载本文件时按 `executable-find' 探测一次；nil 表示未探测到，此时后端
不可用（`cn-word-boundary' 会降级为逐字边界）。"
  :type '(choice (const :tag "自动探测" nil) file)
  :group 'editing)

(defcustom cn-word-boundary-cns-dict-directory nil
  "存放 cppjieba 词表的目录.
默认 nil：词表位置与安装方式（straight / 手工 / 发行版包）强相关，由宿主或
用户显式设置，本包不猜测路径。"
  :type '(choice (const :tag "未设置" nil) directory)
  :group 'editing)

(defcustom cn-word-boundary-cns-recent-limit 20
  "缓存 cns 分词结果的条数.  越大连续移动越快，代价是内存."
  :type 'integer
  :group 'editing)

;;; 可用性探测

(defconst cn-word-boundary-cns--dict-files
  '("jieba.dict.utf8" "hmm_model.utf8" "user.dict.utf8"
    "idf.utf8" "stop_words.utf8")
  "分词程序 cnws 需要的 5 份词表文件名.")

(defun cn-word-boundary-cns--dict-complete-p (dir)
  "判断 DIR 下 5 份词表是否齐全."
  (and (stringp dir)
       (file-directory-p dir)
       (cl-every (lambda (name)
                   (file-exists-p (expand-file-name name dir)))
                 cn-word-boundary-cns--dict-files)))

(defun cn-word-boundary-cns-available-p ()
  "判断 cns 后端此刻是否可用：可执行文件在、词表齐.
只看文件系统，不加载 cns、不启动进程。"
  (let ((prog cn-word-boundary-cns-prog))
    (and (stringp prog)
         (file-executable-p prog)
         (cn-word-boundary-cns--dict-complete-p
          cn-word-boundary-cns-dict-directory))))

;;; 后端启动

(defun cn-word-boundary-cns--ensure ()
  "确保 cns 后端就绪.  就绪返回 t；任何失败降级并返回 nil，不向宿主抛错."
  (let ((prog cn-word-boundary-cns-prog)
        (dict cn-word-boundary-cns-dict-directory))
    (condition-case err
        (progn
          (unless (and (stringp prog)
                       (file-executable-p prog)
                       (cn-word-boundary-cns--dict-complete-p dict))
            (error "找不到 cnws 或词表：%s / %s" prog dict))
          ;; 惰性加载：只有确认文件齐备后才 require，避免 cns 未安装时
          ;; 在加载阶段就失败。
          (require 'cns)
          ;; HACK: 直改 cns 的 defvar 以注入经 `shell-quote-argument' 转义的启动命令
          ;; （其 `cns-set-process-shell-command' 不做转义），避免路径含空格或 shell
          ;; 元字符时的注入与启动失败。
          (setq cns-prog prog
                cns-dict-directory dict
                cns-process-type 'shell
                cns-process-shell-command
                (mapconcat #'shell-quote-argument
                           (cons prog (mapcar (lambda (name) (expand-file-name name dict))
                                              cn-word-boundary-cns--dict-files))
                           " ")
                cns-recent-segmentation-limit cn-word-boundary-cns-recent-limit)
          (unless (process-live-p cns-process)
            (cns-start-process))
          (setq cn-word-boundary--backend-state 'ready)
          ;; 补注册：cns 为延迟加载，加载前已启用本 mode 的 buffer 未进
          ;; `cns-buffer-list'，不补注册会因误判为空而过早停掉进程。
          (dolist (buf (buffer-list))
            (with-current-buffer buf
              (when (bound-and-true-p cn-word-boundary-mode)
                (cn-word-boundary-cns-register-buffer))))
          t)
      (error
       (setq cn-word-boundary--backend-state 'degraded)
       (message "中文词边界：cns 后端不可用，降级为逐字边界（%s）"
                (error-message-string err))
       nil))))

;;; 分词与健康检查

(defun cn-word-boundary-cns-segmenter (string)
  "用 cns 对 STRING 分词并返回各词长度列表.  STRING 必须只含汉字.
上游 cns 在后端刚启动的首次请求可能返回 nil，且该 nil 会被写进
`cns-recent-segmentation' 缓存而永久生效；此处清掉该条并重试一次。"
  (let ((segs (cns-segmentation-handler string)))
    (when (and (null segs) (boundp 'cns-recent-segmentation))
      ;; HACK: 清掉被污染的 nil 条目后重试分词；`cns-recent-segmentation' 是
      ;; cns 的内部缓存结构（非 defcustom），只能直改它来让缓存项重新计算。
      (setq cns-recent-segmentation
            (cl-remove-if (lambda (pair) (equal (car pair) string))
                          cns-recent-segmentation))
      (setq segs (cns-segmentation-handler string)))
    segs))

(defun cn-word-boundary-cns-healthy-p ()
  "cns 常驻进程是否存活.  cns 尚未加载时返回 nil."
  (and (boundp 'cns-process)
       (process-live-p cns-process)))

;;; buffer 注册与进程回收

(defun cn-word-boundary-cns-register-buffer ()
  "把当前 buffer 记入 cns 的使用列表.  cns 未加载时什么也不做."
  (when (fboundp 'cns-buffer-list-add-buffer)
    (cns-buffer-list-add-buffer)))

(defun cn-word-boundary-cns--stop-if-idle ()
  "cns 进程存活且没有任何 buffer 使用时停掉它."
  (when (and (bound-and-true-p cns-process)
             (process-live-p cns-process)
             (null (bound-and-true-p cns-buffer-list)))
    (cns-stop-process)))

(defun cn-word-boundary-cns-unregister-buffer ()
  "把当前 buffer 从 cns 使用列表移除；已无 buffer 使用时停掉进程.
cns 未加载时 `cns-buffer-list' 未绑定，此时只会走 `--stop-if-idle' 的空转路径。"
  (when (fboundp 'cns-buffer-list-delete-buffer)
    (cns-buffer-list-delete-buffer))
  (unless (and (bound-and-true-p cns-buffer-list)
               (length> cns-buffer-list 0))
    (cn-word-boundary-cns--stop-if-idle)))

;;; 重置

(defun cn-word-boundary-cns-reset ()
  "重置 cns 后端：状态置回 `unknown'，进程存活时停掉它.
由 `cn-word-boundary-reset-backend' 调用，也便于用户手工排障时单独调用。"
  (setq cn-word-boundary--backend-state 'unknown)
  (when (and (fboundp 'cns-stop-process)
             (boundp 'cns-process)
             (process-live-p cns-process))
    (cns-stop-process)))

(provide 'cn-word-boundary-cns)
;;; cn-word-boundary-cns.el ends here
