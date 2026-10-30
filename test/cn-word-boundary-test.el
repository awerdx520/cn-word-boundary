;;; cn-word-boundary-test.el --- cn-word-boundary 的 ERT  -*- lexical-binding: t; -*-

;; Author: thomas
;; Version: 0.1.0

;;; Commentary:
;;
;; 主文件 `cn-word-boundary.el' 的 ERT：结构断言 + 行为断言。
;;
;; 与宿主 `thomas-emacs/test/init-smoke-test.el' 的旧用例不同，这里**直接
;; require 真实模块**（`emacs -Q --batch -L .' 即可加载），不再从源码文本里
;; read-eval 单个表单 —— 后者是宿主冒烟测试无法 require `init-chinese' 时的
;; 权宜手段，独立包里没有必要。
;;
;; 行为断言一律把 `cn-word-boundary--backend-state' 绑成 `ready' 并指定
;; 分词器，以跳过真实后端探测：batch 中不启动任何 cns 进程。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cn-word-boundary)

;;; 测试辅助

(defmacro cnwb-test--with-ready-backend (segmenter &rest body)
  "在状态 `ready'、分词器 SEGMENTER 的环境中执行 BODY，并返回 BODY 的值.
同时把 `cn-word-boundary-cns-healthy-p' 桩成恒真。理由：本文件直接 require
真实模块，一旦 cns 适配层已被加载（`make test' 会按文件名顺序先加载
`cn-word-boundary-cns-test.el'），`cn-word-boundary--ensure-ready' 就会在
`ready' 状态下做健康检查；batch 里 `cns-process' 未绑定故判为不健康，会把状态
重置成 `unknown' 并触发真实探测，最终把 SEGMENTER 换成逐字分词器，使断言失真。
宿主的旧用例是按文本 read-eval 单个表单、未加载适配层，故没有这一干扰。"
  (declare (indent 1) (debug t))
  `(let ((cn-word-boundary--backend-state 'ready)
         (cn-word-boundary-segmenter-function ,segmenter))
     (cl-letf (((symbol-function 'cn-word-boundary-cns-healthy-p)
                (lambda () t)))
       ,@body)))

;;; 结构

(ert-deftest test-cnwb-structure ()
  "验证主文件的关键定义存在，且 char-table 只映射汉字。"
  :tags '(sanity)
  ;; a) 边界 handler 可调用
  (should (fboundp 'cn-word-boundary-find-word-boundary))
  ;; b) table 是 char-table，?中 命中可调用的 handler、?a 保持 nil（I2）
  (should (char-table-p cn-word-boundary--table))
  (let ((handler (char-table-range cn-word-boundary--table ?中)))
    (should handler)
    (should (or (functionp handler)
                (and (symbolp handler) (fboundp handler)))))
  (should-not (char-table-range cn-word-boundary--table ?a))
  ;; c) 环境事实：汉字属于 category ?C，ASCII 不属于
  (should (aref (char-category-set ?中) ?C))
  (should-not (aref (char-category-set ?a) ?C))
  ;; d) 三个配置 / 状态变量均已定义
  (should (boundp 'cn-word-boundary-backend))
  (should (boundp 'cn-word-boundary-excluded-modes))
  (should (boundp 'cn-word-boundary-segmenter-function))
  ;; e) 两个 mode 均已定义
  (should (fboundp 'cn-word-boundary-mode))
  (should (fboundp 'global-cn-word-boundary-mode)))

;;; 分词器与边界计算

(ert-deftest test-cnwb-char-segmenter ()
  "验证逐字回退分词器返回每字一个 1。"
  :tags '(sanity)
  (should (equal (cn-word-boundary--char-segmenter "中文分词")
                 '(1 1 1 1)))
  (should (equal (cn-word-boundary--char-segmenter "") nil)))

(ert-deftest test-cnwb-boundaries-from-lengths ()
  "验证长度列表被正确累加为升序边界（mock 分词器）。"
  :tags '(sanity)
  (with-temp-buffer
    (insert "中文分词测试")
    (cnwb-test--with-ready-backend (lambda (_s) '(2 2 2))
      (should (equal (cn-word-boundary--boundaries 1 7)
                     '(1 3 5 7))))))

(ert-deftest test-cnwb-boundaries-mismatch ()
  "验证分词长度和不符或抛错时回退逐字边界。"
  :tags '(sanity)
  (with-temp-buffer
    (insert "中文分词测试")
    ;; a) 长度和（5）与文本字数（6）不符 → 逐字
    (cnwb-test--with-ready-backend (lambda (_s) '(5))
      (should (equal (cn-word-boundary--boundaries 1 7)
                     '(1 2 3 4 5 6 7))))
    ;; b) 分词器抛错 → 逐字
    (cnwb-test--with-ready-backend (lambda (_s) (error "boom"))
      (should (equal (cn-word-boundary--boundaries 1 7)
                     '(1 2 3 4 5 6 7))))))

;;; 边界 handler 契约

(ert-deftest test-cnwb-word-boundary-contract ()
  "验证 handler 的正反向契约与 LIMIT 约束，且返回值恒为整数。"
  :tags '(sanity)
  ;; a) 汉字判据
  (should (cn-word-boundary--han-char-p ?中))
  (should-not (cn-word-boundary--han-char-p ?a))
  (should-not (cn-word-boundary--han-char-p nil))
  (with-temp-buffer
    (insert "中文分词测试")
    (cnwb-test--with-ready-backend (lambda (_s) '(2 2 2))
      ;; b) 正向：POS<LIMIT 返回首个 >POS 的边界
      (should (= 3 (cn-word-boundary-find-word-boundary 1 7)))
      (should (= 5 (cn-word-boundary-find-word-boundary 3 7)))
      (should (= 7 (cn-word-boundary-find-word-boundary 5 7)))
      ;; c) 反向：POS>=LIMIT 返回 <=POS 的最大边界
      (should (= 5 (cn-word-boundary-find-word-boundary 6 1)))
      ;; Emacs 的反向移动以 (point-1) 调 handler；POS 恰在边界上时契约返回该
      ;; 边界本身（max <=POS）。故直接调用 (5 1) 得 5 而非 3；要覆盖「从词首
      ;; 5 反退到上一词首 3」这一真实场景，入参须用 (4 1)。
      (should (= 3 (cn-word-boundary-find-word-boundary 4 1)))
      ;; d) LIMIT 约束：正向结果不超过 limit
      (let ((b (cn-word-boundary-find-word-boundary 1 4)))
        (should (integerp b))
        (should (<= b 4)))
      ;; e) 任意参数下返回值恒为整数（绝不返回 nil）
      (dolist (args '((1 7) (2 7) (7 1) (1 1) (4 4)))
        (should (integerp (apply #'cn-word-boundary-find-word-boundary args)))))))

;;; forward-word 集成

(ert-deftest test-cnwb-forward-word-integration ()
  "验证设置 table 后 forward-word / backward-word 按词边界移动。"
  :tags '(sanity)
  (with-temp-buffer
    (insert "中文分词测试")
    (setq-local find-word-boundary-function-table cn-word-boundary--table)
    (cnwb-test--with-ready-backend (lambda (_s) '(2 2 2))
      (goto-char (point-min))
      (should (forward-word 1))
      (should (= (point) 3))
      (should (forward-word 1))
      (should (= (point) 5))
      (should (forward-word 1))
      (should (= (point) 7))
      (should (backward-word 1))
      (should (= (point) 5))
      ;; 英文不受影响：ASCII 字符在 table 中无条目，走默认边界
      (erase-buffer)
      (insert "abc")
      (goto-char (point-min))
      (should (forward-word 1))
      (should (= (point) 4)))))

;;; 边界情形

(ert-deftest test-cnwb-edge-cases ()
  "验证空区间、POS=LIMIT 与超长汉字段等边界路径。"
  :tags '(sanity)
  ;; a) 空区间返回单元素列表
  (with-temp-buffer
    (insert "中文")
    (cnwb-test--with-ready-backend (lambda (_s) '(1))
      (should (equal (cn-word-boundary--boundaries 2 2) '(2)))))
  ;; b) POS = LIMIT 时走反向分支：结果夹到 <=POS，绝不前进到下一词界。
  ;; 实测契约：反向分支以 (1+ POS) 为锚点向前扩到汉字段起点，而段起点恒在边界
  ;; 表内，故 POS=4 时返回 POS 本身（4）；返回 3 只会在「读未绑定的
  ;; `cns-process' 抛 void-variable」这一错误兜底路径下出现（属假通过）。
  (with-temp-buffer
    (insert "中文分词测试")
    (cnwb-test--with-ready-backend (lambda (s) (make-list (length s) 1))
      (let ((b (cn-word-boundary-find-word-boundary 4 4)))
        (should (= b 4))
        (should (<= b 4)))))
  ;; c) 超长汉字段（2000 字）不触发 specpdl 溢出，边界数 = 字数 + 1
  (with-temp-buffer
    (insert (make-string 2000 ?中))
    (cnwb-test--with-ready-backend (lambda (s) (make-list (length s) 1))
      (should (= 2001
                 (length (cn-word-boundary--boundaries 1 (point-max))))))))

;;; 后端选择与降级

(ert-deftest test-cnwb-backend-char ()
  "验证 `char' 后端把当前 buffer 降级为逐字，且不依赖任何外部程序。"
  :tags '(sanity)
  (with-temp-buffer
    (insert "中文")
    (setq-local find-word-boundary-function-table cn-word-boundary--table)
    ;; 分词器在进入 `let' 之前设成 buffer-local：`let' 绑定同名变量会临时遮住
    ;; buffer-local 值，若在 `let' 内 `setq-local' 则断言读到的是 `let' 的值而非
    ;; buffer-local 值。
    (setq-local cn-word-boundary-segmenter-function
                #'cn-word-boundary--default-segmenter)
    (let ((cn-word-boundary-backend 'char)
          (cn-word-boundary--backend-state 'unknown))
      (cn-word-boundary--ensure-ready)
      ;; a) `char' 不算「意外降级」，但状态仍标为 degraded（不提示）
      (should (eq cn-word-boundary--backend-state 'degraded))
      ;; b) 当前 buffer 的分词器被就地改为逐字
      (should (eq (buffer-local-value 'cn-word-boundary-segmenter-function
                                      (current-buffer))
                  #'cn-word-boundary--char-segmenter))
      ;; c) 行为：forward-word 只前进一个字
      (goto-char (point-min))
      (should (forward-word 1))
      (should (= (point) 2)))))

(ert-deftest test-cnwb-backend-cns-unavailable ()
  "验证适配层报告不可用时状态保持 `degraded'，不被主文件覆盖回 `ready'。
这是状态覆盖缺陷（降级提示重复打印、健康检查反复重探测）的回归守卫。"
  :tags '(sanity)
  ;; 确保适配层已加载：`cl-letf' 需要捕获到真实定义才能在退出时正确还原，
  ;; 否则一次 mock 会把这个函数永久置空。
  (require 'cn-word-boundary-cns nil t)
  (with-temp-buffer
    (insert "中文")
    (let ((cn-word-boundary-backend 'cns)
          (cn-word-boundary--backend-state 'unknown))
      (cl-letf (((symbol-function 'cn-word-boundary-cns--ensure)
                 (lambda ()
                   (setq cn-word-boundary--backend-state 'degraded)
                   nil)))
        (cn-word-boundary--ensure-ready)
        ;; a) 适配层置的 degraded 不得被覆盖回 ready
        (should (eq cn-word-boundary--backend-state 'degraded))
        ;; b) 再调一次也必须保持 degraded（状态已降级时不再重探测）
        (cn-word-boundary--ensure-ready)
        (should (eq cn-word-boundary--backend-state 'degraded)))
      ;; c) 适配层符号在 mock 退出后仍是真实的可调用定义
      (should (fboundp 'cn-word-boundary-cns--ensure)))))

;;; 全局 mode 的排除列表

(ert-deftest test-cnwb-global-mode-excluded ()
  "验证排除列表里的 major mode 不启用本模式，未列入的会启用。"
  :tags '(sanity)
  ;; a) `with-temp-buffer' 是 fundamental-mode；把它列入排除列表后不应启用
  (let ((cn-word-boundary-excluded-modes '(fundamental-mode)))
    (with-temp-buffer
      (cn-word-boundary--turn-on-maybe)
      (should-not cn-word-boundary-mode)))
  ;; b) 对照组：排除列表为空时必须启用
  (let ((cn-word-boundary-excluded-modes nil))
    (with-temp-buffer
      (cn-word-boundary--turn-on-maybe)
      (should cn-word-boundary-mode))))

;;; 缓存

;; 本节覆盖 `cn-word-boundary--run-cache' / `cn-word-boundary--bounds-cache' 的
;; 命中与失效完备性（AGENTS.md I12 的守门用例）。每个用例都在 `with-temp-buffer'
;; 里独立运行：两个缓存变量是 `defvar-local'，temp buffer 天然隔离，故单跑任意
;; 一个用例都不会被其它用例的缓存污染。
;;
;; 计数一律用词法器闭包（`let' + `setq'）而非 `cl-letf' 替换真实定义：缓存命中
;; 断言关心的是「分词函数被调了几次」，闭包计数不影响被调函数的语义。

(defun cnwb-test--pair-lens (string)
  "返回「尽量按词长 2 切分」的长度列表；长度为奇数时末尾补一个 1.
让缓存断言在插入单个字符后仍保持词长 2 的边界语义，避免落到逐字回退分支。"
  (let ((n (length string)))
    (append (make-list (/ n 2) 2) (when (cl-oddp n) (list 1)))))

(ert-deftest test-cnwb-cache-hit-counts-once ()
  "同段内连续三次调用只分词一次（run-cache 与 bounds-cache 双双命中）。"
  :tags '(cache)
  (with-temp-buffer
    (insert (make-string 20 ?中))
    (let* ((calls 0)
           (seg (lambda (s) (setq calls (1+ calls)) (cnwb-test--pair-lens s))))
      (cnwb-test--with-ready-backend seg
        ;; a) 三次调用（pos 依次前移一个词）命中的是同一段的同一份边界表
        (should (= 3 (cn-word-boundary-find-word-boundary 1 (point-max))))
        (should (= 5 (cn-word-boundary-find-word-boundary 3 (point-max))))
        (should (= 7 (cn-word-boundary-find-word-boundary 5 (point-max))))
        ;; 分词器只被调用 1 次
        (should (= calls 1))
        ;; 缓存自洽：段范围覆盖整个 buffer，边界表含两端
        (should (equal (list (nth 3 cn-word-boundary--run-cache)
                             (nth 4 cn-word-boundary--run-cache))
                       '(1 21)))
        (should (equal (nth 6 cn-word-boundary--bounds-cache)
                       (cl-loop for p from 1 to 21 by 2 collect p)))))))

(ert-deftest test-cnwb-cache-invalidated-by-edit ()
  "文本修改（末尾插入字符）后缓存失效，分词器再被调用且边界正确。"
  :tags '(cache)
  (with-temp-buffer
    (insert (make-string 20 ?中))
    (let* ((calls 0)
           (seg (lambda (s) (setq calls (1+ calls)) (cnwb-test--pair-lens s))))
      (cnwb-test--with-ready-backend seg
        (should (= 3 (cn-word-boundary-find-word-boundary 1 (point-max))))
        (should (= calls 1))
        ;; b) TICK 维度失效：缓冲区字符改动使 tick 递增
        (goto-char (point-max))
        (insert "字")
        (should (= 3 (cn-word-boundary-find-word-boundary 1 (point-max))))
        (should (= calls 2))
        (should (= 22 (point-max)))
        (should (equal (list (nth 3 cn-word-boundary--run-cache)
                             (nth 4 cn-word-boundary--run-cache))
                       '(1 22)))))))

(ert-deftest test-cnwb-cache-invalidated-by-narrow ()
  "narrow / widen 后缓存失效（MIN/MAX 维度；narrow 不改 TICK）。"
  :tags '(cache)
  (with-temp-buffer
    (insert (make-string 20 ?中))
    (let* ((calls 0)
           (seg (lambda (s) (setq calls (1+ calls)) (cnwb-test--pair-lens s))))
      (cnwb-test--with-ready-backend seg
        (should (= 3 (cn-word-boundary-find-word-boundary 1 (point-max))))
        (should (= calls 1))
        ;; c) narrow：TICK 不变，只能靠 MIN/MAX 失效
        (narrow-to-region 1 5)
        (should (= 3 (cn-word-boundary-find-word-boundary 1 (point-max))))
        (should (= calls 2))
        (should (= 5 (nth 2 cn-word-boundary--bounds-cache)))
        ;; widen 后又是一个新上下文（此时缓存里是 narrow 的 MIN/MAX）
        (widen)
        (should (= 3 (cn-word-boundary-find-word-boundary 1 (point-max))))
        (should (= calls 3))
        (should (= 21 (nth 2 cn-word-boundary--bounds-cache)))))))

(ert-deftest test-cnwb-cache-invalidated-by-segmenter ()
  "切换 `cn-word-boundary-segmenter-function' 后缓存失效（SEGKEY custom 维度）。"
  :tags '(cache)
  (with-temp-buffer
    (insert "中文分词测试")
    (let* ((x-calls 0)
           (y-calls 0)
           (segx (lambda (_s) (setq x-calls (1+ x-calls)) '(2 2 2)))
           (segy (lambda (_s) (setq y-calls (1+ y-calls)) '(3 3))))
      (cnwb-test--with-ready-backend segx
        (should (= 3 (cn-word-boundary-find-word-boundary 1 7)))
        (should (= x-calls 1))
        ;; d) 换分词器：符号层面是另一个函数对象，SEGKEY 随之改变
        (setq cn-word-boundary-segmenter-function segy)
        (should (= 4 (cn-word-boundary-find-word-boundary 1 7)))
        (should (= y-calls 1))
        ;; 旧分词器不再被调用（没有重复分词）
        (should (= x-calls 1))))))

(ert-deftest test-cnwb-cache-invalidated-by-backend ()
  "分词器符号不变、只改 `cn-word-boundary-backend' 值时缓存仍失效。
这是 SEGKEY 必须包含 backend 值（而非只含函数符号）的回归守卫。"
  :tags '(cache)
  (with-temp-buffer
    (insert "中文分词测试")
    (let ((cn-word-boundary-backend 'char)
          (char-calls 0))
      ;; 分词器固定为默认分派器（符号不变），行为只由 backend 决定
      (cnwb-test--with-ready-backend #'cn-word-boundary--default-segmenter
        (cl-letf (((symbol-function 'cn-word-boundary--char-segmenter)
                   (lambda (s)
                     (setq char-calls (1+ char-calls))
                     (make-list (length s) 1))))
          ;; e) `char' 后端：逐字边界 → 首个边界是 POS+1
          (should (= 2 (cn-word-boundary-find-word-boundary 1 (point-max))))
          (should (= char-calls 1))
          (should (equal (nth 3 cn-word-boundary--bounds-cache)
                         (cons 'default 'char)))
          ;; 只把 backend 换成自定义函数，分词器符号仍是默认分派器
          (setq cn-word-boundary-backend (lambda (_s) '(3 3)))
          (should (= 4 (cn-word-boundary-find-word-boundary 1 (point-max))))
          ;; 重算但不再走 `char' 分支（新 backend 直接产出 '(3 3)）
          (should (= char-calls 1))
          (should-not (equal (nth 3 cn-word-boundary--bounds-cache)
                             (cons 'default 'char))))))))

(ert-deftest test-cnwb-cache-cleared-on-disable ()
  "关闭 mode 后两个缓存都被 `kill-local-variable' 清除。"
  :tags '(cache)
  (with-temp-buffer
    (insert (make-string 20 ?中))
    (cnwb-test--with-ready-backend (lambda (s) (cnwb-test--pair-lens s))
      (cn-word-boundary-mode 1)
      (should (= 3 (cn-word-boundary-find-word-boundary 1 (point-max))))
      ;; f) 两个缓存此刻都已写入
      (should (local-variable-p 'cn-word-boundary--run-cache))
      (should (local-variable-p 'cn-word-boundary--bounds-cache))
      (cn-word-boundary-mode -1)
      ;; disable 后不再有 buffer-local 值，读到的只能是全局默认值 nil
      (should-not (local-variable-p 'cn-word-boundary--run-cache))
      (should-not (local-variable-p 'cn-word-boundary--bounds-cache))
      (should-not cn-word-boundary--run-cache)
      (should-not cn-word-boundary--bounds-cache))))

(ert-deftest test-cnwb-cache-recomputes-across-runs ()
  "POS 落在缓存段之外（跨标点进入另一汉字段）时重算且结果正确。"
  :tags '(cache)
  (with-temp-buffer
    (insert "中文abc分词")
    (let* ((calls 0)
           (seg (lambda (s) (setq calls (1+ calls)) (cnwb-test--pair-lens s))))
      (cnwb-test--with-ready-backend seg
        ;; g) 第一个汉字段 1..3
        (should (= 3 (cn-word-boundary-find-word-boundary 1 (point-max))))
        (should (= calls 1))
        (should (equal (list (nth 3 cn-word-boundary--run-cache)
                             (nth 4 cn-word-boundary--run-cache))
                       '(1 3)))
        ;; 第二个汉字段 6..8：POS 不在缓存段内 → run-cache 重算
        (should (= 8 (cn-word-boundary-find-word-boundary 6 (point-max))))
        (should (= calls 2))
        (should (equal (list (nth 3 cn-word-boundary--run-cache)
                             (nth 4 cn-word-boundary--run-cache))
                       '(6 8)))))))

(ert-deftest test-cnwb-cache-zero-length-lens ()
  "0 长度项产生重复边界位置，且向量二分与线性语义一致（D2 守门）。"
  :tags '(cache)
  (with-temp-buffer
    (insert "中文分词测试")
    (cnwb-test--with-ready-backend (lambda (_s) '(2 0 2 2))
      ;; h) 实测值（2026-10-30 实测，勿凭推算修改）：`natnump' 接受 0，
      ;; 0 长度项不推进 pos，于是 3 被重复 push 两次，边界面为 (1 3 3 5 7)。
      (should (equal (cn-word-boundary--boundaries 1 7) '(1 3 3 5 7)))
      (should (equal (nth 7 cn-word-boundary--bounds-cache) [1 3 3 5 7]))
      ;; 向量二分在重复边界下必须与线性语义逐位置一致（正反向）
      (let ((vec (nth 7 cn-word-boundary--bounds-cache))
            (bounds (nth 6 cn-word-boundary--bounds-cache)))
        (dotimes (i 8)
          (let* ((pos (1+ i))
                 (idx (cn-word-boundary--vec-first-after vec pos))
                 (lin-fwd (cl-find-if (lambda (b) (> b pos)) bounds))
                 (vi (1- (or idx (length vec))))
                 (lin-bwd (car (last (cl-remove-if (lambda (b) (> b pos))
                                                   bounds)))))
            (should (equal (and idx (aref vec idx)) lin-fwd))
            (should (equal (and (>= vi 0) (aref vec vi)) lin-bwd)))))
      ;; handler 侧同样跳过重复边界：pos=3 的下一词界是 5 而非重复的 3
      (should (= 3 (cn-word-boundary-find-word-boundary 1 7)))
      (should (= 5 (cn-word-boundary-find-word-boundary 3 7)))
      (should (= 3 (cn-word-boundary-find-word-boundary 4 1))))))

(ert-deftest test-cnwb-cache-slot-isolation ()
  "直接调用 `--boundaries' 只写 bounds-cache，不污染 run-cache（双槽隔离）。"
  :tags '(cache)
  (with-temp-buffer
    (insert "中文分词测试")
    (cnwb-test--with-ready-backend (lambda (_s) '(2 2 2))
      (should (equal (cn-word-boundary--boundaries 1 7) '(1 3 5 7)))
      ;; i) 槽结构：8 槽；bounds-cache 有值而 run-cache 仍为 nil
      (should (= 8 (length cn-word-boundary--bounds-cache)))
      (should (equal (nth 6 cn-word-boundary--bounds-cache) '(1 3 5 7)))
      (should (local-variable-p 'cn-word-boundary--bounds-cache))
      (should-not cn-word-boundary--run-cache)
      (should-not (local-variable-p 'cn-word-boundary--run-cache)))))

(ert-deftest test-cnwb-cache-indirect-buffer ()
  "经 indirect buffer 修改文本后，base buffer 的缓存同样失效（D7 结论 P）。"
  :tags '(cache)
  (let ((base (generate-new-buffer " *cnwb-base*")))
    (unwind-protect
        (progn
          (with-current-buffer base
            (insert (make-string 20 ?中)))
          (let ((calls 0))
            (cnwb-test--with-ready-backend
                (lambda (s) (setq calls (1+ calls)) (cnwb-test--pair-lens s))
              (with-current-buffer base
                (should (= 3 (cn-word-boundary-find-word-boundary 1 (point-max))))
                (should (= calls 1)))
              (let ((ind (make-indirect-buffer base " *cnwb-ind*" t)))
                (unwind-protect
                    (progn
                      (with-current-buffer ind
                        (goto-char (point-max))
                        (insert "字"))
                      ;; j) `buffer-chars-modified-tick' 跨 base / indirect 传播
                      ;; （实测 P：base tick 6 → 7），故 base 端按 tick 判失效即可
                      (with-current-buffer base
                        (should (= 22 (point-max)))
                        (should (= 3 (cn-word-boundary-find-word-boundary 1 (point-max))))
                        (should (= calls 2))
                        (should (equal (list (nth 3 cn-word-boundary--run-cache)
                                             (nth 4 cn-word-boundary--run-cache))
                                       '(1 22)))))
                  (kill-buffer ind))))))
      (kill-buffer base))))

(ert-deftest test-cnwb-cache-indirect-tick ()
  "间接缓冲区等长替换后 base 端缓存按 tick 失效（D7 结论 P；point-max 不变）.
本用例刻意用 `subst-char-in-region' 做**等长替换**，使 `point-max' 严格不变，
从而排除「失效来自 MIN/MAX 维度」的替代解释 —— 缓存失效只可能来自
`buffer-chars-modified-tick' 跨 base / indirect 的传播（D7 结论 P）。
若某天 Emacs 行为改变使 tick 不再传播，本用例会失败，届时须改走 D7 结论 Q 的
绕过策略（显式比较 base 与 indirect 的 tick，或在间接缓冲区里关掉缓存）。"
  :tags '(cache)
  (with-temp-buffer
    ;; `make-indirect-buffer' 需要一个具名的 base buffer
    (rename-buffer "cnwb-indirect-base" t)
    (insert (make-string 20 ?中))
    (let* ((base (current-buffer))
           (calls 0)
           (seg (lambda (s) (setq calls (1+ calls)) (cnwb-test--pair-lens s)))
           tick0 point-max0)
      (cnwb-test--with-ready-backend seg
        ;; l) base 端首轮：分词一次，并记录 tick / point-max 作为对照基准
        (should (= 3 (cn-word-boundary-find-word-boundary 1 (point-max))))
        (should (= calls 1))
        (setq tick0 (buffer-chars-modified-tick))
        (setq point-max0 (point-max))
        (let ((ind (make-indirect-buffer base "cnwb-indirect-tick" t)))
          (unwind-protect
              (progn
                (with-current-buffer ind
                  ;; m) 等长替换：5..6 的「中」→「文」，长度严格不变
                  (subst-char-in-region 5 6 ?中 ?文)
                  ;; n) 间接缓冲区的 point-max 未变 → 失效不可能来自 MIN/MAX 维度
                  (should (= point-max0 (point-max))))
                (with-current-buffer base
                  ;; o) tick 已跨 base / indirect 推进（结论 P 的直接证据）
                  (should (/= tick0 (buffer-chars-modified-tick)))
                  (should (= point-max0 (point-max)))
                  ;; p) 缓存按 tick 失效 → 重新分词一次，边界表仍逐词长 2
                  (should (= 3 (cn-word-boundary-find-word-boundary 1 (point-max))))
                  (should (= calls 2))
                  (should (equal (nth 6 cn-word-boundary--bounds-cache)
                                 (cl-loop for p from 1 to 21 by 2 collect p)))))
            (when (buffer-live-p ind) (kill-buffer ind))))))))

(ert-deftest test-cnwb-cache-bounds-vector-consistent ()
  "bounds-cache 的列表槽与向量槽内容一致、长度相同（D8 结构自洽）。"
  :tags '(cache)
  (with-temp-buffer
    (insert "中文分词测试")
    (cnwb-test--with-ready-backend (lambda (_s) '(2 2 2))
      (cn-word-boundary--boundaries 1 7)
      (let* ((cache cn-word-boundary--bounds-cache)
             (bounds (nth 6 cache))
             (vec (nth 7 cache)))
        (should (equal bounds '(1 3 5 7)))
        (should (vectorp vec))
        ;; k) 两槽长度相同且逐元素相等
        (should (= (length bounds) (length vec)))
        (should (cl-loop for b in bounds for i from 0
                         always (and (< i (length vec)) (= b (aref vec i)))))
        ;; 键与当前上下文一致（缓存是本次调用的产物）
        (should (equal (nth 3 cache) (cn-word-boundary--cache-segmenter-key)))
        (should (eql (nth 4 cache) 1))
        (should (eql (nth 5 cache) 7))))))

(provide 'cn-word-boundary-test)
;;; cn-word-boundary-test.el ends here
