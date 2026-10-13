local M = {}
local api = vim.api

-- Put boundaries around unmatched runs and modified matched lines. Identical
-- matched runs need no anchors, so large files can still fit the 20-anchor cap.
local function anchors(aligned, lhs, rhs)
  if type(aligned) ~= "table" then return end
  local result, a, b = { {}, {} }, 0, 0
  local last_a, last_b, gap
  local function boundary()
    if (a == 0 and b == 0) or (a == #lhs and b == #rhs) then return true end
    if a == last_a and b == last_b then return true end
    if #result[1] == 20 then return false end
    result[1][#result[1] + 1] = tostring(a + 1)
    result[2][#result[2] + 1] = tostring(b + 1)
    last_a, last_b = a, b
    return true
  end
  for _, row in ipairs(aligned) do
    local x, y = row[1], row[2]
    if x == vim.NIL then x = nil end
    if y == vim.NIL then y = nil end
    -- Difftastic includes the empty line after the final newline. It isn't a
    -- buffer line and must not become an out-of-range anchor.
    if x == #lhs then x = nil end
    if y == #rhs then y = nil end
    if x ~= nil or y ~= nil then
      if (x ~= nil and x ~= a) or (y ~= nil and y ~= b) then return end
      local kind = x == nil and "add" or y == nil and "delete" or nil
      if kind ~= gap and not boundary() then return end
      gap = kind
      local changed = x ~= nil and y ~= nil and lhs[x + 1] ~= rhs[y + 1]
      if changed and not boundary() then return end
      if x ~= nil then a = a + 1 end
      if y ~= nil then b = b + 1 end
      if changed and not boundary() then return end
    end
  end
  if a ~= #lhs or b ~= #rhs then return end
  return result
end

function M.clear(state)
  local saved = state.alignment
  if not saved then return end
  state.alignment = nil
  for _, win in ipairs(saved.windows) do
    if api.nvim_buf_is_valid(win.buf) and vim.bo[win.buf].diffanchors == win.applied then
      api.nvim_set_option_value("diffanchors", win.original, { buf = win.buf, scope = "local" })
    end
  end
  -- Only undo the flag we added; preserve other option changes made meanwhile.
  if saved.added_flag then vim.opt.diffopt:remove("anchor") end
end

function M.apply(state, left, right, result, lhs, rhs)
  if vim.fn.exists("+diffanchors") ~= 1 or api.nvim_get_current_tabpage() ~= state.tabpage then return end
  local plan = anchors(result.aligned_lines, lhs, rhs)
  if not plan or #plan[1] == 0 then
    if state.alignment then
      M.clear(state)
      vim.cmd("diffupdate")
    end
    return
  end
  -- Anchors are shared by all diff buffers in the tab; don't alter an unrelated
  -- comparison if the user has added more diff windows to the tab.
  for _, win in ipairs(api.nvim_tabpage_list_wins(state.tabpage)) do
    local buf = api.nvim_win_get_buf(win)
    if vim.wo[win].diff and buf ~= left.buf and buf ~= right.buf then return end
  end
  local saved = state.alignment
  if not saved then
    saved = { windows = {}, added_flag = not vim.tbl_contains(vim.opt.diffopt:get(), "anchor") }
    for _, win in ipairs({ left, right }) do
      saved.windows[#saved.windows + 1] = {
        buf = win.buf,
        original = api.nvim_get_option_value("diffanchors", { buf = win.buf, scope = "local" }),
      }
    end
    state.alignment = saved
  end
  local ok, err = pcall(function()
    for i, win in ipairs(saved.windows) do
      win.applied = table.concat(plan[i], ",")
      vim.bo[win.buf].diffanchors = win.applied
    end
    if saved.added_flag then vim.opt.diffopt:append("anchor") end
    vim.cmd("diffupdate")
  end)
  if not ok then
    M.clear(state)
    require("diffview.utils").err("Difftastic alignment failed: " .. tostring(err), true)
  end
end

return M
