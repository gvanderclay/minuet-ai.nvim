local M = {}

M.current_jobs = {}
-- Requests for the prediction after a shown one; terminate_all_jobs leaves
-- them running.
M.prefetch_jobs = {}

---@param list_name 'current_jobs'|'prefetch_jobs'
local function remove_job(list_name, job)
    for index, current_job in ipairs(M[list_name]) do
        if current_job.pid == job.pid then
            table.remove(M[list_name], index)
            break
        end
    end
end

---@param list_name 'current_jobs'|'prefetch_jobs'
local function terminate_jobs(list_name)
    for _, job in ipairs(M[list_name]) do
        pcall(job.kill, job, 'sigterm')
    end

    M[list_name] = {}
end

function M.terminate_all_jobs()
    terminate_jobs 'current_jobs'
end

function M.terminate_prefetch_jobs()
    terminate_jobs 'prefetch_jobs'
end

---@param handlers { on_exit: fun(job: vim.SystemObj, out: vim.SystemCompleted), on_spawn_error?: fun(), prefetch?: boolean } prefetch tracks the job in prefetch_jobs
function M.start_job(command, args, handlers)
    local list_name = handlers.prefetch and 'prefetch_jobs' or 'current_jobs'
    local cmd = { command }
    vim.list_extend(cmd, args)

    local job
    local ok, result = pcall(
        vim.system,
        cmd,
        { text = true },
        vim.schedule_wrap(function(out)
            if not job then
                return
            end

            remove_job(list_name, job)
            handlers.on_exit(job, out)
        end)
    )

    if not ok then
        if handlers.on_spawn_error then
            handlers.on_spawn_error()
        end
        return nil
    end

    job = result
    table.insert(M[list_name], job)

    return job
end

function M.apply_transforms(transform, end_point, headers, body)
    local transformed_data = {
        end_point = end_point,
        headers = headers,
        body = body,
    }

    for _, fun in ipairs(transform or {}) do
        transformed_data = fun(transformed_data)
    end

    return transformed_data
end

return M
