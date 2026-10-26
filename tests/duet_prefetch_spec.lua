local helpers = require 'tests.helpers'

-- The auto trigger and the edit recorder only work in normal file buffers;
-- helpers.create_buffer makes scratch buffers, so clear the buftype.
local function create_normal_buffer(lines, cursor)
    local bufnr = helpers.create_buffer(lines, cursor)
    vim.bo[bufnr].buftype = ''
    return bufnr
end

local function pause(ms)
    vim.wait(ms, function()
        return false
    end, 10)
end

local function response(line)
    return '<editable_region>\n' .. line .. '<cursor_position/>\n</editable_region>'
end

local function setup(extra)
    helpers.setup_root_config {
        duet = vim.tbl_deep_extend('force', {
            provider = 'test',
            prefetch = true,
            auto_trigger = { debounce = 20 },
            editable_region = { lines_before = 0, lines_after = 0 },
        }, extra or {}),
    }

    local backend = { calls = {} }
    package.loaded['minuet.duet.backends.test'] = {
        complete = function(context, callback, opts)
            table.insert(backend.calls, { context = context, callback = callback, prefetch = opts and opts.prefetch })
        end,
    }

    local duet = helpers.reload 'minuet.duet'
    duet.setup()
    return duet, backend
end

---Requests other than prefetches.
local function count_predictions(backend)
    local n = 0
    for _, call in ipairs(backend.calls) do
        if not call.prefetch then
            n = n + 1
        end
    end
    return n
end

---Predict 'local value = 2' and show it; the prefetch is then calls[2].
local function show_first(duet, backend)
    duet.action.predict()
    backend.calls[1].callback(response 'local value = 2')
    helpers.wait_until(function()
        return duet.action.is_visible()
    end, 1000, 'the first prediction was not shown')
    helpers.expect_equal(#backend.calls, 2, 'showing a prediction did not prefetch the next one')
    helpers.expect_truthy(backend.calls[2].prefetch, 'the second request is not a prefetch')
end

---A stand-in for a running prefetch request.
local function fake_prefetch_job()
    local job = { pid = -1, killed = false }
    function job.kill()
        job.killed = true
    end
    require('minuet.duet.backends.common').prefetch_jobs = { job }
    return job
end

return {
    {
        name = 'duet prefetch predicts from the buffer as applying will leave it, with the edit in the history',
        run = function()
            local duet, backend = setup { recent_edits = { enabled = true } }
            local bufnr = create_normal_buffer({ 'local value = 1' }, { 1, 0 })
            require('minuet.duet.edits').track(bufnr)

            show_first(duet, backend)

            local prefetch_context = backend.calls[2].context
            helpers.expect_equal(prefetch_context.original_lines, { 'local value = 2' })
            helpers.expect_equal(prefetch_context.editable_region_before_cursor, 'local value = 2')
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local value = 1' })

            local events = prefetch_context.recent_events
            helpers.expect_truthy(events and #events > 0, 'the prefetch has no edit history')
            helpers.expect_match(events[#events].diff, '%+local value = 2')
            helpers.expect_equal(#require('minuet.duet.edits').get_events(), 0, 'the stored history changed')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet prefetch shows the next prediction as soon as apply runs',
        run = function()
            local duet, backend = setup()
            local bufnr = create_normal_buffer({ 'local value = 1' }, { 1, 0 })
            duet.action.enable_auto_trigger()

            show_first(duet, backend)
            backend.calls[2].callback(response 'local value = 3')
            pause(20)

            duet.action.apply()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local value = 2' })
            helpers.expect_truthy(duet.action.is_visible(), 'apply did not show the prefetched prediction')

            -- The text change apply made must neither clear it nor predict again.
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr, modeline = false })
            pause(80)
            helpers.expect_truthy(duet.action.is_visible(), 'the text change from apply cleared the prediction')
            helpers.expect_equal(count_predictions(backend), 1, 'apply predicted again despite the prefetch')
            helpers.expect_truthy(backend.calls[3] and backend.calls[3].prefetch, 'the shown prefetch did not prefetch')

            duet.action.apply()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local value = 3' })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet prefetch still running at apply is shown when it arrives',
        run = function()
            local duet, backend = setup()
            local bufnr = create_normal_buffer({ 'local value = 1' }, { 1, 0 })
            duet.action.enable_auto_trigger()

            show_first(duet, backend)
            duet.action.apply()
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr, modeline = false })
            pause(80)
            helpers.expect_falsy(duet.action.is_visible())
            helpers.expect_equal(count_predictions(backend), 1, 'apply predicted again instead of waiting')

            backend.calls[2].callback(response 'local value = 3')
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'the prefetch did not show when it arrived')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet prefetch is stopped by dismiss and its late answer never shows',
        run = function()
            local duet, backend = setup()
            local bufnr = create_normal_buffer({ 'local value = 1' }, { 1, 0 })

            show_first(duet, backend)
            local job = fake_prefetch_job()
            duet.action.dismiss()
            helpers.expect_truthy(job.killed, 'dismiss did not stop the prefetch')

            backend.calls[2].callback(response 'local value = 3')
            pause(50)
            helpers.expect_falsy(duet.action.is_visible(), 'a dismissed prefetch rendered')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet prefetch is stopped by another edit, a new prediction, or leaving the buffer',
        run = function()
            local duet, backend = setup()
            local bufnr = create_normal_buffer({ 'local value = 1' }, { 1, 0 })

            -- Another edit.
            show_first(duet, backend)
            local job = fake_prefetch_job()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local other = 1' })
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr, modeline = false })
            helpers.expect_truthy(job.killed, 'an edit did not stop the prefetch')
            backend.calls[2].callback(response 'local value = 3')
            pause(50)
            helpers.expect_falsy(duet.action.is_visible(), 'a prefetch rendered after another edit')

            -- A new prediction.
            backend.calls = {}
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local value = 1' })
            show_first(duet, backend)
            job = fake_prefetch_job()
            duet.action.predict()
            helpers.expect_truthy(job.killed, 'a new prediction did not stop the prefetch')

            -- Leaving the buffer.
            backend.calls = {}
            show_first(duet, backend)
            job = fake_prefetch_job()
            local other = helpers.create_buffer { 'other' }
            helpers.expect_truthy(job.killed, 'leaving the buffer did not stop the prefetch')
            vim.api.nvim_set_current_buf(bufnr)
            backend.calls[2].callback(response 'local value = 3')
            pause(50)
            duet.action.apply()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'local value = 2' })
            pause(20)
            helpers.expect_falsy(duet.action.is_visible(), 'a prefetch discarded on leaving the buffer rendered')

            helpers.delete_buffer(other)
            helpers.delete_buffer(bufnr)
        end,
    },
}
