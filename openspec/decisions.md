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
