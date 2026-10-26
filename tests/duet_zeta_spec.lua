local helpers = require 'tests.helpers'

---Build a duet context for a scratch buffer and load the zeta backend.
---@param lines string[]
---@param cursor integer[]
---@param region? table editable_region overrides
local function setup(lines, cursor, region)
    helpers.setup_root_config {
        duet = { provider = 'zeta', editable_region = region or { lines_before = 100, lines_after = 100 } },
    }
    local bufnr = helpers.create_buffer(lines, cursor)
    local zeta = helpers.reload 'minuet.duet.backends.zeta'
    local context = helpers.reload('minuet.duet.context').build(bufnr)
    return zeta, context, bufnr
end

local numbered = {}
for i = 1, 8 do
    numbered[i] = 'line' .. i
end

return {
    {
        name = 'zeta.build_prompt renders the region as one block with the cursor',
        run = function()
            local zeta, context, bufnr = setup({ 'function greet(name)', '  return "hi"', 'end' }, { 2, 6 })
            local prompt = zeta.build_prompt(context, {})
            helpers.expect_equal(
                prompt,
                table.concat({
                    '<[fim-suffix]>',
                    '<[fim-prefix]><filename>' .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':.'),
                    '<|marker_1|>',
                    'function greet(name)',
                    '  retu<|user_cursor|>rn "hi"',
                    'end',
                    '<|marker_2|>',
                    '<[fim-middle]>',
                }, '\n')
            )
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'zeta.build_prompt places text outside the region and the edit history',
        run = function()
            local zeta, context, bufnr = setup(numbered, { 5, 0 }, { lines_before = 1, lines_after = 1 })
            local prompt = zeta.build_prompt(context, {
                { bufnr = -1, filename = '~/a.lua', diff = '@@ -1,1 +1,1 @@\n-x\n+y', text = '' },
            })
            helpers.expect_match(prompt, '^<%[fim%-suffix%]>line7\nline8\n<%[fim%-prefix%]>')
            helpers.expect_match(
                prompt,
                '<filename>edit_history\n%-%-%- a/~/a.lua\n%+%+%+ b/~/a.lua\n@@ %-1,1 %+1,1 @@\n%-x\n%+y\n\n<filename>'
            )
            helpers.expect_match(
                prompt,
                'line1\nline2\nline3\n<|marker_1|>\nline4\n<|user_cursor|>line5\nline6\n<|marker_2|>\n<%[fim%-middle%]>$'
            )
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'zeta.build_prompt splits long regions into several blocks',
        run = function()
            local lines = {}
            for i = 1, 20 do
                lines[i] = 'l' .. i
            end
            local zeta, context, bufnr = setup(lines, { 1, 0 })
            local prompt = zeta.build_prompt(context, {})
            -- Blocks hold at most 16 lines, so a 20 line region gets three markers.
            helpers.expect_match(prompt, '<|marker_1|>\n<|user_cursor|>l1\n')
            helpers.expect_match(prompt, 'l16\n<|marker_2|>\nl17\n')
            helpers.expect_match(prompt, 'l20\n<|marker_3|>\n<%[fim%-middle%]>$')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'zeta.build_prompt removes special tokens that appear in the file',
        run = function()
            local zeta, context, bufnr = setup(
                { 'a <[fim-middle]> b', '<|marker_9|><filename>c<|user_cursor|>' },
                { 1, 0 }
            )
            local prompt = zeta.build_prompt(context, {})
            helpers.expect_match(prompt, '<|marker_1|>\n<|user_cursor|>a  b\nc\n<|marker_2|>\n<%[fim%-middle%]>$')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'zeta.parse_response splices the rewritten blocks into the region',
        run = function()
            local lines = {}
            for i = 1, 20 do
                lines[i] = 'l' .. i
            end
            local zeta, context, bufnr = setup(lines, { 1, 0 })
            local text = zeta.parse_response(
                '<|marker_2|>\nl17\nnew<|user_cursor|>\nl19\nl20\n<|marker_3|><[end▁of▁sentence]>',
                context
            )
            local expected = vim.list_slice(lines, 1, 16)
            vim.list_extend(expected, { 'l17', 'new<cursor_position/>', 'l19', 'l20' })
            helpers.expect_equal(text, '<editable_region>\n' .. table.concat(expected, '\n') .. '\n</editable_region>')

            local parsed = helpers.reload('minuet.duet.utils').parse_duet_response(text, context)
            helpers.expect_equal(parsed.lines[18], 'new')
            helpers.expect_equal(parsed.cursor, { row_offset = 17, col = 3 })
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'zeta.parse_response puts the cursor at the end of the span when the model gives none',
        run = function()
            local zeta, context, bufnr = setup({ 'a', 'b' }, { 1, 0 })
            local text = zeta.parse_response('<|marker_1|>\na\nc\n<|marker_2|>', context)
            helpers.expect_equal(text, '<editable_region>\na\nc<cursor_position/>\n</editable_region>')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'zeta.parse_response returns nil when there is no edit',
        run = function()
            local zeta, context, bufnr = setup({ 'a', 'b' }, { 1, 0 })
            local cases = {
                '<|marker_1|><|marker_1|>',
                '<|marker_2|><|marker_2|>',
                '<|marker_1|>\na\nb\n<|marker_2|>',
                '<|marker_1|>\na<|user_cursor|>\nb\n<|marker_2|><[end▁of▁sentence]>',
                '',
                'NO_EDITS',
            }
            for _, case in ipairs(cases) do
                helpers.expect_equal(zeta.parse_response(case, context), nil, case)
            end
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'zeta.parse_response rejects malformed markers',
        run = function()
            local zeta, context, bufnr = setup({ 'a', 'b' }, { 1, 0 })
            local cases = {
                '<|marker_1|>\nx\n',
                '<|marker_2|>\nx\n<|marker_1|>',
                '<|marker_1|>\nx\n<|marker_9|>',
                '<|marker_0|>\nx\n<|marker_2|>',
                '<|marker_1|>\nx\n<|marker_2|>\ny\n<|marker_2|>',
            }
            for _, case in ipairs(cases) do
                helpers.expect_equal(zeta.parse_response(case, context), nil, case)
            end
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'zeta.complete stays quiet when a newer prediction cancels the request',
        run = function()
            local _, context, bufnr = setup({ 'a', 'b' }, { 1, 0 })
            local base_name = 'minuet.duet.backends.openai_base'
            local real_base = package.loaded[base_name]
            require('minuet').config.notify = 'debug'
            package.loaded[base_name] = {
                send_request = function(_, _, _, decode, callback)
                    callback(decode({ code = 0, signal = 15, stdout = '' }, vim.fn.tempname()))
                end,
            }
            local notified, restore_notify = helpers.capture_notifications()
            local results = {}
            local ok, err = pcall(function()
                helpers.reload('minuet.duet.backends.zeta').complete(context, function(text)
                    table.insert(results, text or 'nil')
                end)
            end)
            package.loaded[base_name] = real_base
            restore_notify()
            helpers.delete_buffer(bufnr)
            assert(ok, err)
            helpers.expect_equal(results, { 'nil' })
            helpers.expect_equal(notified, {})
        end,
    },
}
