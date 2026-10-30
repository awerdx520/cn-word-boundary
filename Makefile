# cn-word-boundary 验证入口
#
# 全部目标使用 `emacs -Q --batch`：不依赖 emacsclient、不碰任何运行中的 daemon，
# 因此可以在任意目录、任意机器上直接跑，也不会干扰用户正在使用的 Emacs。
# 无 .el 文件时 check-parens / lint / test 均空跑成功（exit 0），
# 保证仓库初期骨架（只有元文件、尚无源码）的 `make full-check` 仍可用。

EMACS ?= emacs
EL_FILES := $(shell find . -name '*.el' -not -path './.git/*' -not -path './.local/*' -not -name '*-autoloads.el' 2>/dev/null)
TEST_FILES := $(sort $(wildcard test/*-test.el))

.PHONY: all check-parens test lint full-check bench clean

all: full-check

# L1：括号平衡检查（逐文件）
check-parens:
	@if [ -z "$(EL_FILES)" ]; then \
		echo "no elisp files"; \
	else \
		for f in $(EL_FILES); do \
			echo "check-parens: $$f"; \
			$(EMACS) -Q --batch --eval '(progn (find-file (car command-line-args-left)) (check-parens) (kill-emacs 0))' "$$f" || exit 1; \
		done; \
	fi

# L2：ERT 测试（自动发现 test/*-test.el 并全部加载；无测试文件时空跑成功）
test:
	@if [ -z "$(TEST_FILES)" ]; then \
		echo "no test files"; \
	else \
		echo "test: $(TEST_FILES)"; \
		$(EMACS) -Q --batch -L . -L test $(addprefix -l ,$(TEST_FILES)) -f ert-run-tests-batch-and-exit; \
	fi

# L1 补充：字节编译告警检查（产物输出到临时目录，不污染仓库、不产生 .elc）
# 环境变量名须与包名一致，避免与其它项目的编译目录变量互相覆盖。
lint:
	@if [ -z "$(EL_FILES)" ]; then \
		echo "no elisp files"; \
	else \
		build_dir=$$(mktemp -d); \
		for f in $(EL_FILES); do \
			echo "lint: $$f"; \
			CN_WORD_BOUNDARY_BC_DIR="$$build_dir" $(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn nil byte-compile-dest-file-function (lambda (f) (expand-file-name (file-name-nondirectory f) (getenv "CN_WORD_BOUNDARY_BC_DIR"))))' -f batch-byte-compile "$$f" || { rm -rf "$$build_dir"; exit 1; }; \
		done; \
		rm -rf "$$build_dir"; \
	fi

full-check: check-parens test

# 性能基线（不进 full-check：耗时约半分钟，且不属于正确性门禁）
# 输出即为 bench/cnwb-bench.el 顶部注释里那组数字的复现入口。
bench: ## 性能基线（不进 full-check）
	$(EMACS) -Q --batch -L . -l bench/cnwb-bench.el

clean:
	rm -rf .eln-cache eln-cache
	find . -name '*.elc' -not -path './.git/*' -delete
