local session_mod = require("pr-viewer.session")
local H = require("tests.pr-viewer.helpers")

describe("pr-viewer.session.parse_target", function()
  it("accepts number, #number, owner/repo#n and URL", function()
    assert.are.same({ number = 12 }, session_mod.parse_target("12"))
    assert.are.same({ number = 12 }, session_mod.parse_target("#12"))
    assert.are.same({ owner = "o", repo = "r", number = 3 }, session_mod.parse_target("o/r#3"))
    assert.are.same(
      { owner = "Kurichi", repo = "pr-viewer.nvim", number = 9 },
      session_mod.parse_target("https://github.com/Kurichi/pr-viewer.nvim/pull/9/files")
    )
  end)

  it("treats empty as the current branch and rejects garbage", function()
    assert.are.same({}, session_mod.parse_target(nil))
    assert.are.same({}, session_mod.parse_target(""))
    local t, err = session_mod.parse_target("abc")
    assert.is_nil(t)
    assert.matches("cannot parse", err)
  end)
end)

describe("pr-viewer.session.open + ui (integration)", function()
  local repo, gh, session

  before_each(function()
    require("pr-viewer.config").setup({})
    repo = H.make_repo()
    vim.cmd.cd(repo.dir)
    gh = H.fake_gh(H.pr_data(repo))
    local result
    session_mod.open({ number = 7 }, function(err, s)
      result = { err = err, s = s }
    end)
    H.wait(function()
      return result ~= nil
    end)
    assert.is_nil(result.err)
    session = result.s
  end)

  after_each(function()
    gh.restore()
    if session and session.tab then
      require("pr-viewer.ui.layout").close(session)
    end
  end)

  it("builds the session with exactly one API call", function()
    assert.are.equal(1, gh.calls)
    assert.are.equal("owner", session.owner)
    assert.are.equal("repo", session.repo)
    assert.are.equal(repo.base, session.merge_base)
    assert.is_true(session.head_local)
    -- a.lua は VIEWED なので最初に開くのは b.txt
    assert.are.equal(2, session.file_index)
    -- outdated は anchors に入らない。LEFT:1 が RIGHT:2 より先
    assert.are.equal(2, #session.anchors)
    assert.are.equal("T_left", session.anchors[1].thread.id)
    assert.are.equal("T_right", session.anchors[2].thread.id)
  end)

  it("opens a tab with files | base | head and switches files", function()
    local layout = require("pr-viewer.ui.layout")
    local actions = require("pr-viewer.ui.actions")
    local tabs_before = #vim.api.nvim_list_tabpages()
    layout.open(session)
    assert.are.equal(tabs_before + 1, #vim.api.nvim_list_tabpages())
    assert.are.equal(session, session_mod.current())

    local function base_name()
      return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(session.wins.base))
    end
    H.wait(function()
      return base_name():match("/base/b%.txt$") ~= nil
    end)
    -- b.txt は削除ファイル: 左に旧内容、右は空
    assert.are.same(
      { "old" },
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(session.wins.base), 0, -1, false)
    )
    assert.are.same(
      { "" },
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(session.wins.head), 0, -1, false)
    )
    assert.is_true(vim.wo[session.wins.base].diff)
    assert.is_true(vim.wo[session.wins.head].diff)

    -- files パネルのヘッダと現在行
    local files_lines =
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(session.wins.files), 0, -1, false)
    assert.are.equal("#7 Add b", files_lines[1])
    assert.matches("viewed 1/3 · threads 3 %(2 open%)", files_lines[3])
    assert.matches("^✓ %s+a%.lua", files_lines[5])
    assert.matches("●2", files_lines[5])
    assert.are.equal(6, vim.api.nvim_win_get_cursor(session.wins.files)[1])

    -- 次のファイル: c.lua は追加ファイルで、HEAD が head と一致するので右は実ファイル
    actions.next_file(session)
    H.wait(function()
      return base_name():match("/base/c%.lua$") ~= nil
    end)
    local head_buf = vim.api.nvim_win_get_buf(session.wins.head)
    assert.are.equal("", vim.bo[head_buf].buftype)
    assert.matches("/c%.lua$", vim.api.nvim_buf_get_name(head_buf))
    assert.are.same({ "return {}" }, vim.api.nvim_buf_get_lines(head_buf, 0, -1, false))
    assert.are.equal("lua", vim.bo[head_buf].filetype)
    -- 実ファイルにはバッファローカルキーマップが張られている
    local has_map = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(head_buf, "n")) do
      if m.lhs == "]f" then
        has_map = true
      end
    end
    assert.is_true(has_map)

    -- 前へ 2 回で a.lua: 両側にスレッドの extmark
    actions.prev_file(session)
    actions.prev_file(session)
    H.wait(function()
      return base_name():match("/base/a%.lua$") ~= nil
    end)
    local signs = require("pr-viewer.signs")
    local b = vim.api.nvim_win_get_buf(session.wins.base)
    local h = vim.api.nvim_win_get_buf(session.wins.head)
    assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(b, signs.ns, 0, -1, {}))
    assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(h, signs.ns, 0, -1, {}))
    assert.are.equal("lua", vim.bo[b].filetype)

    -- K でカーソル行のスレッドを float 表示
    vim.api.nvim_set_current_win(session.wins.head)
    vim.api.nvim_win_set_cursor(session.wins.head, { 2, 0 })
    local wins_before = #vim.api.nvim_tabpage_list_wins(session.tab)
    actions.show_thread(session)
    assert.are.equal(wins_before + 1, #vim.api.nvim_tabpage_list_wins(session.tab))
    local float_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.are.equal("### a.lua:2", float_lines[1])
    assert.matches("^%*%*@bob%*%* 2026%-09%-01", float_lines[2])
    require("pr-viewer.ui.thread").close()

    -- ]t: head:2 から次は無し、[t で LEFT:1 へ
    vim.api.nvim_set_current_win(session.wins.head)
    actions.prev_thread(session)
    assert.are.equal(session.wins.base, vim.api.nvim_get_current_win())
    assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])

    -- 閉じると後片付けされる
    layout.close(session)
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
    assert.is_nil(session.tab)
    assert.is_nil(session_mod.by_tab[session.tab or -1])
    assert.are.same({}, session.bound_bufs)
    assert.is_true(vim.api.nvim_buf_is_valid(head_buf)) -- 実ファイルは残す
    has_map = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(head_buf, "n")) do
      if m.lhs == "]f" then
        has_map = true
      end
    end
    assert.is_false(has_map)
  end)

  it("toggles viewed optimistically, advances, and flushes on close", function()
    require("pr-viewer.config").setup({ sync = { debounce_ms = 30 } })
    local layout = require("pr-viewer.ui.layout")
    local actions = require("pr-viewer.ui.actions")
    local sync = require("pr-viewer.gh.sync")
    layout.open(session)
    local function base_name()
      return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(session.wins.base))
    end
    H.wait(function()
      return base_name():match("/base/b%.txt$") ~= nil
    end)
    local files_buf = vim.api.nvim_win_get_buf(session.wins.files)

    -- diff ペインで viewed にすると即座に ✓ が付き、次の未 viewed（c.lua）へ進む
    vim.api.nvim_set_current_win(session.wins.head)
    actions.toggle_viewed(session)
    assert.are.equal("VIEWED", session.pr.files[2].viewed)
    assert.matches("^✓ D b%.txt", vim.api.nvim_buf_get_lines(files_buf, 5, 6, false)[1])
    assert.matches("viewed 2/3", vim.api.nvim_buf_get_lines(files_buf, 2, 3, false)[1])
    H.wait(function()
      return base_name():match("/base/c%.lua$") ~= nil
    end)
    assert.are.equal(1, gh.calls) -- まだ送っていない（open の 1 回だけ）

    -- files パネルでは行のファイルをトグルし、移動しない
    vim.api.nvim_set_current_win(session.wins.files)
    vim.api.nvim_win_set_cursor(session.wins.files, { 5, 0 }) -- a.lua
    actions.toggle_viewed(session)
    assert.are.equal("UNVIEWED", session.pr.files[1].viewed)
    assert.are.equal(3, session.file_index)
    assert.is_true(sync.is_dirty(session))

    -- 閉じると debounce を待たずに 1 リクエストで送る
    layout.close(session)
    assert.are.equal(2, gh.calls)
    H.wait(function()
      return not sync.is_dirty(session)
    end)
  end)

  it("opens the PR for the current branch with one query", function()
    gh.restore()
    gh = H.fake_gh(H.pr_data_by_branch(repo))
    repo.git("switch", "-q", "-c", "feat")
    local result
    session_mod.open({}, function(err, s)
      result = { err = err, s = s }
    end)
    H.wait(function()
      return result ~= nil
    end)
    assert.is_nil(result.err)
    session = result.s
    assert.are.equal(7, session.pr.number)
    assert.are.equal(1, gh.calls)
    assert.are.equal("kurichi", session.pr.viewer)
  end)

  it("reports when the branch has no open PR", function()
    gh.restore()
    gh = H.fake_gh({ viewer = { login = "k" }, repository = { pullRequests = { nodes = {} } } })
    repo.git("switch", "-q", "-c", "lonely")
    local result
    session_mod.open({}, function(err, s)
      result = { err = err, s = s }
    end)
    H.wait(function()
      return result ~= nil
    end)
    assert.matches("no open pull request for branch lonely", result.err)
  end)

  it("lists open pull requests", function()
    gh.restore()
    gh = H.fake_gh(H.list_data())
    local result
    session_mod.list(function(err, list, remote)
      result = { err = err, list = list, remote = remote }
    end)
    H.wait(function()
      return result ~= nil
    end)
    assert.is_nil(result.err)
    assert.are.equal("owner", result.remote.owner)
    assert.are.equal(2, #result.list)
    assert.are.equal(9, result.list[1].number)
    assert.is_true(result.list[2].is_draft)
    assert.is_nil(result.list[2].review_decision)
  end)

  it("falls back to git show for the head pane when HEAD differs", function()
    repo.git("checkout", "-q", repo.base)
    gh.restore()
    gh = H.fake_gh(H.pr_data(repo))
    local result
    session_mod.open({ number = 7 }, function(err, s)
      result = { err = err, s = s }
    end)
    H.wait(function()
      return result ~= nil
    end)
    session = result.s
    assert.is_false(session.head_local)
    require("pr-viewer.ui.layout").open(session)
    require("pr-viewer.ui.diff").show(session, 3)
    H.wait(function()
      return vim.api
        .nvim_buf_get_name(vim.api.nvim_win_get_buf(session.wins.head))
        :match("/head/c%.lua$") ~= nil
    end)
    local h = vim.api.nvim_win_get_buf(session.wins.head)
    assert.are.equal("nofile", vim.bo[h].buftype)
    assert.are.same({ "return {}" }, vim.api.nvim_buf_get_lines(h, 0, -1, false))
  end)
end)
