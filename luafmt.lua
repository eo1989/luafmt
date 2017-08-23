local filename = arg[1]
if not filename then
	printHelp()
end

local file = io.open(filename, "r")
if not file then
	print("cannot open file `" .. filename .. "`")
	os.exit(1)
end

local function matcher(pattern, tag)
	assert(type(tag) == "string")
	return function(text, offset)
		local from, to = text:find("^" .. pattern, offset)
		if from then
			return to, tag
		end
	end
end

local IS_KEYWORD = {
	["if"] = true,
	["then"] = true,
	["elseif"] = true,
	["else"] = true,
	["end"] = true,
	["for"] = true,
	["in"] = true,
	["do"] = true,
	["repeat"] = true,
	["until"] = true,
	["while"] = true,
	["function"] = true,
	-- in line
	["local"] = true,
	["return"] = true,
	["break"] = true,
}

local TOKENS = {
	-- string literals
	function(text, offset)
		local quote = text:sub(offset, offset)
		if quote == "\"" or quote == "'" then
			local back = false
			for i = offset+1, #text do
				if back then
					back = false
				elseif text:sub(i, i) == "\\" then
					back = true
				elseif text:sub(i, i) == quote then
					return i, "string"
				end
			end
		end
	end,

	-- long string literals
	function(text, offset)
		local from, to = text:find("^%[=*%[", offset)
		if from then
			local size = to - from - 1
			local _, stop = text:find("%]" .. string.rep("=", size) .. "%]", offset)
			assert(stop)
			return stop, "string"
		end
	end,

	-- comments
	function(text, offset)
		if text:sub(offset, offset+1) == "--" then
			local start, startLen = text:find("^%[=*%[", offset + 2)
			if start then
				local size = startLen - start - 1
				local _, stop = text:find("%]" .. string.rep("=", size) .. "%]", offset)
				assert(stop)
				return stop, "comment"
			end
			return (text:find("\n", offset) or #text), "comment"
		end
	end,

	-- whitespace
	function(text, offset)
		local _, space = text:find("^%s+", offset)
		if space then
			local breaks = 0
			for _ in text:sub(offset, space):gmatch("\n") do
				breaks = breaks + 1
			end
			if breaks > 1 then
				return space, "empty"
			end
			return space, "whitespace"
		end
	end,
	-- number
	function(text, offset)
		local _, limit = text:find("^[0-9.-+eExa-fA-F]+", offset)
		local last
		for i = offset, limit or offset do
			if tonumber(text:sub(offset, i)) then
				last = i
			end
		end
		if last then
			return last, "number"
		end
	end,

	-- dots
	matcher("%.%.%.", "name"),

	-- concat
	matcher("%.%.", "operator"),

	-- identifiers and keywords
	function(text, offset)
		local from, to = text:find("^[a-zA-Z0-9_]+", offset)
		if to then
			local word = text:sub(from, to)
			local size = #word
			
			if IS_KEYWORD[word] then
				return to, word
			elseif word == "not" or word == "or" or word == "and" then
				return to, "operator"
			end
			return to, "word"
		end
	end,
	matcher("[a-zA-Z0-9_]+", "word"),

	-- accessors
	matcher("[:.]", "access"),

	-- entry separator
	matcher("[;,]", "separator"),

	-- opening brace
	matcher("[%[{(]", "open"),

	-- closing brace
	matcher("[%]})]", "close"),

	-- operators
	function(text, offset)
		local operators = {
			"==",
			"<=",
			">=",
			"~=",
			"^",
			"*",
			"/",
			"%",
			"<",
			">",
			"+",
			"-",
			"#",
		}
		for _, op in ipairs(operators) do
			local to = offset + #op - 1
			if text:sub(offset, to) == op then
				return to, "operator"
			end
		end
	end,
	-- assignment
	matcher("=", "assign"),
}

local function tokenize(blob)
	local tokens = {}
	local offset = 1
	while offset < #blob do
		local didCut = false
		for _, t in ipairs(TOKENS) do
			local cut, tag = t(blob, offset)
			if cut then
				assert(type(cut) == "number", _ .. " number")
				assert(cut >= offset, _ .. " offset")
				assert(tag, tostring(_) .. " tag")
				if tag ~= "whitespace" then
					table.insert(tokens, {text = blob:sub(offset, cut), tag = tag})
				end
				offset = cut + 1
				didCut = true
				break
			end
		end
		assert(didCut, blob:sub(offset, offset+50))
	end
	return tokens
end

local tokens = tokenize(file:read("*all"))

--------------------------------------------------------------------------------

local function splitLines(tokens)
	-- These token tags MUST be the first token in their line
	local MUST_START = {
		["if"] = true,
		["local"] = true,
		["repeat"] = true,
		["else"] = true,
		["elseif"] = true,
		["end"] = true,
		["until"] = true,
		["while"] = true,
		["for"] = true,

		-- statements
		["return"] = true,
		["break"] = true,

		-- Formatting
		["comment"] = true,
		["empty"] = true,
	}

	-- These token tags MUST be the final token in their line
	local MUST_END = {
		["then"] = true,
		["else"] = true,
		["end"] = true,
		["repeat"] = true,
		["do"] = true,

		-- statements
		["break"] = true,

		-- Formatting
		["empty"] = true,
		["comment"] = true,
	}

	-- These token tags MUST be the first token in their line when the
	-- associated function returns `true` for the given context
	local MIGHT_START = {
		["do"] = function(line)
			if line[1].tag == "for" or line[1].tag == "while" then
				return false
			end
			return true
		end,
		["function"] = function(line, context)
			if context(1).tag == "open" then
				-- anonymous functions don't begin lines
				return false
			elseif context(-1).tag == "local" then
				-- the `local` begins a `local function` line
				return false
			end
			return true
		end,
	}

	-- These token tags MUST be the final token in their line when the
	-- associated function returns `true` for the given context
	local MIGHT_END = {
		["close"] = function(line, context, token)
			if token.text == ")" then
				-- Find out if this closing parenthesis ends a function's
				-- parameter list by walking backwards, stopping at the first
				-- `)` (no) or `function` (yes)
				for i = -1, -math.huge, -1 do
					-- XXX: this could be linear in stupid scripts
					if context(i).tag == "close" or context(i).tag == "close-parameters" then
						return false
					elseif context(i).tag == "^" then
						return false
					elseif context(i).tag == "function" then
						token.tag = "close-parameters"
						return true
					end
				end
			end
			return false
		end,
	}

	local statementBreak = {
		{"close", "word"},
		{"word", "word"},
		{"string", "word"},
		{"number", "word"},
	}

	local lines = {{}}
	for i, token in ipairs(tokens) do
		local function context(offset)
			return tokens[i + offset] or {
				text = "",
				tag = offset < 0 and "^" or "$"
			}
		end

		if #lines[#lines] == 0 then
		elseif MUST_START[token.tag] or (MIGHT_START[token.tag] and MIGHT_START[token.tag](lines[#lines], context, token)) then
			table.insert(lines, {})
		end
		local line = lines[#lines]
		table.insert(line, token)

		local semicolon = false
		for _, pair in ipairs(statementBreak) do
			if token.tag == pair[1] and context(1).tag == pair[2] then
				semicolon = true
			end
		end

		if MUST_END[token.tag] or (MIGHT_END[token.tag] and MIGHT_END[token.tag](line, context, token)) or semicolon then
			table.insert(lines, {})
		end
	end

	if #lines[#lines] == 0 then
		table.remove(lines)
	end

	local INCREASE = {
		["if"] = true,
		["while"] = true,
		["repeat"] = true,
		["else"] = true,
		["elseif"] = true,
		["for"] = true,
		["do"] = true,
		["function"] = true,
	}
	local DECREASE = {
		["end"] = true,
		["else"] = true,
		["elseif"] = true,
		["until"] = true,
	}

	local out = {}
	for _, line in ipairs(lines) do
		if DECREASE[line[1].tag] then
			table.insert(out, {text = "", tag = "indent-decrease"})
		end
		table.insert(out, {text = "", tag = "newline"})
		for _, token in ipairs(line) do
			table.insert(out, token)
		end


		if INCREASE[line[1].tag] or line[#line].tag == "close-parameters" then
			table.insert(out, {text = "", tag = "indent-increase"})
		end
	end

	return out
end

local function trimmed(s)
	return s:match("^%s*(.*)$"):match("^(.-)%s*$")
end

local indent = 0
local tokens = splitLines(tokens)
for _, token in ipairs(tokens) do
	if token.tag == "newline" then
		io.write("\n" .. string.rep("\t", indent))
	elseif token.tag == "indent-increase" then
		indent = indent + 1
	elseif token.tag == "indent-decrease" then
		indent = indent - 1
	else
		io.write(trimmed(token.text) .. " ")
	end
end
print()
