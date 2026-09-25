# 開発用タスク。CI (.github/workflows/ci.yml) と同じコマンドをローカルで実行する。
#
#   make deps   テスト依存 (plenary.nvim) を .deps/ に固定コミットで取得
#   make test   headless Neovim で tests/ を実行
#   make lint   luacheck
#   make fmt    stylua で整形（CI では --check）

NVIM ?= nvim
PLENARY_DIR := .deps/plenary.nvim
# dotfiles の lazy-lock.json と同じコミットに固定する
PLENARY_REV := ec289423a1693aeae6cd0d503bac2856af74edaa

.PHONY: deps test lint fmt fmt-check clean

deps: $(PLENARY_DIR)

$(PLENARY_DIR):
	git clone --template= --filter=blob:none https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR)
	git -C $(PLENARY_DIR) checkout --detach $(PLENARY_REV)

test: deps
	$(NVIM) --headless --clean -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"

lint:
	luacheck lua/ plugin/ tests/

fmt:
	stylua lua/ plugin/ tests/

fmt-check:
	stylua --check lua/ plugin/ tests/

clean:
	rm -rf .deps
