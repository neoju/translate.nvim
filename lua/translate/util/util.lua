local fn = vim.fn
local api = vim.api
local luv = vim.loop
local utf8 = require("translate.util.utf8")

local M = {}

---Copy the table
---NOTE: Metatable is not considered
---@param tbl table
---@return table
function M.tbl_copy(tbl)
  if type(tbl) ~= "table" then
    return tbl
  end
  local new = {}
  for k, v in pairs(tbl) do
    if type(v) == "table" then
      new[k] = M.tbl_copy(v)
    else
      new[k] = v
    end
  end
  return new
end

---Concatenate two list-like tables.
---@param t1 table
---@param t2 table
---@return table
function M.concat(t1, t2)
  local new = {}
  for _, v in ipairs(t1) do
    table.insert(new, v)
  end
  for _, v in ipairs(t2) do
    table.insert(new, v)
  end
  return new
end

---Add an element to dict[key]
---dict is a table with an array for values.
---@param dict {any: any[]}
---@param key any
---@param elem any
function M.append_dict_list(dict, key, elem)
  if not dict[key] then
    dict[key] = {}
  end
  table.insert(dict[key], elem)
end

function M.text_cut(text, widths)
  local widths_is_table = type(widths) == "table"
  local function get_width(row)
    return widths_is_table and widths[row] or widths
  end

  local lines = {}
  local row, col = 1, 0
  local width = get_width(1)

  local function skip_blank_line()
    while width == 0 do
      M.append_dict_list(lines, row, "")
      row = row + 1
      width = get_width(row)
    end
  end

  skip_blank_line()

  for p, char in utf8.codes(text) do
    local l = api.nvim_strwidth(char)

    if col + l > width then
      if widths_is_table and widths[row + 1] == nil then
        local residue = text:sub(p)
        M.append_dict_list(lines, row, residue)
        break
      end

      row = row + 1
      width = get_width(row)
      col = 0

      skip_blank_line()
    end

    M.append_dict_list(lines, row, char)
    col = col + l
  end

  for i, line in ipairs(lines) do
    lines[i] = table.concat(line, "")
  end

  if #lines == 0 then
    lines = { "" }
  end

  return lines
end

function M.max_width_in_string_list(list)
  local max = api.nvim_strwidth(list[1])
  for i = 2, #list do
    local v = api.nvim_strwidth(list[i])
    if v > max then
      max = v
    end
  end
  return max
end

function M.has_key(tbl, ...)
  local keys = { ... }
  for _, k in ipairs(keys) do
    if tbl[k] == nil then
      return false
    end
  end
  return true
end

---@param last integer
---@return integer[][]
function M.seq(last)
  local l = {}
  for i = 1, last do
    l[i] = { i }
  end
  return l
end

---Compare position
---@param pos1 number[] #{row, col}
---@param pos2 number[] #{row, col}
---@return number[], number[] #front, end
function M.which_front(pos1, pos2)
  -- Row Comparison
  if pos1[1] < pos2[1] then
    return pos1, pos2
  elseif pos1[1] > pos2[1] then
    return pos2, pos1
  else
    -- Col Comparison
    if pos1[2] < pos2[2] then
      return pos1, pos2
    else
      return pos2, pos1
    end
  end
end

---Wrapper function for getpos() that returns only 'row' and 'col'.
---@param expr string
---@return integer[] {row, col}
function M.getpos(expr)
  local p = vim.fn.getpos(expr)
  local result = { p[2], p[3] }
  return result
end

---Returns whether cursor positions are equal.
---@param expr1 string
---@param expr2 string
---@return boolean
function M.same_pos(expr1, expr2)
  local p1 = M.getpos(expr1)
  local p2 = M.getpos(expr2)
  return p1[1] == p2[1] and p1[2] == p2[2]
end

---@param text string #json string
---@return string
function M.write_temp_data(text)
  local dir = fn.expand(fn.stdpath("cache") .. "/translate")
  vim.fn.mkdir(dir, "p")
  local path = fn.expand(dir .. "/data.json")
  -- tonumber("666", 8) -> 438
  local fd = assert(luv.fs_open(path, "w", 438))
  assert(luv.fs_write(fd, text))
  assert(luv.fs_close(fd))
  return path
end

---Wrap lines to a maximum width using a word-break: normal strategy.
---@param lines string[]
---@param max_width integer
---@return string[]
function M.wrap_lines(lines, max_width)
  local new_lines = {}
  for _, text in ipairs(lines) do
    local tokens = {}
    local current_token = ""
    local current_type = nil

    for _, char in utf8.codes(text) do
      local char_width = api.nvim_strwidth(char)
      local char_type
      if char == " " then
        char_type = "space"
      elseif char_width >= 2 then
        char_type = "cjk"
      else
        char_type = "word"
      end

      if char_type == "cjk" then
        if current_token ~= "" then
          table.insert(tokens, { text = current_token, type = current_type, width = api.nvim_strwidth(current_token) })
          current_token = ""
        end
        table.insert(tokens, { text = char, type = "cjk", width = char_width })
        current_type = nil
      else
        if current_type == nil then
          current_token = char
          current_type = char_type
        elseif current_type == char_type then
          current_token = current_token .. char
        else
          table.insert(tokens, { text = current_token, type = current_type, width = api.nvim_strwidth(current_token) })
          current_token = char
          current_type = char_type
        end
      end
    end
    if current_token ~= "" then
      table.insert(tokens, { text = current_token, type = current_type, width = api.nvim_strwidth(current_token) })
    end

    local current_line = {}
    local current_line_width = 0
    local wrapped_this_line = false

    for _, token in ipairs(tokens) do
      if token.type == "space" then
        if current_line_width == 0 and wrapped_this_line then
          -- Skip leading space on wrapped lines
        elseif current_line_width + token.width <= max_width then
          table.insert(current_line, token.text)
          current_line_width = current_line_width + token.width
        else
          local line_str = table.concat(current_line, ""):gsub("%s+$", "")
          table.insert(new_lines, line_str)
          current_line = {}
          current_line_width = 0
          wrapped_this_line = true
        end
      else
        if current_line_width + token.width <= max_width then
          table.insert(current_line, token.text)
          current_line_width = current_line_width + token.width
        else
          if current_line_width > 0 then
            local line_str = table.concat(current_line, ""):gsub("%s+$", "")
            table.insert(new_lines, line_str)
            current_line = {}
            current_line_width = 0
            wrapped_this_line = true
          end

          if token.width <= max_width then
            table.insert(current_line, token.text)
            current_line_width = token.width
          else
            if token.type == "word" then
              for _, char in utf8.codes(token.text) do
                local char_width = api.nvim_strwidth(char)
                if current_line_width + char_width > max_width then
                  local line_str = table.concat(current_line, ""):gsub("%s+$", "")
                  table.insert(new_lines, line_str)
                  current_line = { char }
                  current_line_width = char_width
                  wrapped_this_line = true
                else
                  table.insert(current_line, char)
                  current_line_width = current_line_width + char_width
                end
              end
            else
              table.insert(current_line, token.text)
              current_line_width = token.width
            end
          end
        end
      end
    end

    if #current_line > 0 then
      local line_str = table.concat(current_line, ""):gsub("%s+$", "")
      table.insert(new_lines, line_str)
    end
  end

  if #new_lines == 0 then
    new_lines = { "" }
  end

  return new_lines
end

return M
