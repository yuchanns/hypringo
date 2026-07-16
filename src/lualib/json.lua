local M = {}

local escapes = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encode_string(value)
	return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
		return escapes[character] or ("\\u%04x"):format(character:byte())
	end) .. '"'
end

local function table_shape(value)
	local length = 0
	local count = 0
	for key in pairs(value) do
		count = count + 1
		if math.type(key) ~= "integer" or key < 1 then
			return "object"
		end
		if key > length then
			length = key
		end
	end
	if count > 0 and count == length then
		return "array", length
	end
	return "object"
end

local function encode_value(value, visiting)
	local value_type = type(value)
	if value_type == "nil" then
		return "null"
	elseif value_type == "boolean" then
		return value and "true" or "false"
	elseif value_type == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error "cannot encode a non-finite number"
		end
		return tostring(value)
	elseif value_type == "string" then
		return encode_string(value)
	elseif value_type ~= "table" then
		error("cannot encode " .. value_type)
	end

	if visiting[value] then
		error "cannot encode a circular table"
	end
	visiting[value] = true

	local shape, length = table_shape(value)
	local result = {}
	if shape == "array" then
		for index = 1, length do
			result[index] = encode_value(value[index], visiting)
		end
		visiting[value] = nil
		return "[" .. table.concat(result, ",") .. "]"
	end

	local keys = {}
	for key in pairs(value) do
		if type(key) ~= "string" then
			error "JSON object keys must be strings"
		end
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for index, key in ipairs(keys) do
		result[index] = encode_string(key) .. ":" .. encode_value(value[key], visiting)
	end
	visiting[value] = nil
	return "{" .. table.concat(result, ",") .. "}"
end

function M.encode(value)
	return encode_value(value, {})
end

return M
