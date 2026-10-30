;;; cnwb-bench.el --- cn-word-boundary 性能基线  -*- lexical-binding: t; -*-

;; Before 基线（优化前，2026-10-30）：
;; Emacs 32.0.50、`emacs -Q --batch'、`cnwb-bench--mock-2' 分词器（两字一词），
;; 全场景总耗时约 12 秒。表中均为中位数：
;;
;; | 场景                            | reps | 总耗时(ms) | 单次(μs) | GC次数 |
;; |---------------------------------|------|-----------|---------|-------|
;; | S1 正向 handler（2000 字）       |  5   |      0.54 |  540.84 |     0 |
;; | S1 反向 handler（2000 字）       |  5   |      0.70 |  698.85 |     0 |
;; | S1w 暖 handler（2000 字）        |  5   |         — |       — |     — |
;; | S2 走完整段 50 字                |  5   |      0.54 |   21.78 |     0 |
;; | S2 走完整段 200 字               |  5   |      6.64 |   66.43 |     0 |
;; | S2 走完整段 1000 字              |  3   |    300.04 |  600.07 |    11 |
;; | S2 走完整段 2000 字              |  3   |   1019.17 | 1019.17 |    44 |
;; | S2 走完整段 4000 字              |  2   |   3992.71 | 1996.35 |   167 |
;; | S3 冷缓存进入段（2000 字）       |  5   |      0.52 |  515.51 |     0 |
;; | S4a 13 字符句子                  |  5   |      0.05 |    6.43 |     0 |
;; | S4b 20 字                        |  5   |      0.11 |   10.52 |     0 |
;; | S5 降级路径 char 后端（2000 字） |  5   |      0.49 |  492.36 |     0 |
;;
;; 说明：`总耗时' 是一个样本的耗时（S1c/S1w/S3/S5 一个样本 = 1 次 handler 调用，
;; S2/S4 一个样本 = 走完整段）；`单次' 由样本耗时除以样本内的移动次数折算，
;; 即每次 `forward-word' 移动（或每次 handler 调用）的平均成本。GC 次数同为中位数。
;;
;; `S1w 暖' 是 D8（边界表向量化 + 二分查找）之后新增的场景：不清缓存、先预热一次
;; 再计时，测的是 warm 稳态单次成本。优化前 warm 与 cold 没有区别（命中缓存后仍要
;; 从 `BOUNDS' 表头线性扫描，成本 O(pos)），故 before 列填 `—'——对照值取上面的
;; S1 行（优化前的 S1 既是 cold 也是 warm）。
;;
;; 读法要点：
;; - S2 的 `单次' 随汉字段长度线性增长（n=2000 → 1019 μs，n=4000 → 1996 μs），
;;   整段遍历因此是 O(n²)：1000 字 300 ms、2000 字 1019 ms、4000 字 3993 ms
;;   （2000→4000 段耗时 3.9×）。
;; - 长段移动的成本里 GC 占比很高：2000 字段 44 次 GC、4000 字段 167 次 GC；
;;   单纯一次 handler 调用（S1 正向 541 μs）只是「每次移动」的一半左右。
;; - S3 与 S1 正向同量级，因为 T1 阶段两个缓存槽还不存在（T2 之后两者才会分叉）。
;; - S5 虽然走逐字后端，仍要建 2001 个边界并做一次 `--ensure-ready'，故仍约
;;   0.5 ms——这是降级路径的固有成本（I7/I11 回归辅助，无硬门槛）。
;; - 复跑稳定性（同机同日第二遍）：亚毫秒场景波动可达 ±60%（几十 μs 量级的绝对值，
;;   如 S2-200 字 66 → 107 μs），毫秒级场景稳定在 ±5% 内。做前后对照时优先看
;;   S2-2000 / S2-4000 的 `总耗时'。

;;; Commentary:
;;
;; `cn-word-boundary' 的性能基线入口，随 T1 固化，供后续优化任务（T2 起）做
;; 前后对照。脚本**自包含**：只依赖 `emacs -Q --batch' 与本仓库源码——不加载
;; 任何用户配置、不 require cns 适配层、不探测外部可执行文件、不起进程。
;; 因此可在任意机器上直接跑，也不会干扰用户正在使用的 Emacs。
;;
;; 用法：
;;
;;   make bench
;;   emacs -Q --batch -L . -l bench/cnwb-bench.el
;;
;; 场景（编号与 `openspec/active/performance-segment-cache.md' 的 T1 一致）：
;;
;;   S1c handler 单次调用（冷）：每样本前清缓存，2000 字正向（1 → 2001）/ 反向（2000 → 1）
;;   S1w handler 单次调用（暖）：不清缓存，先预热一次再计时（D8 起与 S1c 分叉）
;;   S2  走完整段：50 / 200 / 1000 / 2000 / 4000 字
;;   S3  冷缓存单次进入段：每样本前清缓存，再调一次正向 handler（2000 字）
;;   S4  短段对照：13 字符句子、20 字
;;   S5  降级路径：`char' 后端，直接测 `--boundaries'（2000 字）
;;
;; 方法：用 `benchmark-run' 逐样本计时，每场景重复 3–5 次取**中位数**（抵抗 GC
;; 与机器负载抖动）；每个场景开始前先 `garbage-collect'。
;;
;; 本脚本只做测量，不改任何源码：handler 的耗时是现状的直接映射。

;;; Code:

(require 'cl-lib)
(require 'cn-word-boundary)

;; `cn-word-boundary--run-cache' / `cn-word-boundary--bounds-cache' 由 T2 引入。
;; 这里只做「无初值声明」：`(defvar VAR)' 只把符号标记为 special、**不建立运行期
;; 绑定**，故下面的 `boundp' 守卫在 T1 阶段仍如实返回 nil；声明的作用只是清掉
;; 字节编译的 free-vars 警告（`make lint' 会编译本文件）。
(defvar cn-word-boundary--run-cache)
(defvar cn-word-boundary--bounds-cache)

;;; 测量框架

(defvar cnwb-bench--moves 0
  "最近一个样本内部的移动次数，由 `cnwb-bench--traverse' 写入.")

(defun cnwb-bench--median (nums)
  "返回 NUMS（数字列表）的中位数."
  (let* ((sorted (sort (copy-sequence nums) #'<))
         (count (length sorted)))
    (cond
     ((zerop count) 0.0)
     ((cl-oddp count) (float (nth (/ count 2) sorted)))
     (t (/ (+ (nth (1- (/ count 2)) sorted)
              (nth (/ count 2) sorted))
           2.0)))))

(defun cnwb-bench--pad (string width)
  "按显示宽度把 STRING 右侧补空格到 WIDTH（左对齐列）."
  (concat string (make-string (max 0 (- width (string-width string))) ?\s)))

(defun cnwb-bench--pad-left (string width)
  "按显示宽度把 STRING 左侧补空格到 WIDTH（右对齐数字列）."
  (concat (make-string (max 0 (- width (string-width string))) ?\s) string))

(defun cnwb-bench--header ()
  "输出表头."
  (princ (format "%s | %s | %s | %s\n"
                 (cnwb-bench--pad "场景" 40)
                 (cnwb-bench--pad-left "总耗时(ms)" 11)
                 (cnwb-bench--pad-left "单次(μs)" 11)
                 (cnwb-bench--pad-left "GC次数" 7))))

(defun cnwb-bench--measure (label reps thunk &optional calls prepare)
  "测量 THUNK，输出一行 `场景 | 总耗时(ms) | 单次(μs) | GC次数'，并返回该行数据.
REPS 是样本数，结果取中位数。CALLS 是每个样本内部的移动 / 调用次数，用于折算
`单次'；省略时取 THUNK 记录的 `cnwb-bench--moves'。PREPARE 在每个样本计时**之前**
调用（不计时），用于清缓存等准备动作。"
  (garbage-collect)
  (setq cnwb-bench--moves 0)
  (let (times gcs)
    (dotimes (_ reps)
      (when prepare (funcall prepare))
      (let ((result (benchmark-run 1 (funcall thunk))))
        (push (* 1000.0 (nth 0 result)) times)
        (push (nth 1 result) gcs)))
    (let* ((calls (or calls (max 1 cnwb-bench--moves)))
           (total (cnwb-bench--median times))
           (per (/ (* total 1000.0) calls))
           (gc (cnwb-bench--median gcs)))
      (princ (format "%s | %s | %s | %s\n"
                     (cnwb-bench--pad label 40)
                     (cnwb-bench--pad-left (format "%.2f" total) 11)
                     (cnwb-bench--pad-left (format "%.2f" per) 11)
                     (cnwb-bench--pad-left (format "%.0f" gc) 7)))
      (list label total per gc))))

;;; 被测对象与辅助

(defun cnwb-bench--make-buffer (text)
  "创建含 TEXT 的临时 buffer 并装上词边界表，返回该 buffer."
  (let ((buffer (generate-new-buffer " *cnwb-bench*")))
    (with-current-buffer buffer
      (insert text)
      ;; 必须显式装表：否则 `forward-word' 在汉字里按整块算一个词，只移动一次，
      ;; handler 根本不会被调用（内存里那条教训的地雷）。
      (setq-local find-word-boundary-function-table cn-word-boundary--table))
    buffer))

(defun cnwb-bench--traverse ()
  "在当前 buffer 中从 `point-min' 走完整段，返回移动次数.
移动次数同时记入 `cnwb-bench--moves'，供折算 `单次' 使用。"
  (goto-char (point-min))
  (let ((moves 0))
    (while (forward-word 1)
      (setq moves (1+ moves)))
    (setq cnwb-bench--moves moves)
    moves))

(defun cnwb-bench--traverse-case (label text reps)
  "在含 TEXT 的新 buffer 中测「走完整段」LABEL，样本数 REPS."
  (let ((buffer (cnwb-bench--make-buffer text)))
    (unwind-protect
        (with-current-buffer buffer
          (cnwb-bench--measure label reps #'cnwb-bench--traverse
                               nil #'cnwb-bench--clear-caches))
      (kill-buffer buffer))))

(defun cnwb-bench--clear-caches ()
  "清空两个缓存槽.
T1 阶段这两个变量尚未引入，`boundp' 守卫使其静默跳过、不报错。"
  (when (boundp 'cn-word-boundary--run-cache)
    (setq cn-word-boundary--run-cache nil))
  (when (boundp 'cn-word-boundary--bounds-cache)
    (setq cn-word-boundary--bounds-cache nil)))

(defun cnwb-bench--mock-2 (string)
  "两字一词的 mock 分词器.
偶数长度返回 (2 2 ...)；奇数长度回退为逐字，保证长度自洽（否则
`cn-word-boundary--boundaries' 会判定分词结果不合法而回退逐字）。"
  (if (cl-evenp (length string))
      (make-list (/ (length string) 2) 2)
    (make-list (length string) 1)))

(defun cnwb-bench--mock-1 (string)
  "逐字的 mock 分词器：每个字符一个词."
  (make-list (length string) 1))

(defmacro cnwb-bench--with-ready (segmenter &rest body)
  "在状态 `ready'、分词器 SEGMENTER 的环境中执行 BODY.
同时把 `cn-word-boundary-cns-healthy-p' 桩成恒真：batch 里没有 cns 进程，真实
健康检查会把 `ready' 重置成 `unknown'，进而把分词器换成逐字，测量失真。"
  (declare (indent 1) (debug t))
  `(let ((cn-word-boundary--backend-state 'ready)
         (cn-word-boundary-segmenter-function ,segmenter))
     (cl-letf (((symbol-function 'cn-word-boundary-cns-healthy-p)
                (lambda () t)))
       ,@body)))

;;; 场景

(defun cnwb-bench--s1 ()
  "S1c 冷 / S1w 暖：2000 字的 handler 单次调用（正向 / 反向）.
S1c 每个样本计时前清空两个缓存槽（首次进入段的成本）；S1w 不清缓存，先预热一次
（不计时）再逐样本测量，反映 D8 之后 warm 稳态的单次成本。"
  (cnwb-bench--with-ready #'cnwb-bench--mock-2
    (let ((buffer (cnwb-bench--make-buffer (make-string 2000 ?中))))
      (unwind-protect
          (with-current-buffer buffer
            (let ((s1c-forward
                   (cnwb-bench--measure
                    "S1c 冷 正向 handler（2000 字，5 reps）" 5
                    (lambda () (cn-word-boundary-find-word-boundary 1 2001))
                    1 #'cnwb-bench--clear-caches))
                  (s1c-backward
                   (cnwb-bench--measure
                    "S1c 冷 反向 handler（2000 字，5 reps）" 5
                    (lambda () (cn-word-boundary-find-word-boundary 2000 1))
                    1 #'cnwb-bench--clear-caches)))
              ;; 预热：清缓存后调一次 handler 把两个缓存槽填满，且不计时。
              (cnwb-bench--clear-caches)
              (cn-word-boundary-find-word-boundary 1 2001)
              (list s1c-forward
                    s1c-backward
                    (cnwb-bench--measure
                     "S1w 暖 正向 handler（2000 字，5 reps）" 5
                     (lambda () (cn-word-boundary-find-word-boundary 1 2001))
                     1)
                    (cnwb-bench--measure
                     "S1w 暖 反向 handler（2000 字，5 reps）" 5
                     (lambda () (cn-word-boundary-find-word-boundary 2000 1))
                     1))))
        (kill-buffer buffer)))))

(defun cnwb-bench--s2 ()
  "S2：走完整段（50 / 200 / 1000 / 2000 / 4000 字）."
  (cnwb-bench--with-ready #'cnwb-bench--mock-2
    (mapcar
     (lambda (spec)
       (let ((size (nth 0 spec))
             (reps (nth 1 spec)))
         (cnwb-bench--traverse-case
          (format "S2 走完整段 %d 字（%d reps）" size reps)
          (make-string size ?中)
          reps)))
     ;; 1000 字以上单次即秒级，reps 相应下调（输出里如实标注）。
     '((50 5) (200 5) (1000 3) (2000 3) (4000 2)))))

(defun cnwb-bench--s3 ()
  "S3：冷缓存单次进入段（2000 字）.
T1 阶段缓存尚未引入，本场景数值等同 S1 正向；T2 之后才是「首次进入段」的成本。"
  (cnwb-bench--with-ready #'cnwb-bench--mock-2
    (let ((buffer (cnwb-bench--make-buffer (make-string 2000 ?中))))
      (unwind-protect
          (with-current-buffer buffer
            (cnwb-bench--measure
             "S3 冷缓存进入段（2000 字，5 reps）" 5
             (lambda () (cn-word-boundary-find-word-boundary 1 2001))
             1 #'cnwb-bench--clear-caches))
        (kill-buffer buffer)))))

(defun cnwb-bench--s4 ()
  "S4：短段对照（13 字符句子、20 字）."
  (cnwb-bench--with-ready #'cnwb-bench--mock-2
    (list
     (cnwb-bench--traverse-case
      "S4a 13 字符句子（5 reps）" "中文分词测试，这是一句话。" 5)
     (cnwb-bench--traverse-case
      "S4b 20 字（5 reps）" (make-string 20 ?中) 5))))

(defun cnwb-bench--s5 ()
  "S5：降级路径（`char' 后端，直接测 `--boundaries'）.
定位为 I7 / I11 不变量回归辅助，本场景无硬门槛。"
  (let ((buffer (cnwb-bench--make-buffer (make-string 2000 ?中))))
    (unwind-protect
        (with-current-buffer buffer
          (cnwb-bench--measure
           "S5 降级路径 char 后端（2000 字，5 reps）" 5
           (lambda ()
             (let ((cn-word-boundary-backend 'char)
                   (cn-word-boundary--backend-state 'unknown))
               (cn-word-boundary--boundaries 1 2001)))
           1 #'cnwb-bench--clear-caches))
      (kill-buffer buffer))))

;;; 驱动

(defun cnwb-bench--summary (results)
  "输出一行汇总（各场景 单次 μs），便于人工对照."
  (princ (format "汇总：%s\n"
                 (mapconcat (lambda (row)
                              (format "%s=%.2fμs" (car row) (nth 2 row)))
                            results "  "))))

(defun cnwb-bench--run-all ()
  "跑全部场景并输出基线表."
  (princ (format "cn-word-boundary 性能基线（Emacs %s，emacs -Q --batch，mock 分词器）\n"
                 emacs-version))
  (cnwb-bench--header)
  (let ((results (append (cnwb-bench--s1)
                         (cnwb-bench--s2)
                         (list (cnwb-bench--s3))
                         (cnwb-bench--s4)
                         (list (cnwb-bench--s5)))))
    (cnwb-bench--summary results)
    results))

(provide 'cnwb-bench)

;; 只在 batch 里执行：交互式 `load' 本文件不得产生任何测量副作用。
(when noninteractive
  (cnwb-bench--run-all))

;;; cnwb-bench.el ends here
