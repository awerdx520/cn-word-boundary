# 技术债

记录已知但当前不解决的技术风险与边界事实。按「影响 → 处置/计划」记录，关闭时保留原文并标注时点。

## TD-1 cns 是外部 C++ 依赖

- **描述**：默认后端 `cns` 依赖第三方包
  [kanglmf/emacs-chinese-word-segmentation](https://github.com/kanglmf/emacs-chinese-word-segmentation)，
  它把 `cppjieba` 包成常驻进程 `cnws`。首次安装需要 `g++` / `make` 且能访问 GitHub
  （`git submodule update --init --recursive` 拉 `cppjieba` 再 `make` 编译），耗时以分钟计；
  运行时还需要 `cppjieba/dict/` 下的 **5 份词表**（`jieba.dict.utf8` / `hmm_model.utf8` /
  `user.dict.utf8` / `idf.utf8` / `stop_words.utf8`）。
- **影响**：新机器上「装好包就能用」不成立 —— 未编译 `cnws` 或词表不全时，中文按逐字移动。
  这是**可见降级**（首次提示一次原因），但只要用户没注意提示，就会以为「按词移动没生效」。
- **处置**：**不解决**，作为可接受降级存在。安装动作留在宿主配置（首装不得进入
  `:config` 或任何自动 hook）；`cn-word-boundary-backend` 可显式设为 `char` 走零依赖路径；
  `M-x cn-word-boundary-reset-backend` 让修好依赖后无需重启 Emacs。

## TD-2 `cnws` 的 `WIDE_CHAR_SIZE = 3` 是硬编码

- **描述**：`cnws` 内部按「字节数 / 3」计算字符串长度，即假定每个字符都是 3 字节的宽字符；
  含 ASCII（1 字节）、emoji / 罕见 CJK 扩展区（4 字节）的字符串会算出错误的字符长度，
  返回的分段长度随之错位。
- **影响**：若把混排文本整段送进分词器，汉字边界会被算到错误位置 —— `forward-word` 可能跳过
  半个词或停在词中间，比「不启用本包」更糟。
- **处置**：**已用结构性约束规避**（不变量 I7）：先按 category `?C` 切出连续**纯汉字段**，
  只把该段送进分词器，段外的 ASCII / 标点 / emoji 全部走默认边界。代价是混排边界处
  「一个汉字段 + 一个英文词」各算一个词，不做跨语言的联合分词 —— 这本来就是期望行为。
  长度和不符时回退逐字边界，不报错。

## TD-3 汉字判据用运行期 category table，table 构造用 `standard-category-table`

- **描述**：`--han-char-p` 走 `(aref (char-category-set ch) ?C)` —— 读的是**当前运行期**的
  category table（用户/包可通过 `modify-category-entry` 改它）；而 `--table` 的构造遍历的是
  `standard-category-table`（**标准**表，不受运行期修改影响）。
- **影响**：若某人改了运行期的 `?C` 类别范围（例如把扩展区汉字加进去，或把某些符号移出），
  两处判据会漂移：table 里没有条目的字符，`--han-char-p` 判为汉字 → 走 handler 却拿不到边界
  映射，反之亦然。实际影响极小（极少数配置会改 category table，且 `?C` 的定义很稳定）。
- **处置**：**不解决**。要保持一致只能两者都读标准表（失去用户自定义能力）或都读运行期表
  （table 需在每次 category 变更后重建，复杂度不成比例）。已在 `AGENTS.md` I2 记录判据，
  改动该处代码时必须两处一起看。

## TD-4 `count-words` 不受益

- **描述**：`count-words` / `count-words-region` 内部走 `forward-word-strictly`，
  **不查** `find-word-boundary-function-table`；中文仍按「整块连续汉字」计一个词。
- **影响**：启用本包后 `M-=`（`count-words-region`）给出的是「汉字段数」而不是「词数」，
  与 `M-f` 的移动行为不一致 —— 用户可能误以为计数坏了。
- **处置**：**不解决**（这是 Emacs 的设计：`forward-word-strictly` 正是为「不受 word-boundary
  自定义影响」而存在）。已在 `Readme.org`「已知边界」与 `AGENTS.md` 显式声明。
  如需按词计数，须自行写 `(while ... (forward-word 1) ...)` 循环，本包不提供该命令
  （避免与「不改键位、不新增命令」的定位冲突）。

## TD-5 无纯 Elisp 分词后端

- **描述**：可插拔后端里只有 `cns` 是真分词；`char` 后端只是**逐字**降级（每个汉字各自成词），
  不是分词算法。
- **影响**：没有 `cnws` 的环境里，「按词移动」退化为「逐个汉字移动」—— 比默认的
  「整段汉字一个大词」好，但仍不是用户直观期待的「按词」。
- **处置**：**暂不实现**。纯 Elisp 实现可用的中文分词需要带词典 + HMM 或至少一份像样的词表
  （数万条），包体积与启动成本都远超本包现在的能力边界；`cnws` 之外还可以走自定义函数后端
  （`cn-word-boundary-backend` 接受任意 `(string) → 长度列表`），需要的人自己接。
  若日后要内置，优先评估「精简静态词典 + 最大正向匹配」的体积/效果比，并以独立可选模块
  （类似 `cn-word-boundary-cns.el`）的形式提供，不改主文件。
