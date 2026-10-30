;;; cn-word-boundary.el --- 按中文词边界移动与分词  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; 首行的 `byte-compile-warnings' 只抑制 `unresolved'（cns 适配层的符号在单
;; 文件编译时未定义）与 `noruntime'，**不**抑制 `free-vars'——后者是本项目保留
;; 的核心信号通道，只能靠注入真实定义清零。

;; Author: thomas
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: wp, i18n
;; URL: https://github.com/awerdx520/cn-word-boundary

;;; Commentary:
;;
;; 让 Emacs 的「词」在汉字内部按分词边界移动，且不改任何键位。
;;
;; 原理：只设置 buffer-local 的 `find-word-boundary-function-table'，并且只把
;; 汉字（category ?C）映射到本包的 handler。于是 `forward-word' 及其全部派生
;; 功能——evil 的 w/b/e/ge、M-f/M-b/M-d/M-DEL、kill-word、mark-word、
;; transpose-words、thing-at-point、isearch 的 C-w——都会在汉字内部按词移动；
;; 英文与中英混排因 char-table 对应条目为 nil 而回落默认边界，行为不变。
;; 注意 `count-words' / `count-words-region' 走 `forward-word-strictly'，
;; **不**受该 char-table 影响，中文仍按整块计数。
;;
;; 后端可插拔：`cn-word-boundary-backend' 取 `cns'（由独立的
;; `cn-word-boundary-cns.el' 适配，本文件不依赖它）、`char'（逐字边界，不依赖
;; 任何外部程序）或一个自定义分词函数。后端不可用（未安装、进程启动失败、
;; 分词异常）时自动降级为逐字边界，只提示一次，保证功能可用且不中断。
;;
;; 本包自身不启动任何全局 mode：是否 `(global-cn-word-boundary-mode 1)' 由
;; 宿主配置决定；本文件顶层无任何启用副作用（不启 mode、不起定时器、不起进程）。

;;; Code:

;;; 配置

(defcustom cn-word-boundary-excluded-modes
  '(vterm-mode term-mode eshell-mode shell-mode)
  "不启用中文词边界的 major mode 列表."
  :type '(repeat symbol)
  :group 'editing)

(defcustom cn-word-boundary-backend 'cns
  "分词后端.
取值 `cns' 用 cns 分词器（由 `cn-word-boundary-cns.el' 适配；未安装或启动
失败时降级为逐字边界）；取值 `char' 直接逐字切分，不依赖任何外部程序；也可以
直接给一个函数，它接收字符串并返回各词长度组成的列表。"
  :type '(choice (const :tag "cns 分词后端" cns)
                 (const :tag "逐字（不依赖外部程序）" char)
                 (function :tag "自定义分词函数"))
  :group 'editing)

;;; 后端状态与分词器

;; 状态留在本文件：cns 适配层（cn-word-boundary-cns.el）通过 `setq' 更新它，
;; 这样本文件不需要认识任何 cns 变量。
(defvar cn-word-boundary--backend-state 'unknown
  "后端状态.  `unknown' 未探测，`ready' 可用，`degraded' 已降级.")

(defun cn-word-boundary--char-segmenter (string)
  "逐字边界：返回 STRING 字符个数个 1.  空串返回 nil."
  (make-list (length string) 1))

(defun cn-word-boundary--default-segmenter (string)
  "按 `cn-word-boundary-backend' 分派的分词函数.
自定义函数直接调用；`cns' 在适配层已加载时调用它，否则逐字；其余取值逐字。"
  (cond
   ((eq cn-word-boundary-backend 'cns)
    (if (fboundp 'cn-word-boundary-cns-segmenter)
        (cn-word-boundary-cns-segmenter string)
      (cn-word-boundary--char-segmenter string)))
   ((eq cn-word-boundary-backend 'char)
    (cn-word-boundary--char-segmenter string))
   ((functionp cn-word-boundary-backend)
    (funcall cn-word-boundary-backend string))
   (t (cn-word-boundary--char-segmenter string))))

(defvar cn-word-boundary-segmenter-function #'cn-word-boundary--default-segmenter
  "分词函数：接收字符串，返回各词长度组成的列表.  可为 buffer-local.
降级时由 `cn-word-boundary--ensure-ready' 改为逐字边界。")

(defun cn-word-boundary--ensure-backend ()
  "确保 `cn-word-boundary-backend' 指定的后端可用.
可用时把状态置为 `ready' 并返回 t；不可用时置为 `degraded' 并返回 nil。
降级提示只发一次：状态已是 `degraded' 时直接返回，不重复提示。"
  (cond
   ((eq cn-word-boundary--backend-state 'ready) t)
   ((eq cn-word-boundary--backend-state 'degraded) nil)
   ((eq cn-word-boundary-backend 'cns)
    (condition-case err
        (progn
          (require 'cn-word-boundary-cns nil t)
          ;; 适配层成功时已自行置 `ready'；此处只在确认成功时再置一次，避免把
          ;; 适配层写入的 `degraded' 覆盖回 `ready'（会导致降级提示重复打印、
          ;; 健康检查反复重探测）。
          (when (if (fboundp 'cn-word-boundary-cns--ensure)
                    (cn-word-boundary-cns--ensure)
                  (error "未找到 cns 后端适配层 cn-word-boundary-cns.el"))
            (setq cn-word-boundary--backend-state 'ready))
          ;; 适配层可能自行降级（进程缺失等）而不抛错，故返回值取自最终状态，
          ;; 与 docstring「不可用时返回 nil」保持一致。
          (eq cn-word-boundary--backend-state 'ready))
      (error
       (setq cn-word-boundary--backend-state 'degraded)
       (message "中文词边界：%s 后端不可用，降级为逐字边界（%s）"
                cn-word-boundary-backend (error-message-string err))
       nil)))
   ((functionp cn-word-boundary-backend)
    ;; 自定义函数的可用性由用户负责，这里只记录状态
    (setq cn-word-boundary--backend-state 'ready)
    t)
   (t
    ;; `char' 及未知取值：本来就用逐字边界，不算降级，故不提示
    (setq cn-word-boundary--backend-state 'degraded)
    nil)))

(defun cn-word-boundary--ensure-ready ()
  "确保后端就绪，不可用时把当前 buffer 降级为逐字分词.
适配层报告不健康（进程意外死亡等）时重置状态并尝试重建；恢复后清除
buffer-local 的逐字覆盖，回到正常分词。只在 cns 后端下检查进程健康；
自定义函数后端不受 cns 进程状态影响。"
  ;; 判据必须先限定 backend：自定义函数后端不依赖 cns 进程，而 cns 适配层
  ;; 一旦被加载过，健康检查就可能恒为 nil，把 `ready' 反复重置为 `unknown'。
  (when (and (eq cn-word-boundary-backend 'cns)
             (eq cn-word-boundary--backend-state 'ready)
             (fboundp 'cn-word-boundary-cns-healthy-p)
             (not (cn-word-boundary-cns-healthy-p)))
    (setq cn-word-boundary--backend-state 'unknown))
  (unless (eq cn-word-boundary--backend-state 'ready)
    (cn-word-boundary--ensure-backend)
    (if (eq cn-word-boundary--backend-state 'ready)
        (kill-local-variable 'cn-word-boundary-segmenter-function)
      (setq-local cn-word-boundary-segmenter-function
                  #'cn-word-boundary--char-segmenter))))

;;; 边界计算

;;; 段级缓存（纯派生数据：删掉只影响速度，不影响正确性）

;; D7 实测结论 = P（tick 传播）：建 base buffer A → 记 `buffer-chars-modified-tick'
;; → 在 A 的 indirect buffer B 中 insert → A 的 tick 同样递增（实测 A: 4 → 5，
;; B: 5）。故缓存键用「当前 buffer 的 tick」即可覆盖 base / indirect 兄弟的修改，
;; 无需对 `buffer-base-buffer' 非 nil 的 buffer 绕过缓存。
(defvar-local cn-word-boundary--run-cache nil
  "最近的汉字段范围缓存.
形如 (TICK MIN MAX START END)：TICK 是写入时的 `buffer-chars-modified-tick'，
MIN/MAX 是当时的 `point-min'/`point-max'（narrow/widen 不改变 TICK，必须单独比对），
START..END 是该汉字段的**完整**范围。由 `cn-word-boundary--han-run' 独占读写。")

(defvar-local cn-word-boundary--bounds-cache nil
  "最近的边界表缓存.
形如 (TICK MIN MAX SEGKEY START END BOUNDS BOUNDSVEC)。由
`cn-word-boundary--boundaries'（写入）与 `cn-word-boundary--bounds-vector'（读取）
共同读写；BOUNDS 是升序位置列表（含 START 与 END），BOUNDSVEC 是同一组位置的
升序向量（`(vconcat bounds)'，供 handler 二分查找，避免 O(pos) 线性扫描），
SEGKEY 见 `cn-word-boundary--cache-segmenter-key'。")

(defun cn-word-boundary--cache-fresh-p (cache)
  "CACHE 的 TICK/MIN/MAX 是否与当前 buffer 状态一致."
  (and cache
       (eql (nth 0 cache) (buffer-chars-modified-tick))
       (eql (nth 1 cache) (point-min))
       (eql (nth 2 cache) (point-max))))

(defun cn-word-boundary--cache-segmenter-key ()
  "返回代表「实际分词行为」的缓存键.
默认分词器 `cn-word-boundary--default-segmenter' 是符号，其函数体实时读
`cn-word-boundary-backend'，故 backend 改变时符号不变而行为改变——键必须同时
包含 backend 的值，否则会返回陈旧边界。"
  (if (eq cn-word-boundary-segmenter-function
          #'cn-word-boundary--default-segmenter)
      (cons 'default cn-word-boundary-backend)
    (cons 'custom cn-word-boundary-segmenter-function)))

(defun cn-word-boundary--han-char-p (char)
  "判断 CHAR 是否为汉字（category ?C）."
  (and char (aref (char-category-set char) ?C)))

;; 必须逐字符用 `char-category-set' 判断：`skip-chars-forward' 一族只认
;; 字符集（如 "[:japanese-kanji-...:]"），不支持 category 语法，无法表达 ?C。
(defun cn-word-boundary--han-end (pos limit)
  "从 POS 起向前找连续汉字的终点，不超过 LIMIT."
  (save-excursion
    (goto-char pos)
    (while (and (< (point) limit)
                (cn-word-boundary--han-char-p (char-after)))
      (forward-char 1))
    (point)))

(defun cn-word-boundary--han-start (pos limit)
  "从 POS 起向后找连续汉字的起点，不小于 LIMIT."
  (save-excursion
    (goto-char pos)
    (while (and (> (point) limit)
                (cn-word-boundary--han-char-p (char-before)))
      (backward-char 1))
    (point)))

(defun cn-word-boundary--han-run (pos limit)
  "返回 POS 所在**完整**汉字段的 (START . END)，不按 LIMIT 裁剪.
POS 小于 LIMIT 时把 POS 当词首字符，否则当词末字符（与旧实现一致，只用于决定
扫描锚点）。裁剪到 LIMIT 的职责已移到 `cn-word-boundary-find-word-boundary'。
结果按 `buffer-chars-modified-tick' + `point-min'/`point-max' 缓存。"
  (let ((cache cn-word-boundary--run-cache))
    (if (and (cn-word-boundary--cache-fresh-p cache)
             (<= (nth 3 cache) pos)
             (<= pos (nth 4 cache)))
        (cons (nth 3 cache) (nth 4 cache))
      (let* ((anchor (if (< pos limit) pos (min (point-max) (1+ pos))))
             (start (cn-word-boundary--han-start anchor (point-min)))
             (end (cn-word-boundary--han-end anchor (point-max))))
        (setq cn-word-boundary--run-cache
              (list (buffer-chars-modified-tick) (point-min) (point-max)
                    start end))
        (cons start end)))))

(defun cn-word-boundary--compute-boundaries (start end)
  "对 START..END 分词并返回升序边界位置列表（含 START 与 END）.
分词结果不合法（某项非自然数，或总长与文本长度不符）或分词器抛错时回退为逐字
边界。`natnump' 接受 0（与旧实现一致，会产生重复边界位置，不得改为 `cl-plusp'）。"
  (let* ((text (buffer-substring-no-properties start end))
         (usable
          (catch 'cn-word-boundary--bad
            (let ((lens (condition-case nil
                            (funcall cn-word-boundary-segmenter-function text)
                          (error (throw 'cn-word-boundary--bad nil)))))
              (unless (listp lens) (throw 'cn-word-boundary--bad nil))
              (let ((sum 0) (pos start) (bounds (list start)))
                (dolist (len lens)
                  (unless (natnump len) (throw 'cn-word-boundary--bad nil))
                  (setq sum (+ sum len)
                        pos (+ pos len))
                  (push pos bounds))
                (unless (= sum (length text)) (throw 'cn-word-boundary--bad nil))
                (nreverse bounds))))))
    (or usable (number-sequence start end))))

(defun cn-word-boundary--boundaries (start end)
  "返回 START..END 内的升序边界位置列表（含 START 与 END）.
结果按 TICK/MIN/MAX/分词键/区间缓存；返回值可能是缓存内的共享列表，调用方不得
破坏性修改。"
  (if (>= start end)
      (list start)
    (cn-word-boundary--ensure-ready)
    (let ((cache cn-word-boundary--bounds-cache)
          (segkey (cn-word-boundary--cache-segmenter-key)))
      (if (and (cn-word-boundary--cache-fresh-p cache)
               (equal (nth 3 cache) segkey)
               (eql (nth 4 cache) start)
               (eql (nth 5 cache) end)
               (nth 6 cache))
          (nth 6 cache)
        (let ((bounds (cn-word-boundary--compute-boundaries start end)))
          ;; SEGKEY 必须在 `--ensure-ready' 之后重新取：它可能刚把
          ;; `cn-word-boundary-segmenter-function' 改成逐字（降级）或清掉 buffer-local
          ;; 覆盖（恢复）。用调用后的值作键，降级结果才不会被 ready 状态锁死。
          (setq cn-word-boundary--bounds-cache
                (list (buffer-chars-modified-tick) (point-min) (point-max)
                      (cn-word-boundary--cache-segmenter-key) start end bounds
                      (vconcat bounds)))
          bounds)))))

;; 线性扫描是 warm 路径的瓶颈（O(pos)）：handler 命中缓存后仍要从 BOUNDS 表头
;; 逐个比较，pos 越靠后越慢。故额外缓存升序向量，改二分查找 O(log n)。
(defun cn-word-boundary--vec-first-after (vec pos)
  "在升序向量 VEC 中返回第一个大于 POS 的元素的索引；不存在时返回 nil.
二分查找，O(log (length VEC))。"
  (let ((lo 0) (hi (length vec)))
    (while (< lo hi)
      (let ((mid (/ (+ lo hi) 2)))
        (if (> (aref vec mid) pos)
            (setq hi mid)
          (setq lo (1+ mid)))))
    (and (< lo (length vec)) lo)))

(defun cn-word-boundary--bounds-vector (start end)
  "返回 START..END 的边界位置向量（升序），供二分查找使用.
与 `cn-word-boundary--boundaries' 共用 `cn-word-boundary--bounds-cache'：
命中时 O(1) 取向量，未命中时由 `--boundaries' 计算并填充缓存。"
  (if (>= start end)
      (vector start)
    (let ((cache cn-word-boundary--bounds-cache)
          (segkey (cn-word-boundary--cache-segmenter-key)))
      (if (and (cn-word-boundary--cache-fresh-p cache)
               (equal (nth 3 cache) segkey)
               (eql (nth 4 cache) start)
               (eql (nth 5 cache) end)
               (nth 7 cache))
          (nth 7 cache)
        (cn-word-boundary--boundaries start end)
        (nth 7 cn-word-boundary--bounds-cache)))))

(defun cn-word-boundary-find-word-boundary (pos limit)
  "`find-word-boundary-function-table' 使用的 handler.
POS 小于 LIMIT 时返回 POS 之后的首个边界（词尾），否则返回 POS 之前（含 POS）
的最大边界（词首），均夹到 LIMIT / `point-min' 范围内。异常时返回 POS 的
相邻位置，绝不返回 nil。"
  (save-match-data
    (save-excursion
      (condition-case nil
          (let* ((run (cn-word-boundary--han-run pos limit))
                 (vec (cn-word-boundary--bounds-vector (car run) (cdr run)))
                 (idx (cn-word-boundary--vec-first-after vec pos))
                 (found
                  (if (< pos limit)
                      (and idx (aref vec idx))
                    ;; 反向：二分定位「第一个 > pos」的索引，再取前一个（最后一个
                    ;; <= pos 的边界）；索引越界即无此边界，返回 nil。
                    (let ((i (1- (or idx (length vec)))))
                      (and (>= i 0) (aref vec i))))))
            (cond
             ((null found)
              (if (< pos limit)
                  (min (1+ pos) limit)
                (max (1- pos) (point-min))))
             ((< pos limit) (min found limit))
             ;; 完整段化后 found 可能小于 LIMIT（旧实现里段首已被 limit 裁剪，
             ;; 故天然 >= limit）；此处必须显式夹到 LIMIT 才符合公开契约。
             (t (max found limit))))
        (error (if (< pos limit)
                   (min (1+ pos) limit)
                 (max (1- pos) (point-min))))))))

;; 只把汉字 category ?C 映射到 handler：其余字符保持 nil，使英文单词与标点
;; 继续走默认的 syntax/script 边界（中英混排的英文半边因此完全不变）。
(defconst cn-word-boundary--table
  (let ((table (make-char-table nil)))
    (map-char-table
     (lambda (key value)
       (when (aref value ?C)
         (set-char-table-range table key #'cn-word-boundary-find-word-boundary)))
     (standard-category-table))
    table)
  "只把汉字 category ?C 映射到 handler 的 char-table.
其余字符保持 nil，使英文与标点走默认的 syntax/script 边界。")

;;; minor mode

;; 注意：`subword-mode' / `superword-mode' 也写 buffer-local 的
;; `find-word-boundary-function-table'；本模式与它们同时启用时，后启用者覆盖
;; 先启用者（不报错，仅边界行为按后者）。

;; 前向声明：`cn-word-boundary-mode' 由下面的 `define-minor-mode' 定义，
;; 这里先声明一次以免字节编译报 free variable。无初始值，不改变任何运行时状态。
(defvar cn-word-boundary-mode)

(defun cn-word-boundary--on-kill ()
  "当前 buffer 被 kill 时关闭本模式."
  (when cn-word-boundary-mode
    (cn-word-boundary-mode -1)))

(defun cn-word-boundary--enable ()
  "启用 buffer-local 中文词边界."
  (setq-local find-word-boundary-function-table cn-word-boundary--table)
  (when (eq cn-word-boundary--backend-state 'degraded)
    (setq-local cn-word-boundary-segmenter-function
                #'cn-word-boundary--char-segmenter))
  (when (fboundp 'cn-word-boundary-cns-register-buffer)
    (cn-word-boundary-cns-register-buffer))
  (add-hook 'kill-buffer-hook #'cn-word-boundary--on-kill nil t))

(defun cn-word-boundary--disable ()
  "关闭 buffer-local 中文词边界."
  (kill-local-variable 'find-word-boundary-function-table)
  (kill-local-variable 'cn-word-boundary-segmenter-function)
  (kill-local-variable 'cn-word-boundary--run-cache)
  (kill-local-variable 'cn-word-boundary--bounds-cache)
  (when (fboundp 'cn-word-boundary-cns-unregister-buffer)
    (cn-word-boundary-cns-unregister-buffer))
  (remove-hook 'kill-buffer-hook #'cn-word-boundary--on-kill t))

(define-minor-mode cn-word-boundary-mode
  "启用中文词边界.  不改键位，只设置 `find-word-boundary-function-table'."
  :lighter " 词"
  :group 'editing
  (if cn-word-boundary-mode
      (cn-word-boundary--enable)
    (cn-word-boundary--disable)))

(defun cn-word-boundary--turn-on-maybe ()
  "在非 `cn-word-boundary-excluded-modes' 的 buffer 中启用中文词边界."
  (unless (apply #'derived-mode-p cn-word-boundary-excluded-modes)
    (cn-word-boundary-mode 1)))

;; TURN-ON 参数必须传裸符号：Emacs 31 的宏自身会给它加 `#'，写成
;; #'cn-word-boundary--turn-on-maybe 会变成双重 #'，运行时 `invalid-function'。
(define-globalized-minor-mode global-cn-word-boundary-mode
  cn-word-boundary-mode
  cn-word-boundary--turn-on-maybe
  :group 'editing)

;;; 后端预启动与重置

(defvar cn-word-boundary--backend-timer nil
  "空闲预启动后端的 timer.  保留引用以便重复调用时取消.")

(defun cn-word-boundary-schedule-backend ()
  "空闲时预启动后端，避免阻塞 Emacs 启动.
由宿主配置显式调用；本文件顶层不调用它。"
  (when (timerp cn-word-boundary--backend-timer)
    (cancel-timer cn-word-boundary--backend-timer))
  (setq cn-word-boundary--backend-timer
        (run-with-idle-timer 2 nil #'cn-word-boundary--ensure-backend)))

(defun cn-word-boundary-reset-backend ()
  "重置后端探测状态，并对当前 buffer 重新启用本模式."
  (interactive)
  (setq cn-word-boundary--backend-state 'unknown)
  (setq cn-word-boundary--run-cache nil cn-word-boundary--bounds-cache nil)
  (when (fboundp 'cn-word-boundary-cns-reset)
    (cn-word-boundary-cns-reset))
  (when cn-word-boundary-mode
    (cn-word-boundary-mode -1)
    (cn-word-boundary-mode 1))
  (message "中文词边界：后端状态已重置（%s）"
           cn-word-boundary--backend-state))

(provide 'cn-word-boundary)
;;; cn-word-boundary.el ends here
