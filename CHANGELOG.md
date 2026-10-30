# 变更日志

本项目的所有重要变更都记录在此文件中。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### Added

- **ERT 测试 12 例**：`test/cn-word-boundary-test.el`（10 例：结构、逐字分词器、长度→边界累加、
  长度不符/抛错回退、handler 正反向契约与 LIMIT、`forward-word` / `backward-word` 集成、空区间与
  2000 字长段、`char` 后端降级、cns 不可用时的状态流转、全局 mode 的排除列表）与
  `test/cn-word-boundary-cns-test.el`（2 例：分词返回 `nil` 时的重试与缓存清理、缺 `cnws` /
  词表时降级）。测试直接 `require` 真实模块，不启动任何真实 cns 进程（一律 mock 或走提前失败路径）。
- `bench/cnwb-bench.el` 与 `make bench`：性能基线入口（不进 `full-check`）。
- ERT 缓存正确性用例 11 个（`test-cnwb-cache-*`，覆盖命中计数、编辑/narrow/分词函数/backend
  失效、mode 关闭清理、跨段重算、0 长度项等价、双槽隔离、indirect buffer、列表与向量一致）。

### Changed

- 中文词边界 handler 的复杂度从 O(n²) 降到段内连续移动 O(1)：新增两个 buffer-local 段级缓存
  （汉字段完整范围 / 边界表 + 升序向量）。2000 字字段的连续移动由约 1 ms/次降到约 4 μs/次。
- 边界查找改用升序向量二分（`cn-word-boundary--vec-first-after`），不再从边界表头线性扫描；
  成本不再随光标位置线性增长。
- 分词结果的合法性校验与边界表构造合并为单次遍历。
- `cn-word-boundary--han-run` 改为返回**完整**汉字段，裁剪到 `limit` 的职责移到 handler。
  **行为变化**：以非 buffer 边界的 `limit` 调用时（如 region 限制的 `forward-word`），边界可能
  与旧版不同——旧版对截断区间分词、结果随 `limit` 抖动，新版对完整段分词后裁剪，更稳定。
  `forward-word` / `backward-word` 恒传 buffer 边界，不受影响。
- 反向查找不再复制边界表（去掉 `cl-remove-if` + `last`）。

### Removed

- `cn-word-boundary.el` 不再 `require 'cl-lib`（已无 `cl-*` 调用）。

### Fixed

- **降级状态被覆盖回 `ready`**：`cn-word-boundary--ensure-backend` 的 `cns` 分支原先在调用适配层
  `cn-word-boundary-cns--ensure` 之后**无条件**把 `cn-word-boundary--backend-state` 置为 `ready`，
  会冲掉适配层写入的 `degraded`，导致降级提示重复打印、健康检查反复重探测后端。改为**仅在适配层
  确认成功（返回非 nil）时**才置 `ready`。回归守卫：ERT `test-cnwb-backend-cns-unavailable`。

## [0.1.0] - 2026-10-26

首个版本：从 `thomas-emacs` 的 `lisp/init-chinese.el` 抽取为独立包。

### Added

- **中文词边界 minor mode**：`cn-word-boundary-mode`（buffer-local）与
  `global-cn-word-boundary-mode`（全局）只设置 `find-word-boundary-function-table`，
  且只把 `standard-category-table` 的汉字（category `?C`）映射到边界 handler；其余字符
  保持 `nil`。于是 `forward-word` 及其全部派生行为（evil 的 `w`/`b`/`e`/`ge`、
  `M-f`/`M-b`/`M-d`/`M-DEL`、`kill-word`、`mark-word`、`transpose-words`、
  `thing-at-point`、isearch `C-w` …）在中文内部按词移动，英文与中英混排行为不变。
- **可插拔分词后端**：`cn-word-boundary-backend` 支持 `cns`（默认，真分词）、
  `char`（逐字）与任意自定义函数（接收纯汉字字符串，返回各词长度列表）。
- **cns 后端适配（`cn-word-boundary-cns.el`）**：按需启动 `cppjieba` 的 `cnws` 常驻进程、
  探测 5 份词表是否齐全、注入经 `shell-quote-argument` 转义的启动命令、规避首次请求返回
  `nil` 并污染内部缓存的已知问题、进程死亡后重置状态并重启、最后一个 buffer 关闭时停进程。
- **逐字降级**：二进制 / 词表缺失、`cns` 加载失败、进程启动失败、分词异常 —— 任一情形都
  **自动降级为逐字边界**并只提示一次，功能可用、启动不中断；后端状态记录于
  `cn-word-boundary--backend-state`（`unknown` → `ready` / `degraded`）。
- **全局 mode 与排除列表**：`cn-word-boundary-excluded-modes` 默认排除
  `vterm-mode` / `term-mode` / `eshell-mode` / `shell-mode`。
- **`M-x cn-word-boundary-reset-backend`**：把后端状态清回未探测并对当前 buffer 重新开关模式，
  装好 `cns` 或修好 `cnws` / 词表后无需重启 Emacs。

### 设计约束（同步建立）

- **不改任何键位**、**不启用 `cns-mode`**（后者会覆盖 7 个基于 `forward-word` 的默认键位）。
- 主文件 `cn-word-boundary.el` 禁止顶层 `(require 'cns)`，cns 符号只在 `fboundp` / `boundp`
  守卫内出现；`cn-word-boundary-cns.el` 顶层 `(require 'cn-word-boundary)`、同样禁止顶层
  `(require 'cns)` —— 依赖方向单向（cns 适配层 → 主文件）。
- 包不自启动全局 mode：`(global-cn-word-boundary-mode 1)` 由宿主配置显式调用。
- 送进分词器的文本只含纯汉字段（`cnws` 的 `WIDE_CHAR_SIZE = 3` 硬编码所致）。
