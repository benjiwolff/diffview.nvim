local difftastic = require("diffview.difftastic")
local RevType = require("diffview.vcs.rev").RevType
local eq = assert.are.same

describe("difftastic native word fallback", function()
  local layout, jobs, buffers, jobstart, jobstop

  before_each(function()
    jobs, buffers = {}, {}
    jobstart, jobstop = vim.fn.jobstart, vim.fn.jobstop
    vim.fn.jobstart = function(_, opts)
      jobs[#jobs + 1] = opts
      return #jobs
    end
    vim.fn.jobstop = function() return 1 end
    -- attach() checks PATH before launching the mocked job.
    local executable = vim.fn.executable
    vim.fn.executable = function(name)
      if name == "difft" then return 1 end
      return executable(name)
    end
    layout = { state = {}, windows = {}, executable = executable }
    for i = 1, 2 do
      if i == 2 then vim.cmd("vsplit") end
      local buf = vim.api.nvim_create_buf(false, true)
      buffers[#buffers + 1] = buf
      vim.api.nvim_win_set_buf(0, buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { i == 1 and "local x = 1" or "local x = 2" })
      vim.wo.winhl = "DiffText:DiffviewDiffText,DiffChange:DiffviewDiffChange"
      layout.windows[i] = {
        id = vim.api.nvim_get_current_win(),
        file = { bufnr = buf, path = "example.lua", rev = { type = RevType.LOCAL } },
        is_file_open = function() return true end,
        is_nulled = function() return false end,
      }
    end
    layout.get_main_win = function() return layout.windows[2] end
  end)

  after_each(function()
    difftastic.detach(layout)
    vim.fn.jobstart, vim.fn.jobstop = jobstart, jobstop
    vim.fn.executable = layout.executable
    vim.cmd("only!")
    for _, buf in ipairs(buffers) do
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  local function complete(language, code, raw)
    local job = jobs[#jobs]
    job.on_stdout(1, {
      raw
        or vim.fn.json_encode({
          status = "changed",
          language = language,
          chunks = {
            {
              {
                lhs = { line_number = 0, changes = { { start = 10, ["end"] = 11 } } },
                rhs = { line_number = 0, changes = { { start = 10, ["end"] = 11 } } },
              },
            },
          },
        }),
    })
    job.on_exit(1, code or 0)
  end

  local function native()
    for _, win in ipairs(layout.state.difftastic.windows) do
      eq(win.original, vim.wo[win.id].winhl)
      eq({}, win.matches or {})
    end
  end

  local function refresh()
    local count = #jobs
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buffers[1] })
    assert.is_true(vim.wait(1000, function() return #jobs > count end))
  end

  for _, language in ipairs({ "Text", "Text (exceeded DFT_BYTE_LIMIT)" }) do
    it("uses native words for " .. language .. " despite nonempty ranges", function()
      difftastic.attach(layout)
      native()
      complete(language)
      native()
    end)
  end

  it("switches between syntax words and native words across refreshes", function()
    difftastic.attach(layout)
    complete("Lua")
    for _, win in ipairs(layout.state.difftastic.windows) do
      eq(win.applied, vim.wo[win.id].winhl)
      assert.is_true(#win.matches > 0)
    end
    refresh()
    complete("Text")
    native()
    refresh()
    complete("Lua")
    for _, win in ipairs(layout.state.difftastic.windows) do
      eq(win.applied, vim.wo[win.id].winhl)
      assert.is_true(#win.matches > 0)
    end
  end)

  for _, failure in ipairs({ "command", "json" }) do
    it("restores native words after a " .. failure .. " failure", function()
      difftastic.attach(layout)
      complete("Lua")
      refresh()
      complete("Lua", failure == "command" and 1 or 0, failure == "json" and "invalid" or nil)
      native()
    end)
  end

  it("keeps syntax mode for valid output with no changed tokens", function()
    difftastic.attach(layout)
    complete("Lua", 0, vim.fn.json_encode({ language = "Lua", status = "unchanged" }))
    for _, win in ipairs(layout.state.difftastic.windows) do
      eq(win.applied, vim.wo[win.id].winhl)
      eq({}, win.matches)
    end
  end)

  it("restores original highlighting when detached", function()
    difftastic.attach(layout)
    complete("Lua")
    local state = layout.state.difftastic
    difftastic.detach(layout)
    for _, win in ipairs(state.windows) do
      eq(win.original, vim.wo[win.id].winhl)
      eq({}, win.matches)
    end
  end)

  it("keeps native words when a job cannot start", function()
    vim.fn.jobstart = function() return 0 end
    difftastic.attach(layout)
    native()
  end)
end)
