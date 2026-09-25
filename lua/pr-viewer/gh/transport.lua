-- GitHub API への通信層。
--
-- v1 は `gh api` を子プロセスとして vim.system で非同期に呼ぶ（docs/DESIGN.md D2）。
-- 認証・GHES・プロキシは gh に任せる。将来 curl/libuv バックエンドに差し替えられるよう、
-- 公開 API は graphql()/rest() の 2 つだけに絞り、呼び出し側は gh の存在を知らない。
local M = {}

---@alias PrViewer.Callback fun(err: string?, data: any)

--- テストで差し替えるためのフック。本番では vim.system。
---@type fun(cmd: string[], opts: table, on_exit: fun(out: vim.SystemCompleted))
M._system = function(cmd, opts, on_exit)
  vim.system(cmd, opts, on_exit)
end

---@param out vim.SystemCompleted
---@return string? err
---@return table? json
local function parse_output(out)
  if out.code ~= 0 then
    local stderr = vim.trim(out.stderr or "")
    if stderr == "" then
      stderr = ("gh exited with code %d"):format(out.code)
    end
    -- 認証切れは最も多い失敗なので、次にやることを添える
    if stderr:find("auth login") or stderr:find("authentication") then
      stderr = stderr .. "\n(hint: run `gh auth login` or `gh auth refresh`)"
    end
    return stderr, nil
  end
  local ok, decoded =
    pcall(vim.json.decode, out.stdout or "", { luanil = { object = true, array = true } })
  if not ok then
    return "gh returned non-JSON output: " .. tostring(decoded), nil
  end
  return nil, decoded
end

--- gh を実行し、JSON をパースしてメインループ上でコールバックする。
---@param args string[] gh に渡す引数（"gh" 自体は含めない）
---@param stdin? string
---@param cb PrViewer.Callback
function M.run(args, stdin, cb)
  local cfg = require("pr-viewer.config").get().gh
  local cmd = { cfg.cmd }
  vim.list_extend(cmd, args)
  M._system(cmd, {
    text = true,
    stdin = stdin,
    timeout = cfg.timeout_ms,
    -- gh の対話プロンプトと色付けを抑止する
    env = { GH_PROMPT_DISABLED = "1", NO_COLOR = "1", CLICOLOR = "0" },
  }, function(out)
    local err, data = parse_output(out)
    vim.schedule(function()
      cb(err, data)
    end)
  end)
end

--- GraphQL クエリを 1 回実行する。成功時は `data` 直下のテーブルを返す。
---@param query string
---@param variables? table
---@param cb PrViewer.Callback
function M.graphql(query, variables, cb)
  local body = vim.json.encode({ query = query, variables = variables or vim.empty_dict() })
  M.run({ "api", "graphql", "--input", "-" }, body, function(err, res)
    if err then
      return cb(err, nil)
    end
    if type(res) == "table" and res.errors and #res.errors > 0 then
      local msgs = vim.tbl_map(function(e)
        return e.message
      end, res.errors)
      return cb("GraphQL error: " .. table.concat(msgs, "; "), res.data)
    end
    cb(nil, res and res.data or nil)
  end)
end

--- REST API を 1 回実行する。GraphQL に無い操作（viewed 状態の一括更新など）用。
---@param method "GET"|"POST"|"PUT"|"PATCH"|"DELETE"
---@param path string 例: "repos/{owner}/{repo}/pulls/1/files"
---@param body? table
---@param cb PrViewer.Callback
function M.rest(method, path, body, cb)
  local args = { "api", "-X", method, path }
  local stdin
  if body then
    vim.list_extend(args, { "--input", "-" })
    stdin = vim.json.encode(body)
  end
  M.run(args, stdin, cb)
end

return M
