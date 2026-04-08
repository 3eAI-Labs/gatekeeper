--
-- aria-provider.lua — LLM Provider transformation registry
--
-- Transforms canonical (OpenAI-compatible) requests to provider-specific formats
-- and provider responses back to OpenAI format.
--
-- Business Rules: BR-SH-001 (transformation), BR-SH-004 (OpenAI compatibility)
-- User Stories: US-A01 (multi-provider), US-A04 (SDK compatibility)
--

local cjson = require("cjson.safe")
local ngx = ngx
local str_format = string.format

local _M = {
    version = "0.1.0",
}

-- ────────────────────────────────────────────────────────────────────────────
-- Anthropic stop_reason → OpenAI finish_reason mapping (BR-SH-004)
-- ────────────────────────────────────────────────────────────────────────────
local ANTHROPIC_STOP_MAP = {
    end_turn       = "stop",
    max_tokens     = "length",
    stop_sequence  = "stop",
    tool_use       = "tool_calls",
}

-- Google finish_reason mapping
local GOOGLE_FINISH_MAP = {
    STOP           = "stop",
    MAX_TOKENS     = "length",
    SAFETY         = "content_filter",
    RECITATION     = "content_filter",
}


-- ────────────────────────────────────────────────────────────────────────────
-- Provider Registry
-- ────────────────────────────────────────────────────────────────────────────

local providers = {}


-- ═══════════════════════════════════════════════════════════════════════════
-- OpenAI — pass-through (canonical format)
-- ═══════════════════════════════════════════════════════════════════════════
providers.openai = {
    name = "openai",

    build_url = function(conf)
        return conf.endpoint or "https://api.openai.com/v1/chat/completions"
    end,

    build_headers = function(conf)
        return {
            ["Authorization"] = "Bearer " .. (conf.api_key or ""),
            ["Content-Type"]  = "application/json",
        }
    end,

    transform_request = function(body, conf)
        return body  -- Already in canonical format
    end,

    transform_response = function(body_str, conf)
        return body_str, nil  -- Pass through
    end,

    transform_sse_chunk = function(chunk, conf)
        return chunk  -- Already OpenAI SSE format
    end,

    map_error = function(status, body, conf)
        -- OpenAI errors are already in the expected format
        return status, body
    end,
}


-- ═══════════════════════════════════════════════════════════════════════════
-- Anthropic — Messages API
-- BR-SH-001: OpenAI → Anthropic request transformation
-- BR-SH-004: Anthropic → OpenAI response transformation
-- ═══════════════════════════════════════════════════════════════════════════
providers.anthropic = {
    name = "anthropic",

    build_url = function(conf)
        return conf.endpoint or "https://api.anthropic.com/v1/messages"
    end,

    build_headers = function(conf)
        return {
            ["x-api-key"]          = conf.api_key or "",
            ["anthropic-version"]  = conf.api_version or "2023-06-01",
            ["Content-Type"]       = "application/json",
        }
    end,

    --- Transform OpenAI-format request to Anthropic Messages API.
    -- Extracts system messages to top-level "system" field.
    -- Sets max_tokens default to 4096 (required by Anthropic).
    transform_request = function(body, conf)
        local system_parts = {}
        local messages = {}

        for _, msg in ipairs(body.messages or {}) do
            if msg.role == "system" then
                system_parts[#system_parts + 1] = msg.content
            else
                messages[#messages + 1] = {
                    role = msg.role,
                    content = msg.content,
                }
            end
        end

        local request = {
            model      = body.model,
            messages   = messages,
            max_tokens = body.max_tokens or 4096,
            stream     = body.stream,
        }

        if #system_parts > 0 then
            request.system = table.concat(system_parts, "\n")
        end

        -- Optional parameters
        if body.temperature then request.temperature = body.temperature end
        if body.top_p then request.top_p = body.top_p end
        if body.stop then request.stop_sequences = body.stop end

        return request
    end,

    --- Transform Anthropic response to OpenAI format.
    transform_response = function(body_str, conf)
        local body, err = cjson.decode(body_str)
        if not body then return nil, err end

        -- Handle Anthropic error responses
        if body.type == "error" then
            local mapped = _M.map_anthropic_error(body)
            return cjson.encode(mapped), nil
        end

        local content = ""
        if body.content and #body.content > 0 then
            for _, block in ipairs(body.content) do
                if block.type == "text" then
                    content = content .. block.text
                end
            end
        end

        local input_tokens = body.usage and body.usage.input_tokens or 0
        local output_tokens = body.usage and body.usage.output_tokens or 0

        local openai_response = {
            id      = body.id or ("chatcmpl-" .. ngx.now()),
            object  = "chat.completion",
            created = ngx.time(),
            model   = body.model or "",
            choices = {
                {
                    index = 0,
                    message = {
                        role    = "assistant",
                        content = content,
                    },
                    finish_reason = ANTHROPIC_STOP_MAP[body.stop_reason] or "stop",
                }
            },
            usage = {
                prompt_tokens     = input_tokens,
                completion_tokens = output_tokens,
                total_tokens      = input_tokens + output_tokens,
            },
        }

        return cjson.encode(openai_response), nil
    end,

    --- Transform Anthropic SSE chunk to OpenAI ChatCompletionChunk format.
    transform_sse_chunk = function(chunk, conf)
        -- Anthropic SSE events: content_block_delta, message_stop, etc.
        local data = chunk:match("^data: (.+)")
        if not data then return chunk end

        local event, err = cjson.decode(data)
        if not event then return chunk end

        if event.type == "content_block_delta" then
            local delta_text = event.delta and event.delta.text or ""
            local openai_chunk = {
                id      = "chatcmpl-stream",
                object  = "chat.completion.chunk",
                created = ngx.time(),
                model   = "",
                choices = {
                    {
                        index = 0,
                        delta = { content = delta_text },
                        finish_reason = cjson.null,
                    }
                },
            }
            return "data: " .. cjson.encode(openai_chunk) .. "\n\n"

        elseif event.type == "message_stop" then
            local openai_chunk = {
                id      = "chatcmpl-stream",
                object  = "chat.completion.chunk",
                created = ngx.time(),
                model   = "",
                choices = {
                    {
                        index = 0,
                        delta = {},
                        finish_reason = "stop",
                    }
                },
            }
            return "data: " .. cjson.encode(openai_chunk) .. "\n\ndata: [DONE]\n\n"

        elseif event.type == "message_delta" and event.usage then
            -- Include usage in the final chunk
            return ""  -- Anthropic sends usage separately; we skip it
        end

        return ""  -- Skip non-content events
    end,

    map_error = function(status, body_str, conf)
        local body = cjson.decode(body_str)
        if not body then return status, body_str end
        return status, cjson.encode(_M.map_anthropic_error(body))
    end,
}


--- Map Anthropic error to OpenAI error format.
function _M.map_anthropic_error(body)
    local err_type = body.error and body.error.type or "unknown"
    local err_msg = body.error and body.error.message or "Unknown Anthropic error"

    local type_map = {
        overloaded_error     = "server_error",
        rate_limit_error     = "rate_limit",
        authentication_error = "authentication_error",
        invalid_request_error = "invalid_request_error",
        not_found_error      = "not_found_error",
    }

    return {
        error = {
            type    = type_map[err_type] or "server_error",
            code    = err_type,
            message = err_msg,
        }
    }
end


-- ═══════════════════════════════════════════════════════════════════════════
-- Google Gemini
-- ═══════════════════════════════════════════════════════════════════════════
providers.google = {
    name = "google",

    build_url = function(conf)
        local model = conf._current_model or "gemini-2.0-flash"
        local base = conf.endpoint or "https://generativelanguage.googleapis.com/v1beta"
        local action = conf._stream and "streamGenerateContent?alt=sse" or "generateContent"
        return str_format("%s/models/%s:%s", base, model, action)
    end,

    build_headers = function(conf)
        return {
            ["Authorization"] = "Bearer " .. (conf.api_key or ""),
            ["Content-Type"]  = "application/json",
        }
    end,

    transform_request = function(body, conf)
        conf._current_model = body.model
        conf._stream = body.stream

        local contents = {}
        local system_instruction

        for _, msg in ipairs(body.messages or {}) do
            if msg.role == "system" then
                system_instruction = { parts = { { text = msg.content } } }
            else
                contents[#contents + 1] = {
                    role  = msg.role == "assistant" and "model" or "user",
                    parts = { { text = msg.content } },
                }
            end
        end

        local request = {
            contents = contents,
            generationConfig = {},
        }

        if system_instruction then
            request.systemInstruction = system_instruction
        end
        if body.temperature then
            request.generationConfig.temperature = body.temperature
        end
        if body.max_tokens then
            request.generationConfig.maxOutputTokens = body.max_tokens
        end
        if body.top_p then
            request.generationConfig.topP = body.top_p
        end

        return request
    end,

    transform_response = function(body_str, conf)
        local body, err = cjson.decode(body_str)
        if not body then return nil, err end

        if body.error then
            return cjson.encode({
                error = {
                    type    = "server_error",
                    code    = tostring(body.error.code),
                    message = body.error.message or "Google API error",
                }
            }), nil
        end

        local content = ""
        local finish_reason = "stop"

        if body.candidates and #body.candidates > 0 then
            local candidate = body.candidates[1]
            if candidate.content and candidate.content.parts then
                for _, part in ipairs(candidate.content.parts) do
                    if part.text then content = content .. part.text end
                end
            end
            if candidate.finishReason then
                finish_reason = GOOGLE_FINISH_MAP[candidate.finishReason] or "stop"
            end
        end

        local input_tokens = 0
        local output_tokens = 0
        if body.usageMetadata then
            input_tokens = body.usageMetadata.promptTokenCount or 0
            output_tokens = body.usageMetadata.candidatesTokenCount or 0
        end

        local openai_response = {
            id      = "chatcmpl-" .. ngx.now(),
            object  = "chat.completion",
            created = ngx.time(),
            model   = conf._current_model or "",
            choices = {
                {
                    index = 0,
                    message = {
                        role    = "assistant",
                        content = content,
                    },
                    finish_reason = finish_reason,
                }
            },
            usage = {
                prompt_tokens     = input_tokens,
                completion_tokens = output_tokens,
                total_tokens      = input_tokens + output_tokens,
            },
        }

        return cjson.encode(openai_response), nil
    end,

    transform_sse_chunk = function(chunk, conf)
        local data = chunk:match("^data: (.+)")
        if not data then return "" end

        local event = cjson.decode(data)
        if not event or not event.candidates then return "" end

        local candidate = event.candidates[1]
        if not candidate or not candidate.content then return "" end

        local text = ""
        for _, part in ipairs(candidate.content.parts or {}) do
            if part.text then text = text .. part.text end
        end

        local finish = cjson.null
        if candidate.finishReason then
            finish = GOOGLE_FINISH_MAP[candidate.finishReason] or "stop"
        end

        local openai_chunk = {
            id      = "chatcmpl-stream",
            object  = "chat.completion.chunk",
            created = ngx.time(),
            model   = conf._current_model or "",
            choices = {
                {
                    index = 0,
                    delta = { content = text },
                    finish_reason = finish,
                }
            },
        }
        return "data: " .. cjson.encode(openai_chunk) .. "\n\n"
    end,

    map_error = function(status, body_str, conf)
        local body = cjson.decode(body_str)
        if not body then return status, body_str end

        local mapped = {
            error = {
                type    = "server_error",
                code    = body.error and tostring(body.error.code) or "unknown",
                message = body.error and body.error.message or "Google API error",
            }
        }

        -- Map Google status codes
        if body.error then
            local code = body.error.code
            if code == 429 then mapped.error.type = "rate_limit"
            elseif code == 400 then mapped.error.type = "invalid_request_error"
            elseif code == 403 then mapped.error.type = "authentication_error"
            end
        end

        return status, cjson.encode(mapped)
    end,
}


-- ═══════════════════════════════════════════════════════════════════════════
-- Azure OpenAI
-- ═══════════════════════════════════════════════════════════════════════════
providers.azure_openai = {
    name = "azure_openai",

    build_url = function(conf)
        local resource = conf.azure_resource or ""
        local deployment = conf.azure_deployment or conf._current_model or ""
        local api_version = conf.azure_api_version or "2024-02-01"
        return str_format(
            "https://%s.openai.azure.com/openai/deployments/%s/chat/completions?api-version=%s",
            resource, deployment, api_version
        )
    end,

    build_headers = function(conf)
        return {
            ["api-key"]      = conf.api_key or "",
            ["Content-Type"] = "application/json",
        }
    end,

    transform_request = function(body, conf)
        conf._current_model = body.model
        -- Azure uses deployment ID from URL, remove model from body
        local request = {}
        for k, v in pairs(body) do
            if k ~= "model" then
                request[k] = v
            end
        end
        return request
    end,

    -- Azure OpenAI returns OpenAI-compatible responses
    transform_response = function(body_str, conf)
        return body_str, nil
    end,

    transform_sse_chunk = function(chunk, conf)
        return chunk  -- Azure SSE is OpenAI-compatible
    end,

    map_error = function(status, body_str, conf)
        return status, body_str  -- Azure errors are OpenAI-compatible
    end,
}


-- ═══════════════════════════════════════════════════════════════════════════
-- Ollama (local, OpenAI-compatible mode)
-- ═══════════════════════════════════════════════════════════════════════════
providers.ollama = {
    name = "ollama",

    build_url = function(conf)
        return conf.endpoint or "http://localhost:11434/v1/chat/completions"
    end,

    build_headers = function(conf)
        return {
            ["Content-Type"] = "application/json",
        }
    end,

    transform_request = function(body, conf)
        return body  -- Ollama's OpenAI-compatible endpoint
    end,

    transform_response = function(body_str, conf)
        return body_str, nil
    end,

    transform_sse_chunk = function(chunk, conf)
        return chunk
    end,

    map_error = function(status, body_str, conf)
        return status, body_str
    end,
}


-- ────────────────────────────────────────────────────────────────────────────
-- Public API
-- ────────────────────────────────────────────────────────────────────────────

--- Get the provider transformer for a given provider name.
-- @param name  Provider name string (e.g., "openai", "anthropic")
-- @return provider table or nil
function _M.get(name)
    return providers[name]
end


--- List all registered provider names.
-- @return table of provider name strings
function _M.list()
    local names = {}
    for k, _ in pairs(providers) do
        names[#names + 1] = k
    end
    return names
end


--- Extract usage information from a response body string.
-- Attempts to parse the body and find token usage regardless of provider.
-- @param body_str  JSON response body string
-- @return table {prompt_tokens, completion_tokens, total_tokens} or nil
function _M.extract_usage(body_str)
    local body = cjson.decode(body_str)
    if not body then return nil end

    if body.usage then
        return {
            prompt_tokens     = body.usage.prompt_tokens or body.usage.input_tokens or 0,
            completion_tokens = body.usage.completion_tokens or body.usage.output_tokens or 0,
            total_tokens      = body.usage.total_tokens or (
                (body.usage.prompt_tokens or body.usage.input_tokens or 0) +
                (body.usage.completion_tokens or body.usage.output_tokens or 0)
            ),
        }
    end

    -- Google format
    if body.usageMetadata then
        return {
            prompt_tokens     = body.usageMetadata.promptTokenCount or 0,
            completion_tokens = body.usageMetadata.candidatesTokenCount or 0,
            total_tokens      = body.usageMetadata.totalTokenCount or 0,
        }
    end

    return nil
end


return _M
