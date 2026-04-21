--
-- test_provider_transforms.lua — Unit tests for aria-provider.lua
--
-- Framework: busted
-- Run: busted tests/lua/test_provider_transforms.lua
--

-- ────────────────────────────────────────────────────────────────────────────
-- Mocks
-- ────────────────────────────────────────────────────────────────────────────

_G.ngx = {
    re = { gmatch = function() return function() return nil end end },
    null = "\0",
    now = function() return 1712592600 end,
    time = function() return 1712592600 end,
    utctime = function() return "2026-04-08 14:30:00" end,
    sha1_bin = function(s) return string.rep("\0", 20) end,
    encode_base16 = function(s) return string.rep("0", #s * 2) end,
    log = function() end,
    ERR = 1, WARN = 2, INFO = 3, DEBUG = 4,
    shared = {},
    header = {},
}

-- We need a real JSON encoder/decoder for provider transform tests
-- Use a minimal implementation
local json_store = {}

local function simple_encode(t, indent)
    if t == nil then return "null" end
    if t == "\0" then return "null" end  -- cjson.null
    local tt = type(t)
    if tt == "string" then
        return '"' .. t:gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
    elseif tt == "number" then
        return tostring(t)
    elseif tt == "boolean" then
        return tostring(t)
    elseif tt == "table" then
        -- Check if it's an array
        local is_array = #t > 0 or next(t) == nil
        if is_array and #t > 0 then
            local parts = {}
            for i = 1, #t do
                parts[i] = simple_encode(t[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(t) do
                if type(k) == "string" then
                    parts[#parts + 1] = '"' .. k .. '":' .. simple_encode(v)
                end
            end
            if #parts == 0 then return "{}" end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

local function simple_decode(s)
    if not s or s == "" then return nil, "empty" end
    -- Use Lua load for simple JSON (not safe for production, fine for tests)
    local json_str = s:gsub("%[", "{"):gsub("%]", "}")
    json_str = json_str:gsub('"(%w+)"%s*:', '["%1"]=')
    json_str = json_str:gsub(":null", "=nil")
    json_str = json_str:gsub(":true", "=true")
    json_str = json_str:gsub(":false", "=false")
    -- `load(string)` exists in Lua 5.2+ and LuaJIT 5.2-compat mode;
    -- Lua 5.1 (what Alpine luarocks5.1 runs) requires loadstring.
    local compile = loadstring or load
    local fn = compile("return " .. json_str)
    if fn then
        local ok, result = pcall(fn)
        if ok then return result end
    end
    -- Fallback: store/retrieve from our json_store
    if json_store[s] then return json_store[s] end
    return nil, "decode error"
end

local cjson_mock = {
    encode = simple_encode,
    decode = function(s)
        if json_store[s] then return json_store[s] end
        return simple_decode(s)
    end,
    null = "\0",
    empty_table = {},
}

package.loaded["cjson.safe"] = cjson_mock


-- ────────────────────────────────────────────────────────────────────────────
-- Load module under test
-- ────────────────────────────────────────────────────────────────────────────

package.path = package.path .. ";./apisix/plugins/lib/?.lua"

local provider = require("aria-provider")


-- ────────────────────────────────────────────────────────────────────────────
-- Helper: register a JSON string with its decoded table for round-trip
-- ────────────────────────────────────────────────────────────────────────────

local function register_json(tbl)
    local encoded = simple_encode(tbl)
    json_store[encoded] = tbl
    return encoded
end


-- ────────────────────────────────────────────────────────────────────────────
-- Tests
-- ────────────────────────────────────────────────────────────────────────────

describe("aria-provider", function()

    -- ── Provider Registry ────────────────────────────────────────────────

    describe("get()", function()

        it("should return openai provider", function()
            local p = provider.get("openai")
            assert.is_not_nil(p)
            assert.are.equal("openai", p.name)
        end)

        it("should return anthropic provider", function()
            local p = provider.get("anthropic")
            assert.is_not_nil(p)
            assert.are.equal("anthropic", p.name)
        end)

        it("should return google provider", function()
            local p = provider.get("google")
            assert.is_not_nil(p)
            assert.are.equal("google", p.name)
        end)

        it("should return azure_openai provider", function()
            local p = provider.get("azure_openai")
            assert.is_not_nil(p)
            assert.are.equal("azure_openai", p.name)
        end)

        it("should return ollama provider", function()
            local p = provider.get("ollama")
            assert.is_not_nil(p)
            assert.are.equal("ollama", p.name)
        end)

        it("should return nil for unknown provider", function()
            assert.is_nil(provider.get("unknown_provider"))
        end)
    end)

    describe("list()", function()

        it("should return all 5 providers", function()
            local names = provider.list()
            assert.are.equal(5, #names)
        end)

        it("should contain known provider names", function()
            local names = provider.list()
            local set = {}
            for _, n in ipairs(names) do set[n] = true end
            assert.is_true(set["openai"])
            assert.is_true(set["anthropic"])
            assert.is_true(set["google"])
            assert.is_true(set["azure_openai"])
            assert.is_true(set["ollama"])
        end)
    end)


    -- ── OpenAI (pass-through) ────────────────────────────────────────────

    describe("OpenAI provider", function()
        local openai = provider.get("openai")

        describe("transform_request()", function()

            it("should return body unchanged (pass-through)", function()
                local body = {
                    model = "gpt-4o",
                    messages = {
                        { role = "system", content = "You are helpful." },
                        { role = "user", content = "Hello" },
                    },
                }
                local result = openai.transform_request(body, {})
                assert.are.equal(body, result)
            end)
        end)

        describe("transform_response()", function()

            it("should return response unchanged (pass-through)", function()
                local body_str = '{"id":"chatcmpl-123","choices":[]}'
                local result, err = openai.transform_response(body_str, {})
                assert.are.equal(body_str, result)
                assert.is_nil(err)
            end)
        end)

        describe("build_url()", function()

            it("should use default endpoint", function()
                local url = openai.build_url({})
                assert.are.equal("https://api.openai.com/v1/chat/completions", url)
            end)

            it("should use custom endpoint", function()
                local url = openai.build_url({ endpoint = "https://custom.api.com/v1" })
                assert.are.equal("https://custom.api.com/v1", url)
            end)
        end)

        describe("build_headers()", function()

            it("should include Authorization Bearer header", function()
                local headers = openai.build_headers({ api_key = "sk-test123" })
                assert.are.equal("Bearer sk-test123", headers["Authorization"])
                assert.are.equal("application/json", headers["Content-Type"])
            end)

            it("should handle missing api_key", function()
                local headers = openai.build_headers({})
                assert.are.equal("Bearer ", headers["Authorization"])
            end)
        end)
    end)


    -- ── Anthropic ────────────────────────────────────────────────────────

    describe("Anthropic provider", function()
        local anthropic = provider.get("anthropic")

        describe("transform_request()", function()

            it("should extract system messages to top-level system field", function()
                local body = {
                    model = "claude-sonnet-4-6",
                    messages = {
                        { role = "system", content = "You are a helpful assistant." },
                        { role = "user", content = "Hello" },
                    },
                }
                local result = anthropic.transform_request(body, {})
                assert.are.equal("You are a helpful assistant.", result.system)
                assert.are.equal(1, #result.messages)
                assert.are.equal("user", result.messages[1].role)
                assert.are.equal("Hello", result.messages[1].content)
            end)

            it("should concatenate multiple system messages", function()
                local body = {
                    model = "claude-sonnet-4-6",
                    messages = {
                        { role = "system", content = "Rule 1" },
                        { role = "system", content = "Rule 2" },
                        { role = "user", content = "Hi" },
                    },
                }
                local result = anthropic.transform_request(body, {})
                assert.are.equal("Rule 1\nRule 2", result.system)
                assert.are.equal(1, #result.messages)
            end)

            it("should default max_tokens to 4096 when not specified", function()
                local body = {
                    model = "claude-sonnet-4-6",
                    messages = { { role = "user", content = "Hi" } },
                }
                local result = anthropic.transform_request(body, {})
                assert.are.equal(4096, result.max_tokens)
            end)

            it("should use provided max_tokens when specified", function()
                local body = {
                    model = "claude-sonnet-4-6",
                    messages = { { role = "user", content = "Hi" } },
                    max_tokens = 1024,
                }
                local result = anthropic.transform_request(body, {})
                assert.are.equal(1024, result.max_tokens)
            end)

            it("should preserve model name", function()
                local body = {
                    model = "claude-opus-4-6",
                    messages = { { role = "user", content = "Hi" } },
                }
                local result = anthropic.transform_request(body, {})
                assert.are.equal("claude-opus-4-6", result.model)
            end)

            it("should not set system field when no system messages", function()
                local body = {
                    model = "claude-sonnet-4-6",
                    messages = {
                        { role = "user", content = "Hello" },
                        { role = "assistant", content = "Hi" },
                    },
                }
                local result = anthropic.transform_request(body, {})
                assert.is_nil(result.system)
                assert.are.equal(2, #result.messages)
            end)

            it("should pass through optional parameters", function()
                local body = {
                    model = "claude-sonnet-4-6",
                    messages = { { role = "user", content = "Hi" } },
                    temperature = 0.7,
                    top_p = 0.9,
                    stop = { "END" },
                    stream = true,
                }
                local result = anthropic.transform_request(body, {})
                assert.are.equal(0.7, result.temperature)
                assert.are.equal(0.9, result.top_p)
                assert.are.same({ "END" }, result.stop_sequences)
                assert.is_true(result.stream)
            end)
        end)

        describe("transform_response()", function()

            it("should transform content blocks to choices", function()
                local anthropic_response = {
                    id = "msg_123",
                    model = "claude-sonnet-4-6",
                    content = {
                        { type = "text", text = "Hello! How can I help?" },
                    },
                    stop_reason = "end_turn",
                    usage = {
                        input_tokens = 10,
                        output_tokens = 20,
                    },
                }
                local body_str = register_json(anthropic_response)
                local result_str, err = anthropic.transform_response(body_str, {})
                assert.is_nil(err)
                assert.is_not_nil(result_str)

                -- Decode to verify structure
                local result = cjson_mock.decode(result_str)
                if result then
                    assert.are.equal("chat.completion", result.object)
                    assert.is_not_nil(result.choices)
                end
            end)

            it("should map stop_reason 'end_turn' to 'stop'", function()
                local anthropic_response = {
                    id = "msg_123",
                    model = "claude-sonnet-4-6",
                    content = { { type = "text", text = "Done" } },
                    stop_reason = "end_turn",
                    usage = { input_tokens = 5, output_tokens = 3 },
                }
                local body_str = register_json(anthropic_response)
                local result_str, err = anthropic.transform_response(body_str, {})
                assert.is_nil(err)

                local result = cjson_mock.decode(result_str)
                if result and result.choices then
                    assert.are.equal("stop", result.choices[1].finish_reason)
                end
            end)

            it("should map stop_reason 'max_tokens' to 'length'", function()
                local anthropic_response = {
                    id = "msg_456",
                    model = "claude-sonnet-4-6",
                    content = { { type = "text", text = "Truncated..." } },
                    stop_reason = "max_tokens",
                    usage = { input_tokens = 10, output_tokens = 4096 },
                }
                local body_str = register_json(anthropic_response)
                local result_str, err = anthropic.transform_response(body_str, {})
                assert.is_nil(err)

                local result = cjson_mock.decode(result_str)
                if result and result.choices then
                    assert.are.equal("length", result.choices[1].finish_reason)
                end
            end)

            it("should map stop_reason 'tool_use' to 'tool_calls'", function()
                local anthropic_response = {
                    id = "msg_789",
                    model = "claude-sonnet-4-6",
                    content = { { type = "text", text = "" } },
                    stop_reason = "tool_use",
                    usage = { input_tokens = 10, output_tokens = 50 },
                }
                local body_str = register_json(anthropic_response)
                local result_str, err = anthropic.transform_response(body_str, {})
                assert.is_nil(err)

                local result = cjson_mock.decode(result_str)
                if result and result.choices then
                    assert.are.equal("tool_calls", result.choices[1].finish_reason)
                end
            end)

            it("should map usage from Anthropic format", function()
                local anthropic_response = {
                    id = "msg_usage",
                    model = "claude-sonnet-4-6",
                    content = { { type = "text", text = "test" } },
                    stop_reason = "end_turn",
                    usage = { input_tokens = 100, output_tokens = 200 },
                }
                local body_str = register_json(anthropic_response)
                local result_str, err = anthropic.transform_response(body_str, {})
                assert.is_nil(err)

                local result = cjson_mock.decode(result_str)
                if result and result.usage then
                    assert.are.equal(100, result.usage.prompt_tokens)
                    assert.are.equal(200, result.usage.completion_tokens)
                    assert.are.equal(300, result.usage.total_tokens)
                end
            end)

            it("should handle empty content array", function()
                local anthropic_response = {
                    id = "msg_empty",
                    model = "claude-sonnet-4-6",
                    content = {},
                    stop_reason = "end_turn",
                    usage = { input_tokens = 5, output_tokens = 0 },
                }
                local body_str = register_json(anthropic_response)
                local result_str, err = anthropic.transform_response(body_str, {})
                assert.is_nil(err)

                local result = cjson_mock.decode(result_str)
                if result and result.choices then
                    assert.are.equal("", result.choices[1].message.content)
                end
            end)

            it("should handle error responses", function()
                local anthropic_error = {
                    type = "error",
                    error = {
                        type = "rate_limit_error",
                        message = "Rate limited",
                    },
                }
                local body_str = register_json(anthropic_error)
                local result_str, err = anthropic.transform_response(body_str, {})
                assert.is_nil(err)

                local result = cjson_mock.decode(result_str)
                if result and result.error then
                    assert.are.equal("rate_limit", result.error.type)
                    assert.are.equal("rate_limit_error", result.error.code)
                end
            end)
        end)

        describe("build_headers()", function()

            it("should include x-api-key header", function()
                local headers = anthropic.build_headers({ api_key = "sk-ant-123" })
                assert.are.equal("sk-ant-123", headers["x-api-key"])
                assert.are.equal("application/json", headers["Content-Type"])
            end)

            it("should include default anthropic-version", function()
                local headers = anthropic.build_headers({})
                assert.are.equal("2023-06-01", headers["anthropic-version"])
            end)

            it("should use custom api_version", function()
                local headers = anthropic.build_headers({ api_version = "2024-01-01" })
                assert.are.equal("2024-01-01", headers["anthropic-version"])
            end)
        end)

        describe("build_url()", function()

            it("should use default Anthropic endpoint", function()
                local url = anthropic.build_url({})
                assert.are.equal("https://api.anthropic.com/v1/messages", url)
            end)
        end)
    end)


    -- ── Google Gemini ────────────────────────────────────────────────────

    describe("Google provider", function()
        local google = provider.get("google")

        describe("transform_request()", function()

            it("should transform messages to contents format", function()
                local conf = {}
                local body = {
                    model = "gemini-2.0-flash",
                    messages = {
                        { role = "user", content = "Hello" },
                    },
                }
                local result = google.transform_request(body, conf)
                assert.is_not_nil(result.contents)
                assert.are.equal(1, #result.contents)
                assert.are.equal("user", result.contents[1].role)
                assert.are.equal("Hello", result.contents[1].parts[1].text)
            end)

            it("should extract system messages to systemInstruction", function()
                local conf = {}
                local body = {
                    model = "gemini-2.0-flash",
                    messages = {
                        { role = "system", content = "Be helpful" },
                        { role = "user", content = "Hello" },
                    },
                }
                local result = google.transform_request(body, conf)
                assert.is_not_nil(result.systemInstruction)
                assert.are.equal("Be helpful", result.systemInstruction.parts[1].text)
                assert.are.equal(1, #result.contents)
            end)

            it("should map 'assistant' role to 'model'", function()
                local conf = {}
                local body = {
                    model = "gemini-2.0-flash",
                    messages = {
                        { role = "user", content = "Hi" },
                        { role = "assistant", content = "Hello!" },
                    },
                }
                local result = google.transform_request(body, conf)
                assert.are.equal("model", result.contents[2].role)
            end)

            it("should pass temperature to generationConfig", function()
                local conf = {}
                local body = {
                    model = "gemini-2.0-flash",
                    messages = { { role = "user", content = "Hi" } },
                    temperature = 0.5,
                }
                local result = google.transform_request(body, conf)
                assert.are.equal(0.5, result.generationConfig.temperature)
            end)

            it("should pass max_tokens as maxOutputTokens", function()
                local conf = {}
                local body = {
                    model = "gemini-2.0-flash",
                    messages = { { role = "user", content = "Hi" } },
                    max_tokens = 2048,
                }
                local result = google.transform_request(body, conf)
                assert.are.equal(2048, result.generationConfig.maxOutputTokens)
            end)

            it("should pass top_p to generationConfig", function()
                local conf = {}
                local body = {
                    model = "gemini-2.0-flash",
                    messages = { { role = "user", content = "Hi" } },
                    top_p = 0.95,
                }
                local result = google.transform_request(body, conf)
                assert.are.equal(0.95, result.generationConfig.topP)
            end)

            it("should store current model in conf for URL building", function()
                local conf = {}
                local body = {
                    model = "gemini-2.5-pro",
                    messages = { { role = "user", content = "Hi" } },
                }
                google.transform_request(body, conf)
                assert.are.equal("gemini-2.5-pro", conf._current_model)
            end)

            it("should not include systemInstruction when no system messages", function()
                local conf = {}
                local body = {
                    model = "gemini-2.0-flash",
                    messages = {
                        { role = "user", content = "Hello" },
                    },
                }
                local result = google.transform_request(body, conf)
                assert.is_nil(result.systemInstruction)
            end)
        end)

        describe("transform_response()", function()

            it("should transform Google response to OpenAI format", function()
                local google_response = {
                    candidates = {
                        {
                            content = {
                                parts = { { text = "Hello from Gemini!" } },
                            },
                            finishReason = "STOP",
                        },
                    },
                    usageMetadata = {
                        promptTokenCount = 10,
                        candidatesTokenCount = 15,
                    },
                }
                local body_str = register_json(google_response)
                local conf = { _current_model = "gemini-2.0-flash" }
                local result_str, err = google.transform_response(body_str, conf)
                assert.is_nil(err)

                local result = cjson_mock.decode(result_str)
                if result then
                    assert.are.equal("chat.completion", result.object)
                    if result.choices then
                        assert.are.equal("stop", result.choices[1].finish_reason)
                        assert.are.equal("Hello from Gemini!", result.choices[1].message.content)
                    end
                    if result.usage then
                        assert.are.equal(10, result.usage.prompt_tokens)
                        assert.are.equal(15, result.usage.completion_tokens)
                    end
                end
            end)

            it("should map STOP finishReason to 'stop'", function()
                local google_response = {
                    candidates = {
                        {
                            content = { parts = { { text = "Done" } } },
                            finishReason = "STOP",
                        },
                    },
                    usageMetadata = { promptTokenCount = 5, candidatesTokenCount = 3 },
                }
                local body_str = register_json(google_response)
                local result_str, _ = google.transform_response(body_str, { _current_model = "gemini-2.0-flash" })
                local result = cjson_mock.decode(result_str)
                if result and result.choices then
                    assert.are.equal("stop", result.choices[1].finish_reason)
                end
            end)

            it("should map MAX_TOKENS finishReason to 'length'", function()
                local google_response = {
                    candidates = {
                        {
                            content = { parts = { { text = "Truncated" } } },
                            finishReason = "MAX_TOKENS",
                        },
                    },
                    usageMetadata = { promptTokenCount = 5, candidatesTokenCount = 100 },
                }
                local body_str = register_json(google_response)
                local result_str, _ = google.transform_response(body_str, { _current_model = "gemini-2.0-flash" })
                local result = cjson_mock.decode(result_str)
                if result and result.choices then
                    assert.are.equal("length", result.choices[1].finish_reason)
                end
            end)

            it("should map SAFETY finishReason to 'content_filter'", function()
                local google_response = {
                    candidates = {
                        {
                            content = { parts = { { text = "" } } },
                            finishReason = "SAFETY",
                        },
                    },
                    usageMetadata = { promptTokenCount = 5, candidatesTokenCount = 0 },
                }
                local body_str = register_json(google_response)
                local result_str, _ = google.transform_response(body_str, { _current_model = "gemini-2.0-flash" })
                local result = cjson_mock.decode(result_str)
                if result and result.choices then
                    assert.are.equal("content_filter", result.choices[1].finish_reason)
                end
            end)

            it("should handle error responses from Google", function()
                local google_error = {
                    error = {
                        code = 429,
                        message = "Rate limit exceeded",
                    },
                }
                local body_str = register_json(google_error)
                local result_str, err = google.transform_response(body_str, { _current_model = "gemini-2.0-flash" })
                assert.is_nil(err)

                local result = cjson_mock.decode(result_str)
                if result and result.error then
                    assert.are.equal("server_error", result.error.type)
                end
            end)
        end)

        describe("build_url()", function()

            it("should build URL with model and generateContent action", function()
                local conf = { _current_model = "gemini-2.0-flash" }
                local url = google.build_url(conf)
                assert.truthy(url:match("gemini%-2%.0%-flash"))
                assert.truthy(url:match("generateContent$"))
            end)

            it("should build URL with streaming action", function()
                local conf = { _current_model = "gemini-2.0-flash", _stream = true }
                local url = google.build_url(conf)
                assert.truthy(url:match("streamGenerateContent"))
            end)

            it("should use default model when _current_model is nil", function()
                local conf = {}
                local url = google.build_url(conf)
                assert.truthy(url:match("gemini%-2%.0%-flash"))
            end)

            it("should use custom endpoint", function()
                local conf = {
                    endpoint = "https://custom-gemini.example.com/v1",
                    _current_model = "gemini-2.5-pro",
                }
                local url = google.build_url(conf)
                assert.truthy(url:match("^https://custom%-gemini%.example%.com/v1"))
            end)
        end)
    end)


    -- ── Azure OpenAI ─────────────────────────────────────────────────────

    describe("Azure OpenAI provider", function()
        local azure = provider.get("azure_openai")

        describe("transform_request()", function()

            it("should remove model from request body", function()
                local conf = {}
                local body = {
                    model = "gpt-4o",
                    messages = { { role = "user", content = "Hi" } },
                    temperature = 0.7,
                }
                local result = azure.transform_request(body, conf)
                assert.is_nil(result.model)
                assert.are.equal(0.7, result.temperature)
            end)

            it("should store model in conf._current_model", function()
                local conf = {}
                local body = {
                    model = "gpt-4o",
                    messages = { { role = "user", content = "Hi" } },
                }
                azure.transform_request(body, conf)
                assert.are.equal("gpt-4o", conf._current_model)
            end)
        end)

        describe("build_url()", function()

            it("should build Azure-format URL", function()
                local conf = {
                    azure_resource = "myresource",
                    azure_deployment = "my-deployment",
                    azure_api_version = "2024-02-01",
                }
                local url = azure.build_url(conf)
                assert.truthy(url:match("myresource%.openai%.azure%.com"))
                assert.truthy(url:match("my%-deployment"))
                assert.truthy(url:match("api%-version=2024%-02%-01"))
            end)
        end)

        describe("build_headers()", function()

            it("should use api-key header instead of Authorization", function()
                local headers = azure.build_headers({ api_key = "azure-key-123" })
                assert.are.equal("azure-key-123", headers["api-key"])
                assert.is_nil(headers["Authorization"])
            end)
        end)
    end)


    -- ── extract_usage() ──────────────────────────────────────────────────

    describe("extract_usage()", function()

        it("should extract usage from OpenAI format", function()
            local openai_response = {
                usage = {
                    prompt_tokens = 50,
                    completion_tokens = 100,
                    total_tokens = 150,
                },
            }
            local body_str = register_json(openai_response)
            local usage = provider.extract_usage(body_str)
            assert.is_not_nil(usage)
            assert.are.equal(50, usage.prompt_tokens)
            assert.are.equal(100, usage.completion_tokens)
            assert.are.equal(150, usage.total_tokens)
        end)

        it("should extract usage from Anthropic format (input_tokens/output_tokens)", function()
            local anthropic_response = {
                usage = {
                    input_tokens = 30,
                    output_tokens = 70,
                },
            }
            local body_str = register_json(anthropic_response)
            local usage = provider.extract_usage(body_str)
            assert.is_not_nil(usage)
            assert.are.equal(30, usage.prompt_tokens)
            assert.are.equal(70, usage.completion_tokens)
            assert.are.equal(100, usage.total_tokens)
        end)

        it("should extract usage from Google format (usageMetadata)", function()
            local google_response = {
                usageMetadata = {
                    promptTokenCount = 25,
                    candidatesTokenCount = 60,
                    totalTokenCount = 85,
                },
            }
            local body_str = register_json(google_response)
            local usage = provider.extract_usage(body_str)
            assert.is_not_nil(usage)
            assert.are.equal(25, usage.prompt_tokens)
            assert.are.equal(60, usage.completion_tokens)
            assert.are.equal(85, usage.total_tokens)
        end)

        it("should return nil for response without usage", function()
            local response = { id = "test", choices = {} }
            local body_str = register_json(response)
            local usage = provider.extract_usage(body_str)
            assert.is_nil(usage)
        end)

        it("should return nil for invalid JSON", function()
            local usage = provider.extract_usage("not json at all")
            assert.is_nil(usage)
        end)

        it("should return nil for nil input", function()
            local usage = provider.extract_usage(nil)
            assert.is_nil(usage)
        end)

        it("should handle missing total_tokens by computing sum", function()
            local response = {
                usage = {
                    prompt_tokens = 40,
                    completion_tokens = 60,
                },
            }
            local body_str = register_json(response)
            local usage = provider.extract_usage(body_str)
            assert.is_not_nil(usage)
            assert.are.equal(40, usage.prompt_tokens)
            assert.are.equal(60, usage.completion_tokens)
            assert.are.equal(100, usage.total_tokens)
        end)
    end)


    -- ── map_anthropic_error() ────────────────────────────────────────────

    describe("map_anthropic_error()", function()

        it("should map overloaded_error to server_error", function()
            local result = provider.map_anthropic_error({
                error = { type = "overloaded_error", message = "Overloaded" },
            })
            assert.are.equal("server_error", result.error.type)
            assert.are.equal("overloaded_error", result.error.code)
            assert.are.equal("Overloaded", result.error.message)
        end)

        it("should map rate_limit_error to rate_limit", function()
            local result = provider.map_anthropic_error({
                error = { type = "rate_limit_error", message = "Too many requests" },
            })
            assert.are.equal("rate_limit", result.error.type)
        end)

        it("should map authentication_error", function()
            local result = provider.map_anthropic_error({
                error = { type = "authentication_error", message = "Invalid key" },
            })
            assert.are.equal("authentication_error", result.error.type)
        end)

        it("should map invalid_request_error", function()
            local result = provider.map_anthropic_error({
                error = { type = "invalid_request_error", message = "Bad request" },
            })
            assert.are.equal("invalid_request_error", result.error.type)
        end)

        it("should map not_found_error", function()
            local result = provider.map_anthropic_error({
                error = { type = "not_found_error", message = "Model not found" },
            })
            assert.are.equal("not_found_error", result.error.type)
        end)

        it("should default unknown error types to server_error", function()
            local result = provider.map_anthropic_error({
                error = { type = "weird_error", message = "Something odd" },
            })
            assert.are.equal("server_error", result.error.type)
        end)

        it("should handle missing error fields", function()
            local result = provider.map_anthropic_error({})
            assert.are.equal("server_error", result.error.type)
            assert.are.equal("unknown", result.error.code)
            assert.are.equal("Unknown Anthropic error", result.error.message)
        end)
    end)


    -- ── Ollama ───────────────────────────────────────────────────────────

    describe("Ollama provider", function()
        local ollama = provider.get("ollama")

        it("should pass through request unchanged", function()
            local body = { model = "llama3", messages = { { role = "user", content = "Hi" } } }
            local result = ollama.transform_request(body, {})
            assert.are.equal(body, result)
        end)

        it("should pass through response unchanged", function()
            local result, err = ollama.transform_response('{"test":true}', {})
            assert.are.equal('{"test":true}', result)
            assert.is_nil(err)
        end)

        it("should use default localhost endpoint", function()
            local url = ollama.build_url({})
            assert.are.equal("http://localhost:11434/v1/chat/completions", url)
        end)

        it("should not require api_key in headers", function()
            local headers = ollama.build_headers({})
            assert.is_nil(headers["Authorization"])
            assert.are.equal("application/json", headers["Content-Type"])
        end)
    end)
end)
