-- Difftastic refines inline emphasis; Neovim still owns line alignment.
local M = {}
local api = vim.api

-- Resolve the token colors before suppressing DiffText. A link back to DiffText
-- would also inherit the window's native-inline suppression.
function M.token_highlight(winid)
  local group = "DiffviewDifftasticToken" .. winid
  api.nvim_win_call(winid, function()
    local winhl = vim.wo.winhl
    vim.wo.winhl = ""
    vim.cmd("redraw")
    local ok, colors = pcall(function()
      if api.nvim_get_hl then
        return api.nvim_get_hl(0, { name = "DiffviewDiffText", link = false })
      end
      local value = api.nvim_get_hl_by_name("DiffviewDiffText", true)
      value.fg, value.bg, value.sp = value.foreground, value.background, value.special
      value.foreground, value.background, value.special = nil, nil, nil
      return value
    end)
    vim.wo.winhl = winhl
    assert(ok, colors)
    api.nvim_set_hl(0, group, colors)
  end)
  return group
end

function M.clear_tokens(win)
  for _, id in ipairs(win.matches or {}) do
    if api.nvim_win_is_valid(win.id) then pcall(vim.fn.matchdelete, id, win.id) end
  end
  win.matches = {}
end

function M.highlight_tokens(win, ranges, group)
  M.clear_tokens(win)
  -- Unlike extmarks, match backgrounds take precedence over diff-line backgrounds.
  api.nvim_win_call(win.id, function()
    local positions = {}
    local function flush()
      if #positions > 0 then
        win.matches[#win.matches + 1] = vim.fn.matchaddpos(group, positions, 200)
        positions = {}
      end
    end
    for _, range in ipairs(ranges) do
      positions[#positions + 1] = { range[1] + 1, range[2] + 1, range[3] - range[2] }
      if #positions == 8 then flush() end
    end
    flush()
  end)
end

function M.ranges(result, side)
  local ranges = {}
  assert(type(result) == "table" and type(result.status) == "string", "Invalid difftastic output")
  for _, chunk in ipairs(result.chunks or {}) do
    for _, line in ipairs(chunk) do
      local value = line[side]
      if value and value ~= vim.NIL then
        for _, change in ipairs(value.changes or {}) do
          if change["end"] > change.start then
            ranges[#ranges + 1] = { value.line_number, change.start, change["end"] }
          end
        end
      end
    end
  end
  return ranges
end

function M.detach(layout)
  local state = layout.state.difftastic
  if not state then return end
  layout.state.difftastic = nil
  state.generation = state.generation + 1
  if state.group then api.nvim_del_augroup_by_id(state.group) end
  for _, job in ipairs(state.jobs) do pcall(vim.fn.jobstop, job) end
  for _, win in ipairs(state.windows) do
    M.clear_tokens(win)
    if api.nvim_win_is_valid(win.id) and vim.wo[win.id].winhl == win.applied then
      vim.wo[win.id].winhl = win.original
    end
  end
end

function M.attach(layout)
  M.detach(layout)
  if #layout.windows < 2 then return end
  if vim.fn.executable("difft") ~= 1 then
    require("diffview.utils").err(
      "Difftastic is not installed or not on PATH. Install the 'difft' executable for word highlighting.",
      true
    )
    return
  end
  local state = { generation = 0, jobs = {}, windows = {} }
  layout.state.difftastic = state
  for _, win in ipairs(layout.windows) do
    if not win:is_file_open() or win:is_nulled() then
      M.detach(layout)
      return
    end
    state.windows[#state.windows + 1] = {
      id = win.id, buf = win.file.bufnr, path = win.file.path,
      original = vim.wo[win.id].winhl,
    }
  end
  local function refresh()
    state.generation = state.generation + 1
    local generation = state.generation
    for _, job in ipairs(state.jobs) do pcall(vim.fn.jobstop, job) end
    state.jobs = {}
    local ticks, contents = {}, {}
    for i, win in ipairs(state.windows) do
      if not api.nvim_buf_is_valid(win.buf) then return end
      ticks[i] = api.nvim_buf_get_changedtick(win.buf)
      contents[i] = api.nvim_buf_get_lines(win.buf, 0, -1, false)
      M.clear_tokens(win)
      if win.applied and api.nvim_win_is_valid(win.id) and vim.wo[win.id].winhl == win.applied then
        vim.wo[win.id].winhl = win.original
      end
    end
    local main = layout:get_main_win().id
    local main_index
    for i, win in ipairs(state.windows) do if win.id == main then main_index = i end end
    if not main_index then return end
    local pending, all_ranges, failed = #state.windows - 1, {}, false
    for i = 1, #state.windows do all_ranges[i] = {} end
    for i, win in ipairs(state.windows) do
      if i ~= main_index then
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local name = vim.fn.fnamemodify(win.path, ":t")
        local lhs, rhs = dir .. "/old-" .. name, dir .. "/new-" .. name
        vim.fn.writefile(contents[i], lhs)
        vim.fn.writefile(contents[main_index], rhs)
        local output = {}
        local job = vim.fn.jobstart({ "difft", "--display", "json", "--color", "never", lhs, rhs }, {
          env = { DFT_UNSTABLE = "yes", DFT_EXIT_CODE = "false" },
          stdout_buffered = true,
          on_stdout = function(_, data) output = data end,
          on_exit = function(_, code)
            vim.fn.delete(dir, "rf")
            if layout.state.difftastic ~= state or generation ~= state.generation then return end
            local ok, left, right = pcall(function()
              assert(code == 0, "difft failed")
              local result = vim.fn.json_decode(table.concat(output, "\n"))
              return M.ranges(result, "lhs"), M.ranges(result, "rhs")
            end)
            if ok then
              vim.list_extend(all_ranges[i], left)
              vim.list_extend(all_ranges[main_index], right)
            else
              failed = true
            end
            pending = pending - 1
            if pending ~= 0 or failed then return end
            for j, target in ipairs(state.windows) do
              if not api.nvim_buf_is_valid(target.buf)
                or api.nvim_buf_get_changedtick(target.buf) ~= ticks[j]
                or not api.nvim_win_is_valid(target.id)
                or api.nvim_win_get_buf(target.id) ~= target.buf then return end
            end
            for j, target in ipairs(state.windows) do
              -- Map native inline emphasis to the line background, without changing diffopt.
              local token_group = M.token_highlight(target.id)
              target.original = vim.wo[target.id].winhl
              local mappings = {}
              local line_hl = target.original:match("DiffChange:([^,]+)") or "DiffChange"
              for mapping in target.original:gmatch("[^,]+") do
                if not mapping:match("^DiffText:") then mappings[#mappings + 1] = mapping end
              end
              mappings[#mappings + 1] = "DiffText:" .. line_hl
              target.applied = table.concat(mappings, ",")
              vim.wo[target.id].winhl = target.applied
              M.highlight_tokens(target, all_ranges[j], token_group)
            end
          end,
        })
        if job <= 0 then
          vim.fn.delete(dir, "rf")
          failed = true
        else
          state.jobs[#state.jobs + 1] = job
        end
      end
    end
  end
  state.group = api.nvim_create_augroup("DiffviewDifftastic" .. state.windows[1].id, { clear = true })
  for _, win in ipairs(state.windows) do
    api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
      group = state.group, buffer = win.buf,
      callback = function()
        state.generation = state.generation + 1
        local generation = state.generation
        vim.defer_fn(function()
          if layout.state.difftastic == state and generation == state.generation then refresh() end
        end, 150)
      end,
    })
  end
  refresh()
end

return M
