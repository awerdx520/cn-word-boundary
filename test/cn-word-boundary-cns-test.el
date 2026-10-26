;;; cn-word-boundary-cns-test.el --- cn-word-boundary cns 适配层的 ERT  -*- lexical-binding: t; -*-

;; Author: thomas
;; Version: 0.1.0

;;; Commentary:
;;
;; `cn-word-boundary-cns.el' 的 ERT。加载本文件**不会**启动任何真实 cns 进程：
;; `cn-word-boundary-cns.el' 只在 `cn-word-boundary-cns--ensure' 里按需
;; `(require 'cns)'，本文件的所有用例都走「提前失败」或 mock 路径。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cn-word-boundary-cns)

;; `cn-word-boundary-cns-segmenter' 会读写这个 cns 全局变量；batch 中 cns 未
;; 加载，显式 defvar 以提供 special 绑定（`let' 才能动态绑定它）。
(defvar cns-recent-segmentation nil)

;;; 分词与重试

(ert-deftest test-cnwb-cns-segmenter-retry ()
  "验证 segmenter 对 nil 结果重试一次，并清除被污染的缓存条目。"
  :tags '(sanity)
  ;; a) 首次返回 nil（后端刚启动的已知行为）→ 清缓存条目并重试
  (let ((calls 0)
        (cns-recent-segmentation '(("中文分词" nil))))
    (cl-letf (((symbol-function 'cns-segmentation-handler)
               (lambda (_s)
                 (setq calls (1+ calls))
                 (if (= calls 1) nil '(2 2)))))
      (should (equal (cn-word-boundary-cns-segmenter "中文分词") '(2 2)))
      (should (= calls 2))
      ;; 被污染的 nil 条目应已从缓存移除
      (should-not (assoc "中文分词" cns-recent-segmentation))))
  ;; b) 首次即成功时只调用一次
  (let ((calls 0)
        (cns-recent-segmentation nil))
    (cl-letf (((symbol-function 'cns-segmentation-handler)
               (lambda (_s) (setq calls (1+ calls)) '(3))))
      (should (equal (cn-word-boundary-cns-segmenter "中文分词") '(3)))
      (should (= calls 1)))))

;;; 可用性探测与降级

(ert-deftest test-cnwb-cns-ensure-degrades-without-prog ()
  "验证缺失 cnws / 词表时 `--ensure' 降级返回 nil 且不向宿主抛错。"
  :tags '(sanity)
  (let ((cn-word-boundary-cns-prog nil)
        (cn-word-boundary-cns-dict-directory nil)
        (cn-word-boundary--backend-state 'unknown))
    ;; 提前失败：prog 为 nil 时在读文件系统之前就抛错，绝不 require cns、
    ;; 也绝不启动进程。
    (should-not (cn-word-boundary-cns--ensure))
    (should (eq cn-word-boundary--backend-state 'degraded))))

(provide 'cn-word-boundary-cns-test)
;;; cn-word-boundary-cns-test.el ends here
