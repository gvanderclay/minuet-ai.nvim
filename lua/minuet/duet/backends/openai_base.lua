local common = require 'minuet.duet.backends.common'
local utils = require 'minuet.duet.utils'

local M = {}

function M.openai_get_text_fn_stream(json)
    return json.choices[1].delta.content
end

function M.complete_openai_base(options, context, callback)
    common.terminate_all_jobs()

    local system = utils.make_system_prompt(options.system)
    local prompt = utils.make_duet_llm_shot(context, options.chat_input)
    local messages = vim.deepcopy(utils.get_or_eval_value(options.few_shots) or {})

    table.insert(messages, 1, { role = 'system', content = system })
    table.insert(messages, { role = 'user', content = prompt })

    local data = {
        model = options.model,
        messages = messages,
        stream = true,
    }

    local headers = {
        ['Content-Type'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. utils.get_api_key(options.api_key),
    }

    M.send_request(options, data, headers, function(result, data_file)
        return utils.stream_decode(result, data_file, options.name, M.openai_get_text_fn_stream)
    end, callback)
end

---Send one JSON request with curl and call `callback` with the decoded text.
---@param options table provider options (end_point, optional, transform, provider, name, model)
---@param data table request body, merged with `options.optional`
---@param headers table<string, string>
---@param decode fun(result: vim.SystemCompleted, data_file: string): string? turns the curl result into text and deletes `data_file`
---@param callback fun(text: string?)
---@param opts? { prefetch?: boolean } prefetch tracks the request in common.prefetch_jobs
function M.send_request(options, data, headers, decode, callback, opts)
    local root_config = require('minuet').config
    local duet_config = root_config.duet

    data = vim.tbl_deep_extend('force', data, options.optional or {})
    local transformed_data = common.apply_transforms(options.transform, options.end_point, headers, data)
    local data_file = utils.make_tmp_file(transformed_data.body)

    if not data_file then
        callback(nil)
        return
    end

    local args = utils.make_curl_args(
        transformed_data.end_point,
        transformed_data.headers,
        data_file,
        duet_config.request_timeout
    )

    local timestamp = os.time()
    utils.run_event('MinuetDuetRequestStartedPre', {
        provider = options.provider,
        name = options.name,
        model = options.model,
        n_requests = 1,
        timestamp = timestamp,
    })

    local job = common.start_job(root_config.curl_cmd, args, {
        prefetch = opts and opts.prefetch,
        on_exit = function(_, result)
            utils.run_event('MinuetDuetRequestFinished', {
                provider = options.provider,
                name = options.name,
                model = options.model,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })

            callback(decode(result, data_file))
        end,
        on_spawn_error = function()
            vim.uv.fs_unlink(data_file)
            utils.run_event('MinuetDuetRequestFinished', {
                provider = options.provider,
                name = options.name,
                model = options.model,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })
            callback(nil)
        end,
    })

    if not job then
        return
    end

    utils.run_event('MinuetDuetRequestStarted', {
        provider = options.provider,
        name = options.name,
        model = options.model,
        n_requests = 1,
        request_idx = 1,
        timestamp = timestamp,
    })
end

return M
