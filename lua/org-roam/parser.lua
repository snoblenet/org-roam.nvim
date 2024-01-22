-------------------------------------------------------------------------------
-- PARSER.LUA
--
-- Parsing logic to extract information from org files.
-------------------------------------------------------------------------------

local Heading             = require("org-roam.parser.heading")
local Link                = require("org-roam.parser.link")
local PropertyDrawer      = require("org-roam.parser.property-drawer")
local Property            = require("org-roam.parser.property")
local Range               = require("org-roam.parser.range")
local Ref                 = require("org-roam.parser.ref")
local Slice               = require("org-roam.parser.slice")

---@enum org-roam.parser.QueryTypes
local QUERY_TYPES         = {
    TOP_LEVEL_PROPERTY_DRAWER = 1,
    SECTION_PROPERTY_DRAWER = 2,
    REGULAR_LINK = 3,
}

---@enum org-roam.parser.QueryCaptureTypes
local QUERY_CAPTURE_TYPES = {
    TOP_LEVEL_PROPERTY_DRAWER              = "top-level-drawer",
    TOP_LEVEL_PROPERTY_DRAWER_NAME         = "top-level-drawer-name",
    TOP_LEVEL_PROPERTY_DRAWER_CONTENTS     = "top-level-drawer-contents",
    SECTION_PROPERTY_DRAWER_HEADLINE       = "property-drawer-headline",
    SECTION_PROPERTY_DRAWER_HEADLINE_STARS = "property-drawer-headline-stars",
    SECTION_PROPERTY_DRAWER                = "property-drawer",
    SECTION_PROPERTY_DRAWER_PROPERTY       = "property",
    SECTION_PROPERTY_DRAWER_PROPERTY_NAME  = "property-name",
    SECTION_PROPERTY_DRAWER_PROPERTY_VALUE = "property-value",
    REGULAR_LINK                           = "regular-link",
}

---@class org-roam.parser.Results
---@field drawers org-roam.parser.PropertyDrawer[]
---@field links org-roam.parser.Link[]

---@class org-roam.Parser
---@field private __is_initialized boolean
local M                   = {
    __is_initialized = false,
}

function M.init()
    if M.__is_initialized then
        return
    end

    ---Ensures that the nodes are on the same line.
    ---Pulled from nvim-orgmode/orgmode.
    ---
    ---@param start_node TSNode
    ---@param end_node TSNode
    ---@return boolean
    local function on_same_line(start_node, end_node)
        if not start_node or not end_node then
            return false
        end

        local start_line = start_node:range()
        local end_line = end_node:range()

        return start_line == end_line
    end


    ---Ensures that the start and end of a regular link actually represent a regular link.
    ---Pulled from nvim-orgmode/orgmode.
    local function is_valid_regular_link_range(match, _, source, predicates)
        local start_node = match[predicates[2]]
        local end_node = match[predicates[3]]

        local is_valid = on_same_line(start_node, end_node)

        if not is_valid then
            return false
        end

        -- Range start is inclusive, end is exclusive, and both are zero-based
        local _, _, offset_start = start_node:start()
        local _, _, offset_end = end_node:end_()

        -- TODO: I don't know why we are running into these situations:
        --
        -- 1. There is more than one match for the same link.
        -- 2. One of the matches is missing a starting square bracket.
        -- 3. There is a space at the end of each matche.
        --     * "[[...]] "
        --     * "[...]] "
        --
        -- For now, we trim the space so one of these will work...
        local text = vim.trim(string.sub(source, offset_start + 1, offset_end + 1))

        local is_valid_start = vim.startswith(text, "[[")
        local is_valid_end = vim.endswith(text, "]]")
        return is_valid_start and is_valid_end
    end

    -- Build out custom predicates so we can further validate our links
    vim.treesitter.query.add_predicate(
        "org-roam-is-valid-regular-link-range?",
        is_valid_regular_link_range
    )

    M.__is_initialized = true
end

---@private
---@param properties org-roam.parser.Property[] #where to place new properties
---@param ref org-roam.parser.Ref<string> #reference to overall contents
---@param lines string[] #lines to parse
---@param start_row integer
---@param start_offset integer
local function parse_lines_as_properties(properties, ref, lines, start_row, start_offset)
    local row = start_row
    local offset = start_offset

    for _, line in ipairs(lines) do
        local i, _, name, space, value = string.find(line, ":([^%c%z]+):(%s+)([^%c%z]+)$")
        if name and value then
            -- Record where the property starts (could have whitespace in front of it)
            local property_offset = offset + i - 1

            -- We parsed a name and value, so now we need to build up the ranges for the
            -- entire property, which looks like this:
            --
            --     range
            -- |          |
            -- :NAME: VALUE
            --  |  |  |   |
            --  range range
            --
            --  To do this, we need to build up the position from an initial offset
            --  representing the beginning of the line, the length of the name, and
            --  the length of the value.
            local property_range = Range:new({
                row = row,
                column = property_offset - offset,
                offset = property_offset,
            }, {
                row = row,
                column = (property_offset - offset) + string.len(line),
                offset = offset + string.len(line),
            })

            -- Name range is within the colons
            local name_range = Range:new({
                row = property_range.start.row,
                column = property_range.start.column + 1,
                offset = property_range.start.offset + 1,
            }, {
                row = property_range.end_.row,
                column = property_range.start.column + string.len(name),
                offset = property_range.start.offset + string.len(name),
            })

            local value_range = Range:new({
                row = property_range.start.row,
                column = (name_range.end_.column + 1) + string.len(space) + 1,
                offset = (name_range.end_.offset + 1) + string.len(space) + 1,
            }, {
                row = property_range.end_.row,
                column = (name_range.end_.column + 1) + string.len(space) + string.len(value),
                offset = (name_range.end_.offset + 1) + string.len(space) + string.len(value),
            })

            local property = Property:new({
                range = property_range,
                name = Slice:new(ref, name_range, { cache = name }),
                value = Slice:new(ref, value_range, { cache = value }),
            })
            table.insert(properties, property)
        end

        -- Next line means next row
        row = row + 1

        -- Advance the offset by the line (including the newline)
        offset = offset + string.len(line) + 1
    end
end

---@param contents string
---@return org-roam.parser.Results
function M.parse(contents)
    M.init()

    local ref = Ref:new(contents)
    local trees = vim.treesitter.get_string_parser(ref.value, "org"):parse()

    -- Build a query to find top-level drawers (with  name PROPERTIES)
    -- property drawers underneath headings, and expressions that are links
    --
    -- NOTE: The link-parsing logic is a bit of a hack and comes from
    --       https://github.com/nvim-orgmode/orgmode/blob/master/queries/org/markup.scm
    ---@type Query
    local query = vim.treesitter.query.parse("org", [=[
        (
            (drawer
                name: (expr) @top-level-drawer-name
                contents: (contents) @top-level-drawer-contents) @top-level-drawer
            (#eq? @top-level-drawer-name "PROPERTIES")
        )
        (section
            (headline
                stars: (stars) @property-drawer-headline-stars) @property-drawer-headline
            (property_drawer) @property-drawer
        )
        [
            (paragraph
                ((expr "[" @hyperlink.start . "[" _) (expr _ "]" . "]" @hyperlink.end)
                    (#org-roam-is-valid-regular-link-range? @hyperlink.start @hyperlink.end)))
            (paragraph
                (expr "[" @hyperlink.start . "[" _  "]" . "]" @hyperlink.end
                    (#org-roam-is-valid-regular-link-range? @hyperlink.start @hyperlink.end)))
            (item
                ((expr "[" @hyperlink.start . "[" _) (expr _ "]" . "]" @hyperlink.end)
                    (#org-roam-is-valid-regular-link-range? @hyperlink.start @hyperlink.end)))
            (item
                (expr "[" @hyperlink.start . "[" _  "]" . "]" @hyperlink.end
                    (#org-roam-is-valid-regular-link-range? @hyperlink.start @hyperlink.end)))
            (cell
                (contents ((expr "[" @hyperlink.start . "[" _) (expr _ "]" . "]" @hyperlink.end)
                    (#org-roam-is-valid-regular-link-range? @hyperlink.start @hyperlink.end))))
            (cell
                (contents (expr "[" @hyperlink.start . "[" _  "]" . "]" @hyperlink.end
                    (#org-roam-is-valid-regular-link-range? @hyperlink.start @hyperlink.end))))
            (drawer
                (contents ((expr "[" @hyperlink.start . "[" _) (expr _ "]" . "]" @hyperlink.end)
                    (#org-roam-is-valid-regular-link-range? @hyperlink.start @hyperlink.end))))
            (drawer
                (contents (expr "[" @hyperlink.start . "[" _  "]" . "]" @hyperlink.end
                    (#org-roam-is-valid-regular-link-range? @hyperlink.start @hyperlink.end))))
        ]
    ]=])

    ---@type org-roam.parser.Results
    local results = { drawers = {}, links = {} }
    for _, tree in ipairs(trees) do
        for pattern, match, _ in query:iter_matches(tree:root(), ref.value) do
            -- Currently, we handle three different patterns:
            --
            -- 1. Top Level Property Drawer: this shows up when we find a
            --                               normal drawer named PROPERTIES
            --                               that is not within a section.
            --
            -- 2. Section Property Drawer: this shows up when we find a
            --                             property drawer within a section.
            --
            -- 3. Regular Link: this shows up when we find a regullar link.
            --                  Angle, plain, and radio links do not match.
            --
            -- For the top-level property drawer, we have to parse out the
            -- properties and their values as we only have the overall contents.
            --
            -- For the property drawer, everything comes as expected.
            --
            -- For regular links, we have to parse out the link and the
            -- optional description as we only have an overall expression.
            if pattern == QUERY_TYPES.TOP_LEVEL_PROPERTY_DRAWER then
                ---@type org-roam.parser.Range|nil
                local range
                local properties = {}
                for id, node in pairs(match) do
                    local name = query.captures[id]

                    -- We only expect to deal with the full contents within a property
                    -- drawer in this situation.
                    --
                    -- :PROPERTIES:
                    -- ... <-- everything in here we need to parse
                    -- :END:
                    if name == QUERY_CAPTURE_TYPES.TOP_LEVEL_PROPERTY_DRAWER then
                        range = Range:from_node(node)
                    elseif name == QUERY_CAPTURE_TYPES.TOP_LEVEL_PROPERTY_DRAWER_CONTENTS then
                        -- Store the starting row and offset of drawer contents
                        -- so we can build up ranges for the lines within
                        local start_row, _, start_offset = node:start()

                        -- Get the lines within the drawer, which we will iterate through
                        -- NOTE: We do NOT skip empty lines!
                        local inner = vim.treesitter.get_node_text(node, ref.value)
                        local lines = vim.split(inner, "\n", { plain = true })
                        parse_lines_as_properties(properties, ref, lines, start_row, start_offset)
                    end
                end

                table.insert(results.drawers, PropertyDrawer:new({
                    range = assert(range, "Impossible: Failed to find range of top-level property drawer"),
                    properties = properties,
                }))
            elseif pattern == QUERY_TYPES.SECTION_PROPERTY_DRAWER then
                local range
                ---@type org-roam.parser.Property[]
                local properties = {}
                local heading_range
                local heading_stars

                -- TODO: Due to https://github.com/neovim/neovim/issues/17060, we cannot use iter_matches
                --       with a quantification using + in our query as the multiple node matches do not
                --       show up. Instead, we have to do a hack where we read the contents between the
                --       property drawer and parse them the same way as our top-level parser.
                for id, node in pairs(match) do
                    local name = query.captures[id]

                    if name == QUERY_CAPTURE_TYPES.SECTION_PROPERTY_DRAWER_HEADLINE then
                        heading_range = Range:from_node(node)
                    elseif name == QUERY_CAPTURE_TYPES.SECTION_PROPERTY_DRAWER_HEADLINE_STARS then
                        local stars = vim.treesitter.get_node_text(node, ref.value)
                        if type(stars) == "string" then
                            heading_stars = string.len(stars)
                        end
                    elseif name == QUERY_CAPTURE_TYPES.SECTION_PROPERTY_DRAWER then
                        range = Range:from_node(node)

                        -- Get the lines between the property drawer for us to manually parse
                        -- due to https://github.com/neovim/neovim/issues/17060 preventing us
                        -- from capturing multiple properties using quantification operators.
                        local all_lines = vim.split(vim.treesitter.get_node_text(node, ref.value), "\n", { plain = true })

                        -- Start row for properties is one line after :PROPERTIES:
                        local start_row = range.start.row + 1

                        -- Start offset for properties is one line after :PROPERTIES:\n
                        local start_offset = range.start.offset + string.len(all_lines[1]) + 1

                        local lines = {}
                        for i, line in ipairs(all_lines) do
                            if i > 1 and i < #all_lines then
                                table.insert(lines, line)
                            end
                        end

                        parse_lines_as_properties(properties, ref, lines, start_row, start_offset)
                    end
                end

                ---@type org-roam.parser.Heading|nil
                local heading
                if heading_range and heading_stars then
                    heading = Heading:new(heading_range, heading_stars)
                end

                table.insert(results.drawers, PropertyDrawer:new({
                    range = range,
                    properties = properties,
                    heading = heading,
                }))
            elseif pattern == QUERY_TYPES.REGULAR_LINK then
                ---@type org-roam.parser.Position
                local start = { row = 0, column = 0, offset = math.huge }
                ---@type org-roam.parser.Position
                local end_ = { row = 0, column = 0, offset = -1 }

                -- Find start and end of match
                for _, node in pairs(match) do
                    local start_row, start_col, offset_start = node:start()
                    local end_row, end_col, offset_end = node:end_()

                    local cur_start_offset = start.offset
                    local cur_end_offset = end_.offset

                    start.offset = math.min(start.offset, offset_start)
                    end_.offset = math.max(end_.offset, offset_end)

                    -- Start changed, so adjust row/col
                    if start.offset ~= cur_start_offset then
                        start.row = start_row
                        start.column = start_col
                    end

                    -- End changed, so adjust row/col
                    if end_.offset ~= cur_end_offset then
                        end_.row = end_row
                        end_.column = end_col
                    end
                end

                -- Create range from match scan
                local range = Range:new(start, end_)

                -- Get the raw link from the contents
                local raw_link = vim.trim(string.sub(ref.value, range.start.offset + 1, range.end_.offset + 1))

                -- Because Lua does not support modifiers on group patterns, we test for path & description
                -- first and then try just path second
                local _, _, path, description = string.find(raw_link, "^%[%[([^%c%z]*)%]%[([^%c%z]*)%]%]$")
                if path and description then
                    local link = Link:new({
                        kind = "regular",
                        range = range,
                        path = path,
                        description = description,
                    })
                    table.insert(results.links, link)
                else
                    local _, _, path = string.find(raw_link, "^%[%[([^%c%z]*)%]%]$")
                    if path then
                        local link = Link:new({
                            kind = "regular",
                            range = range,
                            path = path,
                        })
                        table.insert(results.links, link)
                    end
                end
            end
        end
    end
    return results
end

return M