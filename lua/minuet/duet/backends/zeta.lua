local base = require 'minuet.duet.backends.openai_base'
local common = require 'minuet.duet.backends.common'
local shared_utils = require 'minuet.utils'
local utils = require 'minuet.duet.utils'

-- Backend for Zeta-2.1, served through a raw completion endpoint such as
-- llama-server's `/v1/completions`. The editable region is split into
-- numbered blocks; the model returns a span of blocks between two numbered
-- markers, which is spliced back into the region.

local M = {}

local EOS = '<[end▁of▁sentence]>'
local USER_CURSOR = '<|user_cursor|>'
local MIN_BLOCK_LINES = 6
local MAX_BLOCK_LINES = 16

-- Tokens that have a meaning in the prompt; they are removed from file text.
local special_tokens = { '<[fim-suffix]>', '<[fim-prefix]>', '<[fim-middle]>', '<filename>', USER_CURSOR, EOS }

---@param text string
---@return string
local function sanitize(text)
    for _, token in ipairs(special_tokens) do
        text = shared_utils.replace_string_literal(text, token, '')
    end
    return (text:gsub('<|marker_%d+|>', ''))
end

---Number of lines before each marker. The first entry is 0 and the last is
---`#lines`. A block starts at a non-blank line that follows a blank line once
---the current block has at least MIN_BLOCK_LINES lines, and never grows past
---MAX_BLOCK_LINES lines.
---@param lines string[]
---@return integer[]
local function marker_boundaries(lines)
    local boundaries = { 0 }
    local last = 0
    for i = 1, #lines - 1 do
        local gap = i - last
        local at_paragraph_start = lines[i]:match '^%s*$' == nil
            and lines[i - 1] ~= nil
            and lines[i - 1]:match '^%s*$' ~= nil
        local enough_left = #lines - i >= MIN_BLOCK_LINES
        if gap >= MAX_BLOCK_LINES or (gap >= MIN_BLOCK_LINES and at_paragraph_start and enough_left) then
            table.insert(boundaries, i)
            last = i
        end
    end
    table.insert(boundaries, #lines)
    return boundaries
end

---Build the completion prompt.
---@param context minuet.DuetContext
---@param events minuet.DuetEditEvent[] recent edits, oldest first
---@return string
function M.build_prompt(context, events)
    local lines = context.original_lines
    local boundaries = marker_boundaries(lines)

    local after = sanitize(context.non_editable_region_after)
    local parts = { '<[fim-suffix]>', after }
    if after == '' or after:sub(-1) ~= '\n' then
        table.insert(parts, '\n')
    end
    table.insert(parts, '<[fim-prefix]>')

    local diffs = {}
    for _, event in ipairs(events) do
        local name = event.filename
        if vim.api.nvim_buf_is_valid(event.bufnr) and vim.api.nvim_buf_get_name(event.bufnr) ~= '' then
            name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(event.bufnr), ':.')
        end
        table.insert(diffs, ('--- a/%s\n+++ b/%s\n%s\n'):format(name, name, sanitize(event.diff)))
    end
    if #diffs > 0 then
        table.insert(parts, '<filename>edit_history\n' .. table.concat(diffs, '\n') .. '\n')
    end

    local file_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(context.bufnr), ':.')
    table.insert(parts, '<filename>' .. sanitize(file_name) .. '\n')

    if context.non_editable_region_before ~= '' then
        table.insert(parts, sanitize(context.non_editable_region_before) .. '\n')
    end

    local before_cursor = vim.split(context.editable_region_before_cursor, '\n', { plain = true })
    local cursor_row = #before_cursor
    local cursor_col = #before_cursor[cursor_row]

    for block = 1, #boundaries - 1 do
        table.insert(parts, ('<|marker_%d|>\n'):format(block))
        for row = boundaries[block] + 1, boundaries[block + 1] do
            local line = sanitize(lines[row])
            if row == cursor_row then
                -- Sanitizing can shorten the line, so clamp the column.
                local col = math.min(cursor_col, #line)
                line = line:sub(1, col) .. USER_CURSOR .. line:sub(col + 1)
            end
            table.insert(parts, line .. '\n')
        end
    end

    table.insert(parts, ('<|marker_%d|>\n<[fim-middle]>'):format(#boundaries))
    return table.concat(parts)
end

---Turn the model output into a response for `utils.parse_duet_response`, or
---return nil when the model proposes no change.
---@param text string
---@param context minuet.DuetContext
---@return string?
function M.parse_response(text, context)
    local eos = text:find(EOS, 1, true)
    if eos then
        text = text:sub(1, eos - 1)
    end

    -- The answer spans blocks from its first marker to its last. When it
    -- covers several blocks it may repeat the markers between them; those
    -- must increase and are dropped.
    local hits = {}
    local search_from = 1
    while true do
        local s, e, number = text:find('<|marker_(%d+)|>', search_from)
        if not s then
            break
        end
        table.insert(hits, { start = s, finish = e, number = tonumber(number) })
        search_from = e + 1
    end
    if #hits < 2 then
        return nil
    end
    for i = 2, #hits do
        if hits[i].number <= hits[i - 1].number then
            return nil
        end
    end

    local boundaries = marker_boundaries(context.original_lines)
    local first = hits[1].number --[[@as integer]]
    local second = hits[#hits].number --[[@as integer]]
    if first < 1 or second > #boundaries then
        return nil
    end

    local inner = {}
    for i = 1, #hits - 1 do
        local piece = text:sub(hits[i].finish + 1, hits[i + 1].start - 1)
        if i > 1 then
            piece = piece:gsub('^\r?\n', '')
        end
        table.insert(inner, piece)
    end

    local replacement = table.concat(inner):gsub('^\r?\n', '')
    replacement = replacement:gsub('\r?\n$', '')
    local markers = require('minuet').config.duet.markers

    local function splice(span_text)
        local lines = vim.list_slice(context.original_lines, 1, boundaries[first])
        if span_text ~= '' then
            vim.list_extend(lines, vim.split(span_text, '\n', { plain = true }))
        end
        vim.list_extend(lines, vim.list_slice(context.original_lines, boundaries[second] + 1))
        return lines
    end

    local without_cursor = shared_utils.replace_string_literal(replacement, USER_CURSOR, '')
    if vim.deep_equal(splice(without_cursor), context.original_lines) then
        return nil
    end

    -- Without a cursor from the model, put it at the end of the rewritten span.
    local with_cursor = shared_utils.replace_string_literal(replacement, USER_CURSOR, markers.cursor_position)
    if not replacement:find(USER_CURSOR, 1, true) and replacement ~= '' then
        with_cursor = with_cursor .. markers.cursor_position
    end

    return table.concat(
        { markers.editable_region_start, table.concat(splice(with_cursor), '\n'), markers.editable_region_end },
        '\n'
    )
end

---@param context minuet.DuetContext
---@param callback fun(text: string?)
---@param opts? { prefetch?: boolean } prefetch leaves running requests alone and is tracked in common.prefetch_jobs
function M.complete(context, callback, opts)
    local options = vim.deepcopy(require('minuet').config.duet.provider_options.zeta)
    options.provider = 'zeta'
    options.name = options.name or 'Zeta'

    if not (opts and opts.prefetch) then
        common.terminate_all_jobs()
    end

    local events = {}
    if require('minuet').config.duet.recent_edits.enabled then
        events = context.recent_events or require('minuet.duet.edits').get_events()
    end

    local data = {
        model = options.model,
        prompt = M.build_prompt(context, events),
        temperature = 0,
        max_tokens = 2048,
        stop = { EOS },
        stream = false,
    }

    base.send_request(options, data, { ['Content-Type'] = 'application/json' }, function(result, data_file)
        vim.uv.fs_unlink(data_file)

        -- A newer prediction cancelled this request; nothing to report.
        if (result.signal or 0) ~= 0 then
            return
        end

        if result.code ~= 0 then
            utils.notify(
                string.format('Zeta request failed with exit code %d', result.code),
                'error',
                vim.log.levels.ERROR
            )
            return
        end

        local ok, json = pcall(vim.json.decode, result.stdout or '')
        local choice = ok and type(json) == 'table' and json.choices and json.choices[1]
        if not choice or type(choice.text) ~= 'string' then
            utils.notify(
                'Zeta returned an unexpected response: ' .. (result.stdout or ''),
                'error',
                vim.log.levels.ERROR
            )
            return
        end

        -- A truncated answer has no closing marker and is rejected by parse_response.
        local response = M.parse_response(choice.text, context)
        if not response then
            utils.notify('Zeta proposed no edit.', 'verbose', vim.log.levels.INFO)
        end
        return response
    end, callback, opts)
end

return M
