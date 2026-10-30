# cn-word-boundary 仓库地图

## 项目概述

`cn-word-boundary` 是一个 Emacs **中文词边界 minor mode**：只设置 buffer-local 的
`find-word-boundary-function-table`，把标准语法表中的汉字（category `?C`）映射到自定义
边界计算函数，于是 `forward-word` 及其全部派生行为（evil 的 `w` / `b` / `e` / `ge`、
`M-f` / `M-b` / `M-d` / `M-DEL`、`kill-word`、`mark-word`、`transpose-words`、
`thing-at-point`、isearch 的 `C-w` …）在中文内部按**词**而不是按**字**移动。

分词后端可插拔：默认走 `cns`（`cppjieba` 的 `cnws` 常驻进程，真分词），后端不可用时自动
降级为**逐字**边界；也可以显式配置成逐字，或接入自定义分词函数。

**设计取向**：只改变「词的边界在哪」，不接管任何键位、不改变 `self-insert`、
不引入新的编辑状态。英文与中英混排因 table 中对应字符为 `nil`、回落默认的
syntax / script 边界，行为完全不变。

命名由来：包要解决的是「**中文**语境下的**词边界**」，故直接 `cn-word-boundary-` 前缀。

当前状态：**源码与 ERT 已就位**。`cn-word-boundary.el`（主逻辑）与
`cn-word-boundary-cns.el`（cns 适配）均已实现，`test/` 下有 24 个 ERT 用例
（`make test` 全绿）；`make full-check` = `check-parens` + `test`。

## 目录结构

| 路径 | 用途 | 状态 |
|---|---|---|
| `cn-word-boundary.el` | 主文件：自定义组、char-table、边界 handler、minor mode + 全局 mode、后端状态与降级 | 已实现 |
| `cn-word-boundary-cns.el` | `cns` 后端适配：进程启动、词表探测、分词调用、缓存污染修复 | 已实现 |
| `test/cn-word-boundary-test.el` | 主文件 ERT（结构 / 边界计算 / handler 契约 / `forward-word` 集成 / 边界情形 / 后端降级 / 全局 mode 排除 / 段级缓存） | 已实现（22 用例，含 12 个 `test-cnwb-cache-*`） |
| `test/cn-word-boundary-cns-test.el` | cns 适配层 ERT（分词 nil 重试、缺 `cnws` 时降级） | 已实现（2 用例） |
| `bench/cnwb-bench.el` | 性能基线（`make bench`）：S1c/S1w handler、S2 走完整段（50–4000 字）、S3 冷缓存、S4 短段、S5 降级路径；顶部注释固化 before 基线 | 已建 |
| `openspec/` | 决策日志（`decisions.md`）与技术债（`tech-debt.md`） | 已建 |
| `Makefile` | 验证入口：`check-parens` / `test` / `lint` / `full-check` / `clean` | 已建 |
| `Readme.org` | 用户文档：安装、用法、后端说明、已知边界 | 已建 |
| `CHANGELOG.md` | 变更日志（Keep a Changelog 格式） | 已建 |
| `.dir-locals.el` | 目录局部变量：`no-byte-compile`（含 `test/`），禁止生成 `.elc` | 已建 |
| `.gitignore` | 忽略 `*.elc` / `*.eln` / `.local/` / `*-autoloads.el` | 已建 |

## 编码约定

**文件头/尾**（不变量，机械可检）：

```elisp
;;; cn-word-boundary.el --- 描述  -*- lexical-binding: t; -*-

;; 正文

;;; cn-word-boundary.el ends here
```

- 必须含 `lexical-binding: t`；文件末行必须是 `;;; cn-word-boundary(-cns).el ends here`。
- **符号前缀**：对外接口 `cn-word-boundary-<name>`，内部实现 `cn-word-boundary--<name>`
  （双连字符）。禁止无前缀的公共符号，也禁止沿用宿主配置的 `+thomas/` 前缀。
- **注释与文档用中文**；符号名与文件名用英文。
- **不生成 `.elc`**：`.dir-locals.el` 已对仓库根与 `test/` 设 `no-byte-compile`。
  `make lint` 的编译产物输出到 `mktemp -d` 临时目录，跑完即删。
- **段级缓存两条铁律**：① 缓存是纯派生数据，删掉只能变慢、不能变错；②
  `cn-word-boundary--run-cache` 与 `cn-word-boundary--bounds-cache` 严格隔离，后者键必须含
  「实际分词行为」（默认分词器符号 + `cn-word-boundary-backend` 值）。详见不变量 I12。
- 送进分词器的文本、后端进程的异常路径必须由 `condition-case` 兜住——**任何失败都不得向
  宿主抛错**，只能降级为逐字边界。
- **cns 侧的全局符号只在编译期声明**：`cn-word-boundary-cns.el` 顶层用
  `(eval-when-compile (defvar cns-prog) (defvar cns-recent-segmentation) …)` 声明 cns 包的
  变量。`(defvar SYMBOL)`（无初值）只把符号标记为 special、**不建立运行期绑定**，因此
  `(boundp 'cns-process)` 一类守卫在运行期仍如实反映 cns 是否已加载；`free-vars` 信号则被
  清零（`byte-compile-warnings` 里只允许抑制 `unresolved` / `noruntime`，**不得**抑制
  `free-vars`）。`cn-word-boundary.el` 主文件不需要这组声明（它对 cns 只经 `fboundp` 守卫）。

## 不变量清单

以下 I1–I12 为**现行**不变量，违反即失败。每条给出**判据**（可机械检查或可逐字复核）。

- **I1 命名空间唯一** —— 全部公共符号以 `cn-word-boundary-` 开头、内部符号以
  `cn-word-boundary--` 开头；**源码（`*.el` / `test/*.el`）内不得出现** `+thomas/` 前缀
  （文档中描述该禁令本身的文字不算）。
  *判据*：`grep -rn '+thomas/' *.el test/*.el` 无输出；`grep -rn 'def[a-z]* +thomas/'` 无输出。

- **I2 只映射汉字** —— char-table 只把 `standard-category-table` 中 category `?C` 的字符范围
  映射到边界 handler，**其余字符一律保持 `nil`**。
  *判据*：构造 table 后遍历 `(map-char-table ...)`，凡 `(aref (char-category-set ch) ?C)` 为 nil
  的字符，`(aref table ch)` 必须为 `nil`；反之为 handler 符号。英文与标点走默认边界即由此保证。

- **I3 不改键位、不启用 `cns-mode`** —— 包内**不得**出现任何键绑定（`define-key` / `keymap-set` /
  `general-define-key` / `local-set-key` / `global-set-key` 等），**不得**调用 `(cns-mode 1)`。
  *理由*：`cns-mode` 是另一条实现路径，其键位表会**覆盖 7 个键位**（`M-f` / `M-b` / `M-d` /
  `M-DEL` / `C-<left>` / `C-<right>` / `C-<backspace>` 一类基于 `forward-word` 的默认键），
  与本包「零键位侵入」的定位冲突；两者同时启用还会争抢 `find-word-boundary-function-table`。
  *判据*：`grep -rn 'cns-mode' --include='*.el' .` 只允许出现在注释与 `fboundp` 守卫中；
  键绑定类符号零命中。

- **I4 主文件不依赖 cns 的加载** —— `cn-word-boundary.el` **禁止**顶层 `(require 'cns)`；
  cns 相关符号（`cns-process` / `cns-buffer-list-add-buffer` / `cns-segmentation-handler` …）
  只能出现在 `(fboundp ...)` / `(boundp ...)` 守卫之内，或由 `cn-word-boundary-cns.el` 提供。
  *理由*：`cns` 是第三方包、且仅在后端可用时才需要；顶层 require 会让「未安装 cns」的用户连
  逐字降级都用不上（加载即失败），也会把第三方包的加载拖进启动路径。
  *判据*：`cn-word-boundary.el` 首屏 `grep "^(require 'cns)"` 无输出；所有 cns 符号出现处的
  同一 `sexp` 内必须有 `fboundp` / `boundp` 守卫。

- **I5 cns 适配层单向依赖** —— `cn-word-boundary-cns.el` **必须**顶层
  `(require 'cn-word-boundary)`（依赖方向 cns → 主文件，绝不反向）；同样**禁止**顶层
  `(require 'cns)`——`cns` 只在 `cn-word-boundary-cns.el` 的函数体内按需 `(require 'cns nil t)`。
  *判据*：`cn-word-boundary-cns.el` 顶部含 `(require 'cn-word-boundary)`、且不含
  `(require 'cns)` 的顶层形态（函数体内的 `require` 不计）。

- **I6 后端状态单一归属** —— `cn-word-boundary--backend-state` **定义在主文件**（初值
  `unknown`，流转 `unknown` → `ready` / `degraded`）；`cn-word-boundary-cns.el` 只允许
  `setq` 更新它，**不得**重新 `defvar` / `defconst`。
  *理由*：主文件在无 cns 时必须能独立判断「已降级」，状态定义若下沉到 cns 层，主文件读它会
  `void-variable`，降级路径整段失效。
  *判据*：`grep -rn 'defvar cn-word-boundary--backend-state\|defconst cn-word-boundary--backend-state'`
  在主文件命中 1 次、在 cns 文件 0 次。

- **I7 只送纯汉字段给分词器** —— 传给分词函数的字符串**只能含汉字**（由连续的
  `(char-category-set ch) ?C` 判定切出汉字段后再送）。*理由*：`cnws` 的 `WIDE_CHAR_SIZE`
  硬编码为 **3**，内部按「字节数 / 3」算长度，含 ASCII 或 emoji 的字符串会算出错误的
  分段长度，边界位置随之错位。*判据*：分词调用点的入参必须是 `--han-run` 一类函数返回的
  汉字段子串；对含 ASCII 的输入，`forward-word` 行为与未启用本模式时逐字相等。

- **I8 全局 mode 的 TURN-ON 参数传裸符号** —— `define-globalized-minor-mode` 的第三个参数
  必须是裸符号（如 `cn-word-boundary--turn-on-maybe`），**不得**写 `#'` 前缀。
  *理由*：该宏在展开时对 TURN-ON 参数做符号比较 / `symbolp` 判定（用于 `after-change-major-mode-hook`
  的注册与 `--global-mode` 的启用循环），`#'` 形式（`(function SYM)`）在部分 Emacs 版本上会让
  判定落空，表现为「全局 mode 显示已启用、但新 buffer 不会被打开」。
  *判据*：`grep -n "define-globalized-minor-mode" -A4` 中第三参数行不含 `#'`。

- **I9 包不自启动全局 mode** —— 加载 `cn-word-boundary` **不得**产生任何全局副作用：
  不得在顶层调用 `(global-cn-word-boundary-mode 1)`、不得起 timer / 进程、不得改任何全局变量。
  全局启用由**宿主配置**显式调用。*理由*：库的加载时机由宿主的包管理器决定；自带自启动会让
  「只想试一下」或「在隔离实例里加载测试」的场景无法回退。
  *判据*：`emacs -Q --batch -L . -l cn-word-boundary` 之后
  `(bound-and-true-p global-cn-word-boundary-mode)` 为 `nil`，且 `timer-list` 无新增项、
  `(process-list)` 无新增进程。注：Emacs 32 起 `timer-list` 是**变量**而非函数，照抄成函数
  调用形式会 `void-function`（应为 `nil`），按变量比较定时器数量即可。

- **I10 验证入口唯一、不产生编译产物** —— 提交前必须 `make full-check`（= `check-parens` +
  `test`）全绿；仓库内**不得**出现 `.elc` / `.eln`（`.dir-locals.el` 的 `no-byte-compile` 已设，
  `make lint` 的产物落临时目录）。
  *判据*：`make full-check` exit 0；`find . -name '*.elc' -not -path './.git/*'` 无输出。

- **I11 降级状态不得被覆盖** —— 主文件调用适配层（`cn-word-boundary-cns--ensure`）后，
  只有在**确认成功**（返回非 nil）时才把 `cn-word-boundary--backend-state` 置 `ready`；
  适配层写入的 `degraded` 必须原样保留。
  *理由*：无条件置 `ready` 会把适配层的降级结论冲掉，表现为降级提示每轮重复打印、
  `--ensure-ready` 的健康检查每轮都重新探测后端（进程反复重启）。
  *判据*：ERT `test-cnwb-backend-cns-unavailable`（mock 适配层返回 nil 后状态必须仍是
  `degraded`，再次调用也不得变成 `ready`）；命令行复核
  `emacs -Q --batch -L . -l cn-word-boundary --eval` 打印
  `state-after-fail=degraded`。

- **I12 缓存失效完备性** —— 段级缓存是**纯派生数据**：任何时刻删掉它只能影响速度，不得影响正确性。
  两个缓存变量**严格隔离**：`cn-word-boundary--run-cache`（汉字段完整范围，仅
  `cn-word-boundary--han-run` 读写）与 `cn-word-boundary--bounds-cache`（区间 → 边界列表 + 升序向量，
  仅 `cn-word-boundary--boundaries` 与 `cn-word-boundary--bounds-vector` 读写）。
  `--bounds-cache` 的键必须同时覆盖 `buffer-chars-modified-tick`、`point-min`、`point-max`、
  **实际分词行为**（默认分词器符号 + `cn-word-boundary-backend` 的值）、区间首尾。
  `cn-word-boundary-mode` 关闭时必须 `kill-local-variable` 两个变量；
  `cn-word-boundary-reset-backend` 必须把两者置 `nil`。
  *判据*：`make test` 中 `test-cnwb-cache-*` 全部通过（命中计数、编辑失效、narrow 失效、
  分词函数切换失效、backend 值切换失效、mode 关闭清理、跨段重算、0 长度项等价、双槽隔离、
  indirect buffer、list/vector 一致）；且 `grep -n 'cn-word-boundary--run-cache' cn-word-boundary.el`
  不出现在 `--boundaries` / `--bounds-vector` / `--compute-boundaries` 函数体内，
  `grep -n 'cn-word-boundary--bounds-cache' cn-word-boundary.el` 不出现在 `--han-run` 函数体内。

## 常用命令

```sh
make check-parens   # L1：逐文件括号平衡（无 .el 时空跑成功）
make test           # L2：自动发现并加载全部 test/*-test.el（无测试文件时空跑成功）
make lint           # L1 补充：字节编译告警（产物落临时目录，不污染仓库）
make full-check     # check-parens + test（提交前的唯一门禁）
make bench          # 性能基线（不进 full-check；约 12 秒）
make clean          # 清理 .elc / .eln / eln-cache
```

全部目标走 `emacs -Q --batch`：不依赖 emacsclient，也不会碰到运行中的 daemon。

**测试文件命名**：必须是 `test/*-test.el` —— `make test` 用
`$(sort $(wildcard test/*-test.el))` 自动发现并按序加载，禁止在 Makefile 里硬编码文件名
（否则拆分测试后会静默漏跑）。无匹配时输出 `no test files` 并成功退出。

**测试直接 require 真实模块**：`test/*-test.el` 用 `(require 'cn-word-boundary)` /
`(require 'cn-word-boundary-cns)` 加载真实定义，**不再**从源码文本里 read-eval 单个表单
（后者是宿主 `thomas-emacs/test/init-smoke-test.el` 无法 require `init-chinese` 时的权宜手段）。
由此带来一条测试侧约定：把 `cn-word-boundary--backend-state` 绑成 `ready` 的行为断言必须同时
桩掉 `cn-word-boundary-cns-healthy-p` —— `make test` 按文件名顺序先加载 cns 适配层，健康检查
会被调用（batch 里 `cns-process` 未绑定 → 判为不健康），进而把状态重置成 `unknown` 并触发真实
探测，把 mock 分词器换成逐字分词器。`test/cn-word-boundary-test.el` 的
`cnwb-test--with-ready-backend` 宏已封装「绑 state + 绑分词器 + 桩健康检查」三件事。

## 已知边界（摘要，详见 `Readme.org` 与 `openspec/tech-debt.md`）

| 边界 | 事实 |
|---|---|
| `count-words` 不受影响 | `count-words` / `count-words-region` 走 `forward-word-strictly`，**不走** `find-word-boundary-function-table`，中文仍按整块计数。要按词计数须自行用 `forward-word` 循环 |
| `cnws` 只接受纯汉字 | `WIDE_CHAR_SIZE = 3` 硬编码，含 ASCII / emoji 的字符串长度会算错（I7 / TD-2） |
| 终端类 mode 默认排除 | `cn-word-boundary-excluded-modes` 默认 `vterm-mode` / `term-mode` / `eshell-mode` / `shell-mode` —— 这些 buffer 里 `forward-word` 多为 shell 语义，分词边界反而碍事 |
| 与 `subword-mode` 互斥覆盖 | 两者都写 buffer-local 的 `find-word-boundary-function-table`，**后启用者覆盖先启用者**（不报错，仅边界按后者） |
| cns 是外部 C++ 依赖 | 首次安装需 `g++` / `make` / 网络；不可用时降级逐字并只提示一次（TD-1） |
| 无纯 Elisp 真分词 | `char` 后端只是逐字降级，不是分词（TD-5） |
| 长汉字段首次进入有一次性成本 | 段级缓存冷启动需扫段 + 分词 + 建表（2000 字约 0.5 ms），之后同段移动 O(1)（约 4–5 μs/次）；任何文本修改都会使缓存失效 |
| 非 buffer 边界的 `limit` 行为变化 | handler 改为「完整段分词后裁剪到 `limit`」，以 region 限制 `forward-word` 时边界可能与旧版不同（更稳定、不随 `limit` 抖动）；`forward-word` / `backward-word` 恒传 buffer 边界，不受影响 |

## 文档治理

| 产物类型 | 位置 |
|---|---|
| 决策日志 | `openspec/decisions.md`（按日期分节，含**决策**与**理由**） |
| 技术债 | `openspec/tech-debt.md`（逐条编号 TD-N） |
| 用户文档 | `Readme.org` |
| 变更日志 | `CHANGELOG.md`（Keep a Changelog 格式，中文条目） |
| 仓库地图（本文件） | `AGENTS.md` |

文档与代码同步：改公共接口（defcustom / interactive 命令 / 后端协议）必须同时更新
`Readme.org` 的「用法」与「后端说明」；改不变量必须同步本文件的判据与 `make test` 的守门用例。
