# 性能优化：段级缓存与局部化边界计算

## 当前状态

- 阶段：Phase 4（Review & Document）· 已完成
- 已确认：方案 ✅（用户 2026-10-30 确认）、计划 ✅（2026-10-30 用户确认）
- 修订记录：
  - **v1 → v2**（2026-10-30）：按首轮独立审查补齐缓存 key 完备性（`backend` 值 / `limit` / indirect buffer）、澄清 SEGKEY 归属、修正 L3 数值口径、补等价性与文档同步项。
  - **v2 → v3**（2026-10-30）：按复审意见改为**双缓存槽**（`run-cache` / `bounds-cache`）消除「裁剪返回 vs 命中条件」冲突；D6 改为**方案 A**（完整段分词 + handler 侧裁剪）并补反向 cond 的 `limit` 补偿；新增**行为变化声明**；补 `.PHONY bench`、S3 门槛口径、缓存结构自洽用例。
  - **v3 → v4**（2026-10-30）：按第三次复审的一般级建议微调——S3 硬门槛与放宽条款合并表述、D6 补「放大仅首次」与「不做只算 pos 附近」的理由、D5 修正字节编译措辞、TD-6 必须记录 run-cache 的判据依赖缺口、注意事项补「禁止 setq-default」。
  - **v4 → v5**（2026-10-30）：追加 **D8 向量 + 二分查找**（warm 路径瓶颈是 `BOUNDS` 表头线性扫描 O(pos)，实测 2000 字段 pos=1000 时 45.7 μs）；bench 的 S1 拆为 S1c（冷）/ S1w（暖）；L3 的「连续移动」指标改由 S1w 与 S2 共同验证。
- 结果：L3 五项门槛全部达成（S1w 4.09 μs/次、S2-4000 6.86 ms、S3 517 μs、反向:正向 1.11×、
  S4a −46%）；`make full-check` 23/23 绿
- 下一步：无（已归档）

## ⚠ 行为变化声明（需用户确认）

方案 A（D6）会让 `--han-run` 从「按 `limit` 截断」改为「返回完整汉字段」。由此产生**一处可观测的行为变化**：

- **受影响场景**：以**非 buffer 边界**的 `limit` 调用 handler（例如 `(cn-word-boundary-find-word-boundary 1 4)`，或宿主用 region 限制 `forward-word`）。
- **变化**：旧实现只对 `[start, limit)` 分词，分词结果受截断影响（可能把词切错，导致边界随 `limit` 抖动）；新实现对完整段分词后再裁剪到 `limit`。当截断改变分词结果时（例：`"研究生命"` 完整分词 `(2 2)` → 首界 3；截断到 `"研究生"` 可能分词 `(3)` → 首界 4），新实现返回的边界可能与旧实现不同。
- **判定**：这是**修正**而非劣化——同一位置在不同 `limit` 下给出不同边界本身是不一致；新实现消除该抖动。
- **日常不受影响**：`forward-word` / `backward-word` / `thing-at-point` / evil 的 `w`/`b`/`e` 恒传 `point-max`/`point-min` 作 `limit`，不存在截断，行为完全不变。
- **代价**：小 `limit` 场景下分词范围从 `[start, limit)` 扩到整段。该放大**只发生在首次进入段**——完整段 `BOUNDS` 入缓存后，同段后续调用（含小 `limit`）命中 O(1)；场景本身极罕见，接受。
- **处理**：Phase 3 完成后在 `CHANGELOG.md` 的 `Changed` 中如实记录；若用户不接受，改走备选方案（见 D6「备选」）。

## 目标

把「中文词边界 handler」的复杂度从 **O(n²)（n = 汉字段长度）** 降到**段内连续移动 O(1) / 首次进入段 O(n)**，使长汉字段（≥500 字）不再出现可感知的移动延迟；除上面已声明的 `limit` 截断行为变化外，**不改变任何其它对外行为**，不变量 I1–I11 全守。

### 实测基线（Emacs 32.0.50，`emacs -Q --batch`，mock 分词器，改动前）

| 场景 | 现状 |
|---|---|
| 2000 字段 handler 正向 | 897 μs/次 |
| 2000 字段 handler 反向 | 1277 μs/次 |
| 5120 字段 handler 反向（真实 cns） | 3490 μs/次 |
| 2000 字走完整段 | 2060 ms |
| 4000 字走完整段 | 8022 ms |
| 规模曲线 1000→2000→4000 | 3.81× / 4.00×（O(n²)） |
| 13 字符句子 / 20 字段 | 12.5 μs / 22 μs 每次移动（无需优化） |

### 拆项归因（基准 = 897 μs）

| 项 | 占比 |
|---|---|
| `cn-word-boundary--han-run` 全段双向逐字符扫描（`cn-word-boundary.el:147-173`） | 48.3% |
| `cn-word-boundary--boundaries` 整段分词 + 全份双遍历校验 + 建全表（`:175-196`） | 47.2% |
| └ `cl-every` + `cl-loop sum` 双遍历校验 | ≈30% |
| `buffer-substring-no-properties` | 1.2% |
| `cl-find-if`（真正需要的那一步） | 0.44% |
| `--ensure-ready`（state=ready） | 0.01% |

关键事实：`forward-word` 每次只调用 handler **1 次**（实测移动数 : handler 数 = 1.00），无重复调用；问题在**单次调用成本**。GC 占实测时间 30–40%。

## 设计

### D1 双缓存槽（承担 ~90% 收益）

**不用单槽**：`--han-run` 与 `--boundaries` 的缓存键语义不同（前者是「完整段范围」，后者是「某个区间 → 边界表」），共用一个槽会让命中条件互相错配（复审 blocking #1 的根因），也会在「测试直接调 `--boundaries`」时污染段范围。因此**两个独立 buffer-local 变量，各自独占读写**：

| 变量 | 结构 | 独占读写方 |
|---|---|---|
| `cn-word-boundary--run-cache` | `(TICK MIN MAX START END)` | `cn-word-boundary--han-run` |
| `cn-word-boundary--bounds-cache` | `(TICK MIN MAX SEGKEY START END BOUNDS)` | `cn-word-boundary--boundaries` |

**槽语义**：

| 槽 | 含义 |
|---|---|
| `TICK` | 写入时的 `(buffer-chars-modified-tick)` |
| `MIN` / `MAX` | 写入时的 `(point-min)` / `(point-max)`（narrow/widen 不改变 TICK，必须单独比对） |
| `START` / `END` | run-cache：**完整**汉字段范围；bounds-cache：`--boundaries` 的**入参**区间 |
| `SEGKEY` | 「实际分词行为」的键（见下），仅 bounds-cache 有 |
| `BOUNDS` | 该区间的边界位置列表（升序，含 start 与 end） |

**命中条件**：

- `--han-run`：`TICK` / `MIN` / `MAX` 全等 **且** `START ≤ pos ≤ END`。不比较任何分词相关键（段范围只由文本与 `point-min`/`point-max` 决定）。
- `--boundaries`：`TICK` / `MIN` / `MAX` 全等 **且** `SEGKEY` 与当前 `equal` **且** `BOUNDS` 非 `nil` **且** 入参 `start`/`end` 与缓存 `START`/`END` 相等。

**SEGKEY 必须同时覆盖分词函数符号与 `cn-word-boundary-backend` 的值**：默认分词器 `cn-word-boundary--default-segmenter` 是**符号**，其函数体实时读 `cn-word-boundary-backend`，用户 `(setq cn-word-boundary-backend #'my-seg)` 或 cns↔char 切换时符号不变但行为变了，只用符号会返回陈旧边界。取键：

```elisp
(if (eq cn-word-boundary-segmenter-function #'cn-word-boundary--default-segmenter)
    (cons 'default cn-word-boundary-backend)
  (cons 'custom cn-word-boundary-segmenter-function))
```
比较用 `equal`。

**写入时序（防 I11 精神被破坏）**：`--boundaries` 内部先调 `--ensure-ready`（可能降级改写 `cn-word-boundary-segmenter-function`），**在其之后**再写 `SEGKEY` + `BOUNDS`，使 `SEGKEY` 恒等于「实际产出 `BOUNDS` 的那个分词行为」；读侧比较的是进入 `--boundaries` 后的当前值，不一致即重算，因此降级结果不会被 `ready` 状态锁死。

**失效与清理**：不显式失效，靠 key 比较自然失效；`cn-word-boundary--disable` 中 `kill-local-variable` 两个变量；`cn-word-boundary-reset-backend` 中把两者都置 `nil`。**不引入 timer / 线程**（I9 不变）。

### D2 单循环「校验 + 建表」（承担 ~30% 首次成本）

把现有三段遍历（`cl-every` → `cl-loop sum` → `dolist` 建表）合并为**一次** `dolist`：边累加、边 push 边界；遇非 `natnump` 或最终 `sum ≠ (length text)` 时回退 `(number-sequence start end)`。

语义必须与现状**完全等价**：`nil` lens → 回退；**`0` 长度项被接受**（`natnump` 含 0，原始实现亦接受，结果是产生**重复边界位置**、`dolist` 有限遍历不会死循环）；分词器抛错 → 回退。**不得**「顺手修正」为 `cl-plusp`。

### D3 反向路径去 `cl-remove-if` + `last`

改为单遍扫描取「最后一个 `≤ pos` 的边界」，不复制列表、不用 `pop`/`nreverse`/`setcdr`。无任何 `≤ pos` 的边界时返回 `nil`（与现状 `(car (last nil))` 等价）。

### D4 `--han-char-p` 判据（实测后决定）

候选：`(and char (aref cn-word-boundary--table char))` 替代 `(aref (char-category-set char) ?C)`。
（`cn-word-boundary--table` 的汉字条目值是 handler **符号**，非 nil，作布尔判据正确。）

- 收益不确定（`char-category-set` 每次返回 128 元素向量）。
- 会改变行为：不再尊重用户运行时 `modify-category-entry` 对 `?C` 的修改；但**顺带消除 TD-3 的判据漂移**（当前是「运行期 category table vs `standard-category-table`」两套判据）。
- **决策规则**：D1/D2 落地后单独 benchmark `--han-run` 冷路径，若提速 **≥10%** 则采纳（并把 TD-3 标为「已关闭」），否则不动（TD-3 维持现状），并在计划中记录两组数字。

### D5 性能回归入口

新增 `bench/cnwb-bench.el` + Makefile `bench` 目标（`emacs -Q --batch -L . -l bench/cnwb-bench.el`），固化本次基线。`bench` **不**并入 `full-check`。

脚本要求：
- **自包含**：不 `require` cns、不依赖用户配置；
- **可被 `make lint` 字节编译**（Makefile 的 `EL_FILES` 会递归扫到 `bench/*.el`）；
- 顶层用 `(when noninteractive ...)` 守卫，避免交互式 `load` 时执行；字节编译本身不 eval 顶层普通 form（`batch-byte-compile` 只编译不加载），故 benchmark 不会在 `make lint` 时跑。**禁止**把耗时计算放进 `defvar` / `defconst` 的初始化器（编译期会求值）；
- 内置**重复测量取中位数**（每场景 ≥5 次）以抵抗 GC 与机器负载抖动。

### D6 方案 A：完整段分词 + handler 侧裁剪（替代「缓存裁剪后区间」）

**问题**：若 `--han-run` 命中缓存后按 `limit` 裁剪返回，`--boundaries` 收到的 `end` 是裁剪值，与缓存里的完整段 `END` 永不相等 → `BOUNDS` 缓存对所有「需要裁剪」的调用**永远 miss**（复审 blocking）。而把 `limit` 加进 key 会大幅降低命中率且不必要。

**方案 A**：

1. `--han-run` **返回完整段**（扫描上界用 `point-max`/`point-min`，不用 `limit`），**不做任何裁剪**。docstring 同步更新（「返回 POS 所在完整汉字段，裁剪由调用方负责」）。
2. `--boundaries` 恒接收完整段，对完整段分词并缓存 `BOUNDS`（key 一致，缓存可命中）。
3. 裁剪统一移到 `cn-word-boundary-find-word-boundary` 的 `cond`：
   - 正向（`pos < limit`）：`(min found limit)` —— **保持不变**。
   - 反向（`pos ≥ limit`）：`(max found (point-min))` → **改为 `(max found limit)`**。理由：旧实现里 `--han-run` 反向的 `START` 已被 `limit` 裁剪（`≥ limit`），故 `found ≥ limit` 天然成立、用 `point-min` 等价；完整段化后 `found` 可能 `< limit`，必须显式夹到 `limit` 才符合「反向结果不小于 LIMIT」的公开契约。
   - `(null found)` 兜底分支：**保持原样**（`(min (1+ pos) limit)` / `(max (1- pos) (point-min))`），以维持行为等价。
4. **前提说明**：handler 由 `find-word-boundary-function-table` 只在汉字（category `?C`）上调用，故 `pos` 恒落在汉字上；完整段的正/反向计算因此一致（`pos` 为非汉字时两者会差 1，该路径不触发）。
5. **不做「只算到 POS 附近」的理由**：`BOUNDS` 必须是完整段的表才能跨 `pos` 复用缓存；若按 `pos` 裁剪（只算到 `pos` 之后第一个边界），每次 `pos` 前进都要重算，命中率归零，复杂度回到 O(n²)。「首次 O(n) + 后续 O(1)」才是本方案的目标形态。

**备选（仅当用户拒绝行为变化时）**：保留 `--han-run` 的 `limit` 截断语义 → 必须把 `limit` 纳入 bounds-cache 的 key（命中率下降，且测试里不同 `limit` 调用会频繁重算）；性能收益打折但不为零。

### D7 indirect buffer 的失效策略（先探测、后落地）

间接缓冲区与 base buffer **共享文本**，而 `buffer-chars-modified-tick` 是否跨两者传播需实测确认。

T2 中先做一次 10 行探测：建 buffer A → 记 tick → 建 indirect B → 在 B 中 insert → 读 A 的 `(buffer-chars-modified-tick)`。按结论二选一（**必须二选一并在代码注释记录实测结论**）：

- **结论 P（tick 传播）**：key 用当前 buffer 的 tick 即可，仅补一条 ERT 覆盖「经 indirect 修改后 base 缓存失效」。
- **结论 Q（tick 不传播）**：对 `(buffer-base-buffer)` 非 nil 的 buffer **绕过缓存**（直接计算，牺牲该场景性能），并在 `openspec/tech-debt.md` 记录「base buffer 经 indirect 兄弟修改」的残余风险。

两种结论下都不得让缓存返回陈旧边界。

### D8 边界表向量化 + 二分查找（warm 路径）

D1/D2/D3/D6 落地后，warm 路径仍有 O(pos) 项：handler 命中缓存后要用 `cl-find-if`（正向）或
`cl-loop`（反向）从 `BOUNDS` 表头线性扫描，实测 2000 字段 pos=10 → 4.9 μs、pos=1000 → 45.7 μs
（单次 91 μs），达不到 L3 的 ≤20 μs。

做法：
1. `--bounds-cache` 增加第 8 槽 `BOUNDSVEC`，由 `--boundaries` 在写 `BOUNDS` 时一并
   `(vconcat bounds)` 生成（冷路径多一次 O(n) 拷贝，约占冷路径 5%）。
2. 新增 `cn-word-boundary--vec-first-after`（升序向量二分，O(log n)）与
   `cn-word-boundary--bounds-vector`（命中缓存取向量，未命中委托 `--boundaries` 填充）。
3. handler 改用 `--bounds-vector` + 二分：正向取「第一个 > pos 的元素」，反向取「最后一个
   ≤ pos 的元素」（索引 = `(1- (or idx (length vec)))`，越界返回 nil）。`cond` 与两个兜底
   分支不变。

对外行为零变化（`--boundaries` 仍返回列表，测试契约不变）；`--bounds-vector` 与
`--boundaries` 同侧读写 `--bounds-cache`，不触碰 `--run-cache`（I12 判据同步放宽为「`--bounds-cache`
只被 `--boundaries` 与 `--bounds-vector` 读写」）。

## 任务

- [x] **T1 固化性能基线入口**（依赖：无）
  新增 `bench/cnwb-bench.el`（batch 可跑、自包含、可字节编译、顶层 `(when noninteractive ...)`）与 Makefile `bench` 目标（**同时把 `bench` 加入 `.PHONY`**；`bench` 不并入 `full-check`）。
  场景：S1 handler 单次（2000 字正向/反向，冷缓存，测试前 `(setq cn-word-boundary--run-cache nil cn-word-boundary--bounds-cache nil)`）、S2 整段遍历（50/200/1000/2000/4000 字）、S3 冷缓存首次进入段（**使用词长 2 mock**，单次 handler 实测值，供 L3 对照）、S4 短段对照（13 字符句子、20 字段）、S5 降级路径（`char` 后端，定位为 I7/I11 不变量回归辅助，无硬门槛）。
  mock 分词器须长度自洽：偶数长度用 `(lambda (s) (make-list (/ (length s) 2) 2))`；另用 `(lambda (s) (make-list (length s) 1))` 覆盖逐字分支；奇数长度场景回退逐字并在脚本内处理。
  每场景 ≥5 次重复，输出中位数与 GC 次数。
  验收：`make bench` 退出码 0；输出含各场景中位数；改动前跑一次，把 before 数字写入 `bench/cnwb-bench.el` 顶部注释；`make check-parens` 与 `make lint` 均通过；`make -n bench` 可用（`.PHONY` 已含 bench）。

- [x] **T2 环境探测 + 双缓存基础设施**（依赖：T1）
  a. 执行 D7 的 indirect buffer 探测，记录实测结论（P 或 Q）；
  b. 新增 `cn-word-boundary--run-cache` 与 `cn-word-boundary--bounds-cache`（均 `defvar-local`）+ 各自的命中判定与写入函数（严格按 D1 的槽语义与独占读写方）；
  c. `cn-word-boundary--disable` 中 `kill-local-variable` 两个变量；`cn-word-boundary-reset-backend` 中两者都置 `nil`。
  验收：`make check-parens` 通过；两个变量与辅助函数有中文 docstring；D7 结论写进代码注释；两缓存的读写方互不交叉（代码里 grep 可验：`--han-run` 不出现 `--bounds-cache`，`--boundaries` 不出现 `--run-cache`）。

- [x] **T3 接入 `--han-run` / `--boundaries` + handler 裁剪**（依赖：T2）
  按 D1 + D6 方案 A：`--han-run` 返回完整段并读写 run-cache；`--boundaries` 读写 bounds-cache；handler 的反向 `cond` 改为 `(max found limit)`。
  验收：`make test` 现有 12 用例全绿（尤其 `test-cnwb-word-boundary-contract` 的 b/c/d 项与 `test-cnwb-edge-cases` 的 b 项）。

- [x] **T4 单循环校验 + 建表**（依赖：T3）
  按 D2 重写 `cn-word-boundary--boundaries` 的校验/建表部分，语义等价（含 0 长度项与 nil lens）。
  验收：`make test` 全绿。

- [x] **T5 反向路径清理**（依赖：T4）
  按 D3 替换 `cl-remove-if` + `last`。
  验收：`make test` 全绿；`test-cnwb-word-boundary-contract` 的反向断言不变。

- [x] **T4b 向量 + 二分（D8）**（依赖：T5）
  `--bounds-cache` 扩为 8 槽；新增 `--vec-first-after` / `--bounds-vector`；handler 改用向量二分。
  验收：`make test` 全绿；bench 的 S1w 单次 ≤ 20 μs（2000 字段，pos 取首/中/尾各测一次）。

- [x] **T6 D4 判据实测决策**（依赖：T4）
  对 `--han-run` 冷路径分别测两种 `--han-char-p` 实现（各 ≥5 次取中位数）。
  验收（机械可判）：输出两组中位数与**提速百分比**，并明确写出落点——提速 ≥10% → 采纳并把 `openspec/tech-debt.md` 的 TD-3 标为「已关闭」；<10% → 不采纳、TD-3 维持现状，两组数字写入计划。

- [x] **T7 缓存正确性 ERT**（依赖：T5）
  在 `test/cn-word-boundary-test.el` 新增用例，**必须复用 `cnwb-test--with-ready-backend` 宏**（AGENTS.md 已记录 `make test` 按文件名顺序先加载 cns 适配层、健康检查会把 `ready` 串味的问题；不复用会让计数断言失真）：
  a. 同段两次调用只分词 1 次（`cl-letf` 计数 segmenter 调用次数）；
  b. 修改 buffer（插入字符）后缓存失效（segmenter 再被调用，且边界正确）；
  c. `narrow-to-region` / `widen` 后缓存失效（覆盖 `MIN`/`MAX` 维度）；
  d. 切换 `cn-word-boundary-segmenter-function` 后缓存失效（覆盖 `SEGKEY` custom 维度）；
  e. **切换 `cn-word-boundary-backend` 值而 segmenter 符号不变**后缓存失效（覆盖 `SEGKEY` default 维度，首轮 blocking #1 的回归守卫）；
  f. `cn-word-boundary-mode -1` 后两个缓存都被清除（无 buffer-local 值）；
  g. pos 落在缓存段之外（跨标点进入另一段）时重新计算且结果正确；
  h. **0 长度项等价性**：`(lambda (_s) '(2 0 2 2))` 在 6 字 buffer 上的结果与「含重复边界位置」的现状语义一致（D2 守门，防误改 `cl-plusp`）；
  i. **直接调用 `--boundaries`（不经 handler）后 `--bounds-cache` 自洽，且 `--run-cache` 未被污染**（D1 双槽隔离的回归守卫）；
  j. 若 D7 结论为 P：经 indirect buffer 修改后 base buffer 缓存失效。
  验收：`make test` 全绿，新增 9–10 个用例（现有 12 + 新增 = 21 或 22）。

- [x] **T8 性能验收（L3）**（依赖：T7）
  `make bench` 对比门槛（见「验证标准」L3）。未达标 → 回 T3/T4 继续优化（修复循环上限 2 轮）。
  验收：全部门槛达成，输出 before/after 对照表（中位数）。

- [x] **T9a 文档沉淀：不变量与仓库地图**（依赖：T8）
  - `AGENTS.md`：
    - 新增不变量 **I12 缓存失效完备性**，判据 = 「T7.a–j 全绿」+「命中条件覆盖 `TICK`/`MIN`/`MAX`/`SEGKEY`/`START`/`END` 各维度」+「`--han-run` 与 `--boundaries` 各自独占一个缓存变量，互不读写对方」；
    - 「不变量清单」节标题由 I1–I11 改为 I1–I12；
    - **目录结构表**新增 `bench/cnwb-bench.el` 行；
    - **已知边界（摘要）表**新增一行（长段首次进入成本 / 按文本修改失效）；
    - 「常用命令」补 `make bench`；
    - 「编码约定」补缓存失效要求（两缓存独立、SEGKEY 含 backend 值、裁剪在 handler 侧）。
  验收：`grep -c 'I12' AGENTS.md` ≥ 1；目录表含 `bench/`；命令表含 `make bench`。

- [x] **T9b 文档沉淀：决策与变更记录**（依赖：T9a）
  - `openspec/decisions.md`：新增决策「段级双缓存 + 完整段分词」（含**弃用方案**：单槽缓存、key 含 `limit`、后台 timer 预热、增量分词、跨段 LRU）；
  - `openspec/tech-debt.md`：TD-3 按 T6 结论更新或关闭；新增 TD-6「段级缓存一致性风险与失效边界」，**必须包含**：① D7 的 indirect buffer 结论与残余风险；② **run-cache 的段范围依赖 `--han-char-p` 判据**——若 T6 未采纳 D4（维持运行期 category table 判据）且用户在运行时 `modify-category-entry` 改动 `?C`，段范围会变而 `buffer-chars-modified-tick` 不变，导致 run-cache 返回陈旧段范围（概率极低：TD-3 已声明 `?C` 稳定；`M-x cn-word-boundary-reset-backend` 可清缓存；T6 采纳 D4 即消除该缺口）；
  - `CHANGELOG.md`：`Changed` 下新增性能条目（中文），**并如实记录 D6 的 `limit` 截断行为变化**；
  - `Readme.org`：「已知边界」补性能说明（长段首次进入成本、缓存按文本修改失效、`limit` 截断行为变化）。
  验收：四份文件各有对应变更；`make full-check` 全绿。

- [x] **T10 归档**（依赖：T9b）
  计划勾选完成 → 移入 `openspec/completed/performance-segment-cache.md`。
  验收：`openspec/active/` 为空；`git status` 显示预期变更。

## 依赖关系

T1 → T2 → T3 → T4 → T5 → T7 → T8 → T9a → T9b → T10；T6 依赖 T4，与 T5/T7 无冲突可穿插。

## 文档清单

| 文档 | 需要的更新 | 触发条件 |
|---|---|---|
| `AGENTS.md` | 新增 I12 + 目录结构表（`bench/`）+ 已知边界摘要表 + `make bench` + 编码约定 | 必然 |
| `openspec/decisions.md` | 双缓存 + 完整段分词决策 + 弃用方案 | 必然 |
| `openspec/tech-debt.md` | TD-3 状态更新/关闭；新增 TD-6 缓存一致性（含 D7 结论） | 必然 |
| `CHANGELOG.md` | `Changed` 性能条目 + `limit` 截断行为变化 | 必然 |
| `Readme.org` | 性能与缓存语义 + `limit` 行为说明 | 必然（用户可感知） |
| `Makefile` | 新增 `bench` 目标 + `.PHONY` | 必然 |
| `bench/cnwb-bench.el` | 新增（含 before 基线注释） | 必然 |
| `openspec/active/performance-segment-cache.md` | 归档到 `completed/` | 必然 |

## 验证标准

**L1（每步）**：`make check-parens`；改动文件跑 `make lint`（产物落临时目录）。

**L2（每步）**：`make test` 全绿（现有 12 用例 + T7 新增 9–10 用例）。

**L3（T8 性能门槛，硬指标；bench 取中位数）**：

| 指标 | 现状 | 目标 | 对应 bench 场景 |
|---|---|---|---|
| 2000 字段内连续移动 | ~1000 μs/次 | **≤ 20 μs/次** | S1w / S2 |
| 2000 字冷缓存首次进入（单次 handler，词长 2 mock） | ~1000 μs（实测基线） | **≤ 600 μs**（T6 未采纳 D4 时放宽至 ≤800 μs，绝对上限） | S3 |
| 4000 字走完整段（2000 次移动累计） | 8022 ms | **≤ 60 ms**（即平均 ≤30 μs/次） | S2 |
| 反向 : 正向成本比 | 1.4–3.9× | **≤ 1.3×** | S1 |
| 13 字符句子（短段对照） | 12.5 μs/次 | 劣化不超过 20% | S4 |

> 口径说明：
> 1. 连续移动门槛（≤20 μs/次）比整段累计门槛（≤30 μs/次平均）更严，因为整段遍历含首次冷缓存成本与跨段切换成本。两者不矛盾，但**不得**用整段累计数字倒推单次门槛。
> 2. S3 固定使用**词长 2 mock**（`(make-list (/ len 2) 2)`）以保证门槛可复现。硬门槛为 ≤600 μs；仅当 T6 未采纳 D4 时允许放宽到 **≤800 μs**（绝对上限），且须在计划中记录实测值与放宽理由。

**不变量回归**：I1–I11 全守（重点 I2 只映射汉字、I6 后端状态单一归属、I7 只送纯汉字段、I9 加载无全局副作用、I11 降级状态不被覆盖）。

## 注意事项

1. **缓存是纯派生数据**：任何时刻删掉缓存都必须只影响速度、不影响正确性。缓存不得参与状态机（`cn-word-boundary--backend-state` 仍归 I6 管）。
2. **两个缓存变量必须严格隔离**：`--han-run` 只读写 `--run-cache`，`--boundaries` 只读写 `--bounds-cache`。共用单槽会导致「裁剪后入参 vs 完整段」的键错配（本轮 blocking 的根因），也会让测试直接调用 `--boundaries` 时污染段范围。写入缓存必须用 `setq` / `setq-local`，**禁止** `setq-default`（会污染全局默认值）。
3. **key 必须含 `point-min`/`point-max`**：`narrow-to-region` 不改变 `buffer-chars-modified-tick`，只用 tick 作 key 会在 narrow/widen 后返回越界边界。
4. **`SEGKEY` 必须同时含分词函数与 `cn-word-boundary-backend` 值**（默认分词器是符号、函数体实时读 backend）；**且只能在 `--boundaries` 调完 `--ensure-ready` 之后写入**。写/读顺序错会让降级结果被锁死（破坏 I11 精神）。
5. **裁剪只在 handler 侧**（D6 方案 A）：`--han-run` 返回完整段，不得把 `limit` 截断后的结果写进 run-cache，也不得把 `limit` 加进 key（会显著降低命中率且无必要）。
6. **反向 `cond` 必须夹 `limit`**：`(max found (point-min))` → `(max found limit)`；`(null found)` 兜底分支保持原样。这是完整段化的必要补偿，漏改会导致反向越界（返回小于 `limit` 的位置）。
7. **不要破坏性修改缓存里的 `BOUNDS` 列表**（`nreverse` / `pop` / `setcdr` 都会）；反向扫描须用非破坏性遍历。
8. `natnump` 允许 0，原始实现接受含 0 的 lens（产生重复边界位置、不死循环）。重写校验时必须保持等价，并由 T7.h 守门。
9. 性能测试一律 `emacs -Q --batch`；**不要**在用户运行中的主实例上跑 bench（config 任务禁长耗时，I5）。
10. 每次性能测量须报告 GC 次数；优化后若 GC 占比仍 >20%，说明仍有大量分配，需继续查。
11. 不得新增任何 `run-with-idle-timer` / 后台线程（I9）。
12. `bench/cnwb-bench.el` 会被 `make check-parens` / `make lint` 自动扫到（`Makefile` 的 `EL_FILES` 递归匹配 `*.el`），因此脚本必须自包含、可字节编译、不 `require` cns、顶层用 `noninteractive` 守卫。
13. handler 只在汉字上被调用（char-table 只映射 category `?C`），D6 的「正反向完整段一致」依赖这个前提；若将来放宽映射范围，需重新审视 run-cache 的段计算。
