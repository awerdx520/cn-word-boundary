# 决策日志

记录跨越模块边界、影响长期结构的决策。日常实现选择不入此表（写进代码注释或 `AGENTS.md`）。

## 2026-10-26 — 从中抽取为独立包

**决策**

把中文词边界实现从宿主配置（`thomas-emacs` 的 `lisp/init-chinese.el`，350+ 行）抽取为独立开发仓
`cn-word-boundary`：

- **命名空间**：全部符号统一为 `cn-word-boundary-`（内部 `cn-word-boundary--`），不再使用宿主
  配置的 `+thomas/` 前缀；包内不出现任何 `+thomas/` 符号。
- **模块划分**：`cn-word-boundary.el`（char-table、边界 handler、minor mode + 全局 mode、
  后端状态与降级编排）与 `cn-word-boundary-cns.el`（cns 适配：进程启动、词表探测、分词调用、
  缓存污染修复）。依赖方向单向：cns 适配层 → 主文件，主文件顶层不 `require` `cns`。
- **配置层只留三件事**：`cns` 的 straight 安装 recipe、`cnws` / 词表路径注入（自动推导失败时）、
  以及 `(global-cn-word-boundary-mode 1)` 的显式启用。宿主模块从 350+ 行降至约 50 行接线。
- **不自启动**：包加载不产生任何全局副作用（不起 timer / 进程、不调 `global-...-mode`），
  全局启用由宿主显式调用。

**理由**

- **可复用**：词边界是通用编辑能力，与任何一台机器的配置无关；放在宿主仓里只有本机用户能用，
  抽出来才能被其它配置、隔离实例与其它人复用。
- **可独立演进与测试**：宿主仓的验证入口（`make full-check`）覆盖整个配置，一处改动失败难定位；
  独立仓可以只跑自己的 `check-parens` + ERT（含无 cns 时的降级路径），把「后端不可用」这类
  分支真正测到。
- **宿主模块瘦身**：抽取后宿主只剩安装与启用的接线，读取成本与误改风险都下降；`lisp/` 目录也回到
  「只放 `init-*.el` 模块」的分层约定。
- **cns 安装属宿主环境职责**：`cns` 是第三方包 + 需编译的 C++ 子模块（`g++` / `make` / 网络），
  安装动作是环境准备而非包的功能；包不依赖 straight 的目录布局（只在自动推导路径时**读取**
  `straight-base-dir`，且允许被 `cn-word-boundary-cns-prog` / `-dict-directory` 完全覆盖），
  因此无 straight 的宿主也能用（`char` 后端零依赖，`cns` 后端手工指定路径）。

## 2026-10-30 — 段级双缓存 + 完整段分词（性能优化）

**决策**

1. **双缓存槽**：`cn-word-boundary--run-cache`（汉字段完整范围，`--han-run` 独占读写）与
   `cn-word-boundary--bounds-cache`（区间 → 边界列表 + 升序向量，`--boundaries` / `--bounds-vector`
   读写）。两者严格隔离，互不读写对方。
2. **完整段分词 + handler 侧裁剪**：`--han-run` 不再按 `limit` 裁剪；`--boundaries` 对完整段分词；
   `cn-word-boundary-find-word-boundary` 的 `cond` 负责夹到 `limit`（反向由
   `(max found (point-min))` 改为 `(max found limit)`）。
3. **边界表向量化 + 二分**：边界表同时缓存升序向量，handler 用 `cn-word-boundary--vec-first-after`
   二分查找，不再从表头线性扫描。
4. **缓存键含「实际分词行为」**：默认分词器 `cn-word-boundary--default-segmenter` 是符号、函数体
   实时读 `cn-word-boundary-backend`，故键为 `(cons 'default backend值)` 或
   `(cons 'custom 分词函数)`，比较用 `equal`。

**理由**

- 实测（Emacs 32.0.50，`make bench`，同一脚本前后对照）：2000 字段连续移动
  **1019 μs/次 → 4.09 μs/次**；4000 字走完整段 **3993 ms → 6.86 ms**；反向:正向
  **1.4–3.9× → 1.11×**；GC 次数 **167 → 0**。根因是每次 handler 调用都付「扫全段 + 分词整段 +
  双遍历校验 + 建全表 + 从表头线性扫描」的整段代价，而 `forward-word` 每次只需一个相邻边界
  （实测移动次数 : handler 次数 = 1.00，无重复调用）→ 整段成本 × 段内移动次数 = O(n²)。
- **双槽而非单槽**：`--han-run` 与 `--boundaries` 的键语义不同（完整段范围 vs 某区间 → 表）。
  单槽会让「裁剪后入参」与「完整段」永不相等，缓存对裁剪场景永远 miss（该缺陷在计划复审中被抓出）。
- **完整段分词而非截断分词**：若缓存截断后的区间，就必须把 `limit` 纳入 key，命中率骤降；
  且截断分词本身会让同一边界随 `limit` 抖动（`"研究生命"` 完整分词首界 3、截断成 `"研究生"`
  可能首界 4），属不一致。
- **向量 + 二分**：仅做缓存时 warm 单次仍 91 μs，因 handler 从 `BOUNDS` 表头线性扫描 O(pos)
  （pos=1000 时 45.7 μs、pos=1990 时 112.97 μs）；二分后降到 4 μs 且与 pos 基本无关（1.44×）。
- **键含 backend 值**：只存分词函数符号会在用户切换 `cn-word-boundary-backend` 时返回陈旧边界
  （符号不变、行为已变）。

**弃用方案**

- **后台 timer / 线程预热**：违反 I9（加载无全局副作用），且只是把成本移出交互路径而非消除，
  还引入竞态。
- **增量分词**：`cnws` / jieba 不支持增量，前缀分词结果与整段不一致会导致边界抖动。
- **跨段 LRU**：中文文本段长通常 < 50 字，单槽已足够；多槽增加内存与失效复杂度而无实测收益。
- **key 含 `limit`**：命中率骤降（region 限制的 `forward-word` 每次 `limit` 可能不同），
  且方案 A 已消除其必要性。
- **只算到 POS 附近**：`BOUNDS` 必须是完整段才能跨 `pos` 复用；按 `pos` 裁剪会让每次移动都重算，
  复杂度回到 O(n²)。

**代价（已知并接受）**

- 冷路径 +5%（`(vconcat bounds)` 一次 O(n) 拷贝）。
- 以**非 buffer 边界**的 `limit` 调用时边界可能与旧版不同（截断分词 → 完整段分词），判定为修正；
  `forward-word` / `backward-word` / `thing-at-point` 恒传 buffer 边界，不受影响。
- `--han-char-p` 改查 char-table（原计划的 D4）实测仅提速 2–6%，**未采纳**，TD-3 维持现状。
