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

(provide 'cn-word-boundary-test)
;;; cn-word-boundary-test.el ends here
