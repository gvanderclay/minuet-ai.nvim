local api = vim.api
local common = require 'minuet.duet.backends.common'
local context = require 'minuet.duet.context'
local edits = require 'minuet.duet.edits'
local preview = require 'minuet.duet.preview'
local utils = require 'minuet.duet.utils'
local shared_utils = require 'minuet.utils'

local M = {}

M.augroup = api.nvim_create_augroup('MinuetDuet', { clear = true })

local internal = {
    states = {},
    request_seq = 0,
    timer = nil,
    -- changedtick of each buffer when Insert mode was entered
    insert_ticks = {},
}

local function stop_timer()
    if internal.timer and not internal.timer:is_closing() then
        internal.timer:stop()
        internal.timer:close()
        internal.timer = nil
    end
end

local function get_state(bufnr)
    local state = internal.states[bufnr]
    if not state then
        state = {}
        internal.states[bufnr] = state
    end

    return state
end

---Stop and forget the prediction made for after the shown one.
local function discard_prefetch(state)
    if state.prefetch and not state.prefetch.done then
        common.terminate_prefetch_jobs()
    end
    state.prefetch = nil
end

local function clear_state(bufnr, state)
    state = state or get_state(bufnr)
    preview.clear(bufnr, state)
    discard_prefetch(state)
    state.skip_tick = nil
    state.pending_seq = nil
    state.changedtick = nil
    state.range = nil
    state.original_lines = nil
    state.proposed_lines = nil
    state.proposed_cursor = nil
    state.request_tick = nil
    state.leave_cursor = nil
end

local function in_insert_mode()
    local mode = api.nvim_get_mode().mode:sub(1, 1)
    return mode == 'i' or mode == 'R'
end

---The cursor Normal mode will have after <Esc>: on the character before the
---Insert-mode cursor, or unchanged at the start of a line.
---@return integer[] (1,0)-indexed cursor
local function normal_mode_cursor()
    local cursor = api.nvim_win_get_cursor(0)
    if cursor[2] == 0 then
        return cursor
    end
    local line = api.nvim_get_current_line()
    local col = math.min(cursor[2], #line)
    if col == 0 then
        return { cursor[1], 0 }
    end
    return { cursor[1], col + vim.str_utf_start(line, col) - 1 }
end

local function current_provider()
    return require('minuet').config.duet.provider
end

local show

---Show the prefetched prediction that apply waited for, if it proposes an
---edit and the buffer is still as apply left it.
local function use_prefetch(bufnr, state)
    local prefetch = state.prefetch
    state.prefetch = nil
    local auto_trigger = require('minuet').config.duet.auto_trigger
    if
        not prefetch.parsed
        or utils.get_changedtick(bufnr) ~= prefetch.applied_tick
        or (auto_trigger.hold_in_insert_mode and in_insert_mode())
    then
        return
    end

    state.changedtick = prefetch.applied_tick
    state.range = prefetch.context.range
    state.original_lines = prefetch.context.original_lines
    state.proposed_lines = prefetch.parsed.lines
    state.proposed_cursor = prefetch.parsed.cursor
    show(bufnr, state)
end

---Predict from the buffer as applying the shown prediction will leave it,
---so apply can show the next prediction without waiting.
local function start_prefetch(bufnr, state)
    local config = require('minuet').config.duet
    if not config.prefetch then
        return
    end
    discard_prefetch(state)

    local ok, backend = pcall(require, 'minuet.duet.backends.' .. config.provider)
    if not ok then
        return
    end

    local old_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local lines = vim.list_slice(old_lines, 1, state.range.start_row)
    vim.list_extend(lines, state.proposed_lines)
    vim.list_extend(lines, old_lines, state.range.end_row + 1)
    local row = state.range.start_row + state.proposed_cursor.row_offset + 1
    local cursor = { row, math.min(state.proposed_cursor.col, #(lines[row] or '')) }

    local edit
    if config.recent_edits.enabled then
        ---@diagnostic disable-next-line: deprecated
        local diff = (vim.text and vim.text.diff) or vim.diff
        local hunks = diff(table.concat(old_lines, '\n') .. '\n', table.concat(lines, '\n') .. '\n', {
            ctxlen = config.recent_edits.diff_context_lines,
        })
        ---@cast hunks string
        edit = hunks:gsub('\n$', '')
    end

    local prefetch_context = context.build(bufnr, { cursor = cursor, lines = lines, edit = edit })
    ---@type { cursor: integer[], context: minuet.DuetContext, done?: boolean, parsed?: table, applied_tick?: integer }
    local prefetch = { cursor = cursor, context = prefetch_context }
    state.prefetch = prefetch

    backend.complete(prefetch_context, function(text)
        vim.schedule(function()
            if state.prefetch ~= prefetch then
                return
            end
            prefetch.done = true
            if text then
                prefetch.parsed = utils.parse_duet_response(text, prefetch_context)
            end
            if prefetch.applied_tick then
                use_prefetch(bufnr, state)
            end
        end)
    end, { prefetch = true })
end

show = function(bufnr, state)
    preview.render(bufnr, state)
    start_prefetch(bufnr, state)
end

---@param opts? { flush_timeout?: integer, hold?: boolean } flush_timeout bounds the recent-edits wait in milliseconds; defaults to recent_edits.flush_timeout. hold predicts from the cursor Normal mode will have and keeps the result hidden until Insert mode is left
local function predict(opts)
    stop_timer()

    local bufnr = api.nvim_get_current_buf()
    local state = get_state(bufnr)

    clear_state(bufnr, state)

    -- With recent_edits.enabled = 'lazy' the recorder is set up on the first
    -- prediction rather than at plugin setup, so users who never invoke duet
    -- pay nothing for it. No-op when already set up or disabled.
    edits.ensure_setup()

    -- Record edits made since the last idle flush so the freshest burst is
    -- part of the prompt's recent-edits history; wait (bounded) for the
    -- in-flight diffs so the history is as fresh as possible.
    edits.flush(bufnr, { wait = true, timeout = opts and opts.flush_timeout })

    local leave_cursor = opts and opts.hold and normal_mode_cursor() or nil
    local current_context = context.build(bufnr, { cursor = leave_cursor })
    local provider_name = current_provider()
    local ok, backend = pcall(require, 'minuet.duet.backends.' .. provider_name)

    if not ok then
        utils.notify('Minuet duet provider is not supported: ' .. provider_name, 'error', vim.log.levels.ERROR)
        return
    end

    internal.request_seq = internal.request_seq + 1
    local request_seq = internal.request_seq
    state.pending_seq = request_seq
    state.request_tick = current_context.changedtick
    state.leave_cursor = leave_cursor

    utils.notify('Minuet duet started', 'verbose', vim.log.levels.INFO)

    backend.complete(current_context, function(text)
        vim.schedule(function()
            if not api.nvim_buf_is_loaded(bufnr) or state.pending_seq ~= request_seq then
                return
            end

            state.pending_seq = nil

            if not text then
                return
            end

            if utils.get_changedtick(bufnr) ~= current_context.changedtick then
                utils.notify(
                    'Minuet duet result arrived after the buffer changed; discarded stale preview.',
                    'verbose',
                    vim.log.levels.INFO
                )
                return
            end

            local parsed, err = utils.parse_duet_response(text, current_context)
            if not parsed then
                utils.notify('Minuet duet returned invalid output: ' .. err, 'warn', vim.log.levels.WARN)
                return
            end

            state.changedtick = current_context.changedtick
            state.range = current_context.range
            state.original_lines = current_context.original_lines
            state.proposed_lines = parsed.lines
            state.proposed_cursor = parsed.cursor

            -- A held prediction is shown when Insert mode is left.
            if state.leave_cursor and in_insert_mode() then
                return
            end
            state.leave_cursor = nil

            show(bufnr, state)
        end)
    end)
end

local function apply()
    local bufnr = api.nvim_get_current_buf()
    local state = get_state(bufnr)

    -- A held prediction has not been shown yet, so there is nothing to apply.
    if not state.proposed_lines or not state.range or not state.proposed_cursor or state.leave_cursor then
        utils.notify('No Minuet duet prediction to apply.', 'warn', vim.log.levels.WARN)
        return
    end

    if utils.get_changedtick(bufnr) ~= state.changedtick then
        clear_state(bufnr, state)
        utils.notify('Minuet duet prediction is stale and has been discarded.', 'warn', vim.log.levels.WARN)
        return
    end

    local prefetch = state.prefetch
    state.prefetch = nil

    api.nvim_buf_set_lines(bufnr, state.range.start_row, state.range.end_row, false, state.proposed_lines)

    local target_row = state.range.start_row + state.proposed_cursor.row_offset + 1
    local target_line = api.nvim_buf_get_lines(bufnr, target_row - 1, target_row, false)[1] or ''
    local target_col = math.min(state.proposed_cursor.col, #target_line)

    api.nvim_win_set_cursor(0, { target_row, target_col })

    clear_state(bufnr, state)

    -- The prefetch was made for this buffer text and cursor: show it now or
    -- when it arrives, instead of predicting again after the text change.
    if prefetch and vim.deep_equal(prefetch.cursor, { target_row, target_col }) then
        prefetch.applied_tick = utils.get_changedtick(bufnr)
        state.prefetch = prefetch
        state.skip_tick = prefetch.applied_tick
        if prefetch.done then
            use_prefetch(bufnr, state)
        end
    elseif prefetch and not prefetch.done then
        common.terminate_prefetch_jobs()
    end
end

local function dismiss()
    stop_timer()
    local bufnr = api.nvim_get_current_buf()
    clear_state(bufnr, get_state(bufnr))
end

---Debounced automatic prediction: each text change restarts the timer, so a
---prediction only fires after the configured idle gap. The guards run at
---fire time because the buffer, mode, or completion menu may have changed
---during the delay.
---@param bufnr integer
---@param delay? integer milliseconds; defaults to auto_trigger.debounce, or insert_mode_debounce for a prediction held in Insert mode
local function schedule(bufnr, delay)
    stop_timer()

    local config = require('minuet').config
    local auto_trigger = config.duet.auto_trigger
    if not delay and auto_trigger.hold_in_insert_mode and in_insert_mode() then
        delay = auto_trigger.insert_mode_debounce
    end

    internal.timer = vim.defer_fn(function()
        local hold = config.duet.auto_trigger.hold_in_insert_mode and in_insert_mode()
        -- A held prediction shows nothing, so the completion menu does not
        -- stop it.
        if
            bufnr ~= api.nvim_get_current_buf()
            or not api.nvim_buf_is_loaded(bufnr)
            or vim.bo[bufnr].buftype ~= ''
            or not vim.bo[bufnr].modifiable
            or (not hold and shared_utils.completion_menu_visible())
            or not shared_utils.run_hooks_until_failure(config.duet.auto_trigger.enable_predicates)
        then
            return
        end

        -- A held prediction waits for a running inline completion request.
        if hold and #require('minuet.backends.common').current_jobs > 0 then
            schedule(bufnr, 50)
            return
        end

        predict {
            flush_timeout = config.duet.auto_trigger.flush_timeout,
            hold = hold,
        }
    end, delay or auto_trigger.debounce)
end

---@param info { buf: integer }
local function on_text_changed(info)
    local state = internal.states[info.buf]
    -- The change apply made when it used a prefetched prediction.
    if state and state.skip_tick == api.nvim_buf_get_changedtick(info.buf) then
        return
    end
    if state then
        -- The running request's answer would be discarded; stop it so it
        -- does not keep the server busy.
        if state.pending_seq then
            common.terminate_all_jobs()
        end
        clear_state(info.buf, state)
    end

    if vim.b[info.buf].minuet_duet_auto_trigger then
        schedule(info.buf)
    end
end

local action = {
    predict = predict,
    apply = apply,
    dismiss = dismiss,
    is_visible = function()
        local bufnr = api.nvim_get_current_buf()
        local state = get_state(bufnr)
        return preview.is_visible(bufnr, state)
    end,
    enable_auto_trigger = function()
        vim.b.minuet_duet_auto_trigger = true
        vim.notify('Minuet Duet auto trigger enabled', vim.log.levels.INFO)
    end,
    disable_auto_trigger = function()
        vim.b.minuet_duet_auto_trigger = false
        vim.notify('Minuet Duet auto trigger disabled', vim.log.levels.INFO)
    end,
    toggle_auto_trigger = function()
        vim.b.minuet_duet_auto_trigger = not vim.b.minuet_duet_auto_trigger
        vim.notify(
            'Minuet Duet auto trigger ' .. (vim.b.minuet_duet_auto_trigger and 'enabled' or 'disabled'),
            vim.log.levels.INFO
        )
    end,
}

M.action = action

function M.setup()
    api.nvim_clear_autocmds { group = M.augroup }

    local config = require('minuet').config
    if #config.duet.auto_trigger.auto_trigger_ft > 0 then
        api.nvim_create_autocmd('FileType', {
            pattern = config.duet.auto_trigger.auto_trigger_ft,
            callback = function()
                if not vim.tbl_contains(config.duet.auto_trigger.auto_trigger_ignore_ft, vim.bo.ft) then
                    vim.b.minuet_duet_auto_trigger = true
                end
            end,
            group = M.augroup,
            desc = '[minuet.duet] filetype auto trigger',
        })
    end

    api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
        group = M.augroup,
        callback = on_text_changed,
        desc = '[minuet.duet] clear preview and schedule auto trigger on text change',
    })

    -- Leaving Insert mode fires no TextChanged. When the debounce ran out
    -- while still typing and enable_predicates allow only Normal mode, the
    -- edit would never get a prediction, so schedule one on InsertLeave if
    -- the insert changed the buffer.
    api.nvim_create_autocmd('InsertEnter', {
        group = M.augroup,
        callback = function(info)
            internal.insert_ticks[info.buf] = api.nvim_buf_get_changedtick(info.buf)
        end,
        desc = '[minuet.duet] remember the changedtick on insert enter',
    })

    api.nvim_create_autocmd('InsertLeave', {
        group = M.augroup,
        callback = function(info)
            local tick = internal.insert_ticks[info.buf]
            internal.insert_ticks[info.buf] = nil

            -- A prediction held from Insert mode: show it, or let it show on
            -- arrival, if it was made for this buffer text and cursor.
            local state = internal.states[info.buf]
            if state and state.leave_cursor then
                if
                    state.request_tick == api.nvim_buf_get_changedtick(info.buf)
                    and vim.deep_equal(state.leave_cursor, api.nvim_win_get_cursor(0))
                then
                    state.leave_cursor = nil
                    if state.proposed_lines then
                        show(info.buf, state)
                    end
                    return
                end
                if state.pending_seq then
                    common.terminate_all_jobs()
                end
                clear_state(info.buf, state)
            end

            if tick and tick ~= api.nvim_buf_get_changedtick(info.buf) and vim.b[info.buf].minuet_duet_auto_trigger then
                schedule(info.buf)
            end
        end,
        desc = '[minuet.duet] schedule auto trigger after an insert that changed text',
    })

    api.nvim_create_autocmd('BufLeave', {
        group = M.augroup,
        callback = function(info)
            local state = internal.states[info.buf]
            if state then
                discard_prefetch(state)
            end
        end,
        desc = '[minuet.duet] discard the prefetched prediction on leaving the buffer',
    })

    api.nvim_create_autocmd('BufWipeout', {
        group = M.augroup,
        callback = function(info)
            local state = internal.states[info.buf]
            if state then
                discard_prefetch(state)
            end
            internal.states[info.buf] = nil
            internal.insert_ticks[info.buf] = nil
        end,
        desc = '[minuet.duet] clear state on buf wipeout',
    })

    edits.setup()
end

return M
