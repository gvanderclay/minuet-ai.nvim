local helpers = require 'tests.helpers'

-- The test runner cannot stay in Insert mode, so the mode virtual text sees is
-- stubbed, and typing is simulated by editing the line, moving the cursor and
-- firing CursorMovedI by hand. This tests how answers are handled, not how
-- Neovim delivers typing events.
local original_mode = vim.fn.mode

local function stub_insert_mode()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.mode = function()
        return 'i'
    end
end

local function restore_mode()
    vim.fn.mode = original_mode
end

local function pause(ms)
    vim.wait(ms, function()
        return false
    end, 10)
end

local function setup()
    helpers.setup_root_config {
        provider = 'test',
        debounce = 20,
        throttle = 0,
    }

    local backend = { calls = {} }
    package.loaded['minuet.backends.test'] = {
        complete = function(context, callback)
            table.insert(backend.calls, { context = context, callback = callback })
        end,
    }

    local virtualtext = helpers.reload 'minuet.virtualtext'
    virtualtext.setup()
    stub_insert_mode()
    return virtualtext, backend
end

-- A file buffer whose line ends with ')', so the cursor can sit after the
-- typed text while the runner is really in Normal mode.
local function create_buffer(line, col)
    local bufnr = helpers.create_buffer({ line }, { 1, col })
    vim.bo[bufnr].buftype = ''
    vim.b[bufnr].minuet_virtual_text_auto_trigger = true
    return bufnr
end

local function type_text(bufnr, line, col)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(0, { 1, col })
    vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr, modeline = false })
end

local function shown_text(virtualtext, bufnr)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, virtualtext.ns_id, 0, -1, { details = true })
    if not marks[1] then
        return nil
    end
    return marks[1][4].virt_text[1][1]
end

-- Request a suggestion with the cursor right after 'f' in 'local x = f)'.
local function request_after_f(backend)
    local bufnr = create_buffer('local x = f)', 11)
    vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr, modeline = false })
    helpers.wait_until(function()
        return #backend.calls == 1
    end, 1000, 'no suggestion was requested')
    -- Even with throttle = 0 the throttle flag clears one event-loop turn
    -- later; a key typed before then schedules nothing. Let it clear, as it
    -- always has between real keystrokes.
    pause(30)
    return bufnr
end

local function run_case(fn)
    local virtualtext, backend = setup()
    local bufnr
    local ok, err = pcall(function()
        bufnr = request_after_f(backend)
        fn(virtualtext, backend, bufnr)
    end)
    restore_mode()
    helpers.delete_buffer(bufnr)
    if not ok then
        error(err, 0)
    end
end

return {
    {
        name = 'virtualtext shows an answer as it arrives when the cursor has not moved',
        run = function()
            run_case(function(virtualtext, backend, bufnr)
                backend.calls[1].callback { 'oo_bar()' }
                helpers.expect_equal(shown_text(virtualtext, bufnr), 'oo_bar()')
            end)
        end,
    },
    {
        name = 'virtualtext shows the rest of a late answer that matches the text typed since the request',
        run = function()
            run_case(function(virtualtext, backend, bufnr)
                type_text(bufnr, 'local x = fo)', 12)
                backend.calls[1].callback { 'oo_bar()' }

                helpers.expect_equal(
                    shown_text(virtualtext, bufnr),
                    'o_bar()',
                    'the late answer should continue after the typed text'
                )

                pause(80)
                helpers.expect_equal(#backend.calls, 1, 'a matching late answer should not be requested again')
                helpers.expect_equal(shown_text(virtualtext, bufnr), 'o_bar()')
            end)
        end,
    },
    {
        name = 'virtualtext drops a late answer that does not match the text typed since the request',
        run = function()
            run_case(function(virtualtext, backend, bufnr)
                type_text(bufnr, 'local x = fx)', 12)
                backend.calls[1].callback { 'oo_bar()' }

                helpers.expect_equal(shown_text(virtualtext, bufnr), nil, 'a stale answer was shown')

                helpers.wait_until(function()
                    return #backend.calls == 2
                end, 1000, 'no new suggestion was requested for the typed text')
            end)
        end,
    },
}
