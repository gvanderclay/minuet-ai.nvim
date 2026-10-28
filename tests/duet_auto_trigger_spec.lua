local helpers = require 'tests.helpers'

-- The auto trigger only fires in normal file buffers; helpers.create_buffer
-- makes scratch buffers, so clear the buftype.
local function create_normal_buffer(lines, cursor)
    local bufnr = helpers.create_buffer(lines, cursor)
    vim.bo[bufnr].buftype = ''
    return bufnr
end

-- The test runner cannot stay in Insert mode while it runs, so the mode duet
-- sees is stubbed and the Insert-mode autocmds are fired by hand.
local original_get_mode = vim.api.nvim_get_mode
local current_mode = 'n'
local function stub_mode()
    current_mode = 'n'
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_get_mode = function()
        return { mode = current_mode, blocking = false }
    end
end

local function restore_mode()
    vim.api.nvim_get_mode = original_get_mode
end

-- Type in Insert mode before the line's last character (Normal mode, which
-- the runner is really in, cannot put the cursor past the end).
local function type_in_insert_mode(bufnr, line)
    current_mode = 'i'
    vim.api.nvim_exec_autocmds('InsertEnter', { buffer = bufnr, modeline = false })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(0, { 1, #line - 1 })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })
end

-- <Esc>: the cursor steps back onto the last character, then InsertLeave.
local function press_esc(bufnr)
    current_mode = 'n'
    local cursor = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_win_set_cursor(0, { cursor[1], math.max(cursor[2] - 1, 0) })
    vim.api.nvim_exec_autocmds('InsertLeave', { buffer = bufnr, modeline = false })
end

local function pause(ms)
    vim.wait(ms, function()
        return false
    end, 10)
end

local function setup_hold(extra)
    helpers.setup_root_config {
        duet = vim.tbl_deep_extend('force', {
            provider = 'test',
            auto_trigger = {
                debounce = 20,
                hold_in_insert_mode = true,
            },
            editable_region = {
                lines_before = 0,
                lines_after = 0,
            },
        }, extra or {}),
    }

    local backend = { calls = {} }
    package.loaded['minuet.duet.backends.test'] = {
        complete = function(context, callback)
            table.insert(backend.calls, { context = context, callback = callback, mode = current_mode })
        end,
    }

    local duet = helpers.reload 'minuet.duet'
    duet.setup()
    stub_mode()
    return duet, backend
end

local held_response = [[<editable_region>
local value = 123<cursor_position/>;
</editable_region>]]

return {
    {
        name = 'duet hold_in_insert_mode predicts in Insert mode, shows nothing there, and shows the result on <Esc>',
        run = function()
            local duet, backend = setup_hold()
            local bufnr = create_normal_buffer({ 'local value = 1;' }, { 1, 0 })
            duet.action.enable_auto_trigger()

            type_in_insert_mode(bufnr, 'local value = 12;')
            helpers.wait_until(function()
                return #backend.calls > 0
            end, 1000, 'no prediction while typing paused in Insert mode')

            local call = backend.calls[1]
            helpers.expect_equal(call.mode, 'i', 'the prediction should start in Insert mode')
            -- Predicted from the cursor Normal mode will have: on the '2'.
            helpers.expect_equal(call.context.editable_region_before_cursor, 'local value = 1')

            call.callback(held_response)
            pause(50)
            helpers.expect_falsy(duet.action.is_visible(), 'a held prediction rendered in Insert mode')

            press_esc(bufnr)
            helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, 15 })
            helpers.expect_truthy(duet.action.is_visible(), 'the held prediction was not shown on <Esc>')

            pause(80)
            helpers.expect_equal(#backend.calls, 1, 'leaving Insert mode should reuse the held prediction')

            duet.action.apply()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local value = 123;' })

            restore_mode()
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet hold_in_insert_mode shows a request still running at <Esc> when it arrives',
        run = function()
            local duet, backend = setup_hold()
            local bufnr = create_normal_buffer({ 'local value = 1;' }, { 1, 0 })
            duet.action.enable_auto_trigger()

            type_in_insert_mode(bufnr, 'local value = 12;')
            helpers.wait_until(function()
                return #backend.calls > 0
            end, 1000, 'no prediction while typing paused in Insert mode')

            press_esc(bufnr)
            pause(80)
            helpers.expect_equal(#backend.calls, 1, 'leaving Insert mode should wait for the running prediction')
            helpers.expect_falsy(duet.action.is_visible())

            backend.calls[1].callback(held_response)
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'the prediction did not show when it arrived after <Esc>')

            restore_mode()
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet hold_in_insert_mode discards a held result when the cursor moved and predicts again',
        run = function()
            local duet, backend = setup_hold()
            local bufnr = create_normal_buffer({ 'local value = 1;' }, { 1, 0 })
            duet.action.enable_auto_trigger()

            type_in_insert_mode(bufnr, 'local value = 12;')
            helpers.wait_until(function()
                return #backend.calls > 0
            end, 1000, 'no prediction while typing paused in Insert mode')
            backend.calls[1].callback(held_response)
            pause(20)

            vim.api.nvim_win_set_cursor(0, { 1, 4 })
            press_esc(bufnr)
            helpers.expect_falsy(duet.action.is_visible(), 'a held prediction for another cursor was shown')

            helpers.wait_until(function()
                return #backend.calls == 2
            end, 1000, 'leaving Insert mode did not predict again')
            helpers.expect_equal(backend.calls[2].mode, 'n')

            -- The first answer, arriving again, must not render either.
            backend.calls[1].callback(held_response)
            pause(20)
            helpers.expect_falsy(duet.action.is_visible())

            restore_mode()
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet hold_in_insert_mode predicts while the completion menu is open',
        run = function()
            local duet, backend = setup_hold()
            local shared_utils = require 'minuet.utils'
            local original_menu_visible = shared_utils.completion_menu_visible
            ---@diagnostic disable-next-line: duplicate-set-field
            shared_utils.completion_menu_visible = function()
                return true
            end
            local bufnr = create_normal_buffer({ 'local value = 1;' }, { 1, 0 })
            duet.action.enable_auto_trigger()

            type_in_insert_mode(bufnr, 'local value = 12;')
            local predicted = vim.wait(1000, function()
                return #backend.calls > 0
            end, 10)
            shared_utils.completion_menu_visible = original_menu_visible
            helpers.expect_truthy(predicted, 'an open completion menu stopped a held prediction')

            press_esc(bufnr)
            restore_mode()
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet hold_in_insert_mode waits for a running inline completion request',
        run = function()
            local duet, backend = setup_hold()
            local completion_common = require 'minuet.backends.common'
            completion_common.current_jobs = { { pid = -1 } }
            local bufnr = create_normal_buffer({ 'local value = 1;' }, { 1, 0 })
            duet.action.enable_auto_trigger()

            type_in_insert_mode(bufnr, 'local value = 12;')
            pause(150)
            local calls_while_completing = #backend.calls
            completion_common.current_jobs = {}
            helpers.expect_equal(calls_while_completing, 0, 'predicted while inline completion was running')

            helpers.wait_until(function()
                return #backend.calls > 0
            end, 1000, 'no prediction after inline completion finished')

            press_esc(bufnr)
            restore_mode()
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet hold_in_insert_mode uses insert_mode_debounce in Insert mode',
        run = function()
            local duet, backend = setup_hold { auto_trigger = { insert_mode_debounce = 300 } }
            local bufnr = create_normal_buffer({ 'local value = 1;' }, { 1, 0 })
            duet.action.enable_auto_trigger()

            local typed = vim.uv.now()
            type_in_insert_mode(bufnr, 'local value = 12;')
            helpers.wait_until(function()
                return #backend.calls > 0
            end, 2000, 'no prediction while typing paused in Insert mode')
            helpers.expect_truthy(vim.uv.now() - typed >= 300, 'the held prediction ignored insert_mode_debounce')

            press_esc(bufnr)
            restore_mode()
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet stops a running request when the text changes',
        run = function()
            local duet, backend = setup_hold()
            local common = require 'minuet.duet.backends.common'
            local bufnr = create_normal_buffer({ 'local value = 1;' }, { 1, 0 })
            duet.action.enable_auto_trigger()

            type_in_insert_mode(bufnr, 'local value = 12;')
            helpers.wait_until(function()
                return #backend.calls > 0
            end, 1000, 'no prediction while typing paused in Insert mode')

            local killed = false
            common.current_jobs = {
                {
                    pid = -1,
                    kill = function()
                        killed = true
                    end,
                },
            }
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local value = 123;' })
            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })
            helpers.expect_truthy(killed, 'typing again did not stop the running request')

            press_esc(bufnr)
            restore_mode()
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet hold_in_insert_mode includes the newest edit in the prompt',
        run = function()
            local duet, backend = setup_hold {
                auto_trigger = { flush_timeout = 2000 },
                recent_edits = { enabled = true, debounce = 10000 },
            }
            local bufnr = create_normal_buffer({ 'local value = 1;' }, { 1, 0 })
            require('minuet.duet.edits').track(bufnr)
            duet.action.enable_auto_trigger()

            type_in_insert_mode(bufnr, 'local value = 12;')
            helpers.wait_until(function()
                return #backend.calls > 0
            end, 3000, 'no prediction while typing paused in Insert mode')
            helpers.expect_match(backend.calls[1].context.recent_edits, 'local value = 12')

            press_esc(bufnr)
            restore_mode()
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet auto trigger fires a single prediction after the debounce gap',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    auto_trigger = {
                        debounce = 20,
                    },
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }

            local complete_count = 0

            package.loaded['minuet.duet.backends.test'] = {
                complete = function()
                    complete_count = complete_count + 1
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = create_normal_buffer({ 'return 1' }, { 1, 8 })
            duet.action.enable_auto_trigger()

            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })
            vim.wait(5, function()
                return false
            end, 5)
            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })

            helpers.wait_until(function()
                return complete_count > 0
            end, 1000, 'auto trigger did not fire a prediction')

            -- The two text changes are within one debounce gap, so they must
            -- collapse into a single request.
            vim.wait(60, function()
                return false
            end, 10)
            helpers.expect_equal(complete_count, 1, 'debounced text changes should produce one request')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet auto trigger predicts on InsertLeave after an insert whose debounce ran out in Insert mode',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    auto_trigger = {
                        debounce = 20,
                    },
                },
            }

            local complete_count = 0
            package.loaded['minuet.duet.backends.test'] = {
                complete = function()
                    complete_count = complete_count + 1
                end,
            }

            -- Stands in for a `vim.fn.mode() == 'n'` predicate.
            local in_normal_mode = false
            require('minuet').config.duet.auto_trigger.enable_predicates = {
                function()
                    return in_normal_mode
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = create_normal_buffer({ 'return 1' }, { 1, 8 })
            duet.action.enable_auto_trigger()

            -- Typing, then a pause longer than the debounce before <Esc>.
            vim.api.nvim_exec_autocmds('InsertEnter', { buffer = bufnr, modeline = false })
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })
            vim.wait(80, function()
                return false
            end, 10)
            helpers.expect_equal(complete_count, 0, 'the predicate should block predictions in Insert mode')

            in_normal_mode = true
            vim.api.nvim_exec_autocmds('InsertLeave', { buffer = bufnr, modeline = false })
            helpers.wait_until(function()
                return complete_count > 0
            end, 1000, 'leaving Insert mode after an edit did not predict')
            helpers.expect_equal(complete_count, 1)

            -- An insert that changed nothing must not predict.
            vim.api.nvim_exec_autocmds('InsertEnter', { buffer = bufnr, modeline = false })
            vim.api.nvim_exec_autocmds('InsertLeave', { buffer = bufnr, modeline = false })
            vim.wait(80, function()
                return false
            end, 10)
            helpers.expect_equal(complete_count, 1, 'an insert without edits predicted')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet auto trigger stays quiet when disabled or gated by its own enable_predicates',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    auto_trigger = {
                        debounce = 20,
                    },
                },
            }

            local complete_count = 0

            package.loaded['minuet.duet.backends.test'] = {
                complete = function()
                    complete_count = complete_count + 1
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = create_normal_buffer({ 'return 1' }, { 1, 8 })

            -- The buffer variable was never enabled, so nothing may fire.
            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })
            vim.wait(100, function()
                return false
            end, 10)
            helpers.expect_equal(complete_count, 0, 'auto trigger fired in a buffer where it is disabled')

            -- With the buffer enabled but a failing duet predicate, it must
            -- stay quiet as well.
            require('minuet').config.duet.auto_trigger.enable_predicates = {
                function()
                    return false
                end,
            }
            duet.action.enable_auto_trigger()

            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })
            vim.wait(100, function()
                return false
            end, 10)
            helpers.expect_equal(complete_count, 0, 'auto trigger fired despite a failing enable predicate')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet auto trigger ignores the global enable_predicates',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    auto_trigger = {
                        debounce = 20,
                    },
                },
            }

            -- The global predicate list gates inline completion only; duet
            -- has its own list, so a failing global predicate must not stop
            -- an automatic prediction.
            require('minuet').config.enable_predicates = {
                function()
                    return false
                end,
            }

            local complete_count = 0

            package.loaded['minuet.duet.backends.test'] = {
                complete = function()
                    complete_count = complete_count + 1
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = create_normal_buffer({ 'return 1' }, { 1, 8 })
            duet.action.enable_auto_trigger()

            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })

            helpers.wait_until(function()
                return complete_count > 0
            end, 1000, 'auto trigger did not fire despite the global predicate list being irrelevant')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet auto trigger flushes recent edits with its shorter timeout while manual predict keeps the default',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    auto_trigger = {
                        debounce = 20,
                        flush_timeout = 50,
                    },
                },
            }

            local captured_flush_opts

            -- Stub the edits module before minuet.duet is (re)loaded: it is
            -- required at module top level, and context.build calls
            -- edits.render() while building the prompt.
            package.loaded['minuet.duet.edits'] = {
                setup = function() end,
                ensure_setup = function() end,
                render = function()
                    return ''
                end,
                flush = function(_, opts)
                    captured_flush_opts = opts
                end,
            }

            package.loaded['minuet.duet.backends.test'] = {
                complete = function() end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = create_normal_buffer({ 'return 1' }, { 1, 8 })
            duet.action.enable_auto_trigger()

            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })

            helpers.wait_until(function()
                return captured_flush_opts ~= nil
            end, 1000, 'auto trigger did not flush recent edits')

            helpers.expect_equal(captured_flush_opts, { wait = true, timeout = 50 })

            captured_flush_opts = nil
            duet.action.predict()

            helpers.expect_equal(
                captured_flush_opts,
                { wait = true },
                'manual predict should keep the default flush timeout'
            )

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet auto_trigger_ft enables the buffer variable per filetype and honors the ignore list',
        run = function()
            helpers.setup_root_config {
                duet = {
                    auto_trigger = {
                        auto_trigger_ft = { 'lua' },
                    },
                },
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local lua_bufnr = create_normal_buffer { 'return 1' }
            vim.bo[lua_bufnr].filetype = 'lua'
            helpers.expect_truthy(
                vim.b[lua_bufnr].minuet_duet_auto_trigger,
                'lua buffer should have auto trigger enabled'
            )

            local text_bufnr = create_normal_buffer { 'hello' }
            vim.bo[text_bufnr].filetype = 'text'
            helpers.expect_falsy(
                vim.b[text_bufnr].minuet_duet_auto_trigger,
                'text buffer should not have auto trigger enabled'
            )

            helpers.delete_buffer(lua_bufnr)
            helpers.delete_buffer(text_bufnr)

            helpers.setup_root_config {
                duet = {
                    auto_trigger = {
                        auto_trigger_ft = { '*' },
                        auto_trigger_ignore_ft = { 'text' },
                    },
                },
            }

            duet = helpers.reload 'minuet.duet'
            duet.setup()

            local ignored_bufnr = create_normal_buffer { 'hello' }
            vim.bo[ignored_bufnr].filetype = 'text'
            helpers.expect_falsy(
                vim.b[ignored_bufnr].minuet_duet_auto_trigger,
                'ignored filetype should not have auto trigger enabled'
            )

            local enabled_bufnr = create_normal_buffer { 'return 1' }
            vim.bo[enabled_bufnr].filetype = 'lua'
            helpers.expect_truthy(
                vim.b[enabled_bufnr].minuet_duet_auto_trigger,
                'wildcard filetype should enable auto trigger'
            )

            helpers.delete_buffer(ignored_bufnr)
            helpers.delete_buffer(enabled_bufnr)
        end,
    },
}
