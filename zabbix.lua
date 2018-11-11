
zabbix_protocol = Proto("Zabbix", "Zabbix Protocol")

p_header = ProtoField.string("zabbix.header", "Header", base.ASCII)
p_version = ProtoField.uint8("zabbix.version", "Version", base.DEC)
p_data_length = ProtoField.uint32("zabbix.len", "Length", base.DEC)
p_reserved = ProtoField.uint32("zabbix.reserved", "Reserved", base.DEC)
p_uncompressed_length = ProtoField.uint32("zabbix.uncompressedlen", "Uncompressed length", base.DEC)
p_data = ProtoField.string("zabbix.data", "Data", base.ASCII)
p_operation = ProtoField.string("zabbix.operation", "Operation", base.ASCII)
p_request = ProtoField.bool("zabbix.request", "Request")
p_response = ProtoField.bool("zabbix.response", "Response")
p_proxy_data_request = ProtoField.bool("zabbix.proxydatarequest", "Proxy Data Request")
p_proxy_tasks_request = ProtoField.bool("zabbix.proxytasksrequest", "Proxy Tasks Request")
p_proxy_response = ProtoField.bool("zabbix.proxyresponse", "Proxy Response")
p_server_response = ProtoField.bool("zabbix.serverresponse", "Proxy Server Response")

zabbix_protocol.fields = { p_header, p_version, p_data_length, p_reserved, p_uncompressed_length,
    p_data, p_operation, p_request, p_response, 
    p_proxy_data_request, p_proxy_tasks_request, p_proxy_response, p_server_response }

local default_settings =
{
    debug_level = DEBUG,
    ports = "10051", -- the default TCP port for Zabbix
    reassemble = true -- whether we try reassembly or not
}


-- ###############################################################################
function doDissect(buffer, pktinfo, tree)
    -- dissect the actual data from the tvb buffer

    -- get the data length and reserved fields (32-bit little-endian unsigned integers)
    local data_length = buffer(5,4):le_uint()
    local reserved = buffer(9,4):le_uint()

    -- get the data, remove the spaces for comparison for now
    local data_without_spaces = string.gsub(buffer(13):string(), " ", "")
    -- (note that we assumed that the full segment belongs to this same message)
    -- set default texts, then check for specific matches and change the texts as needed
    local operation = "Unknown"
    local tree_text = "Zabbix Protocol, Length: " .. data_length
    local info_text = "Zabbix Protocol, Len=" .. data_length .. " (" .. pktinfo.src_port .. " → " .. pktinfo.dst_port .. ")"
    if string.find(data_without_spaces, "\"request\":") then
        operation = "Request"
        tree_text = "Zabbix Request, Length: " .. data_length
        info_text = "Zabbix Request, Len=" .. data_length .. " (" .. pktinfo.src_port .. " → " .. pktinfo.dst_port .. ")"
    elseif string.find(data_without_spaces, "\"response\":") then
        operation = "Response"
        tree_text = "Zabbix Response, Length: " .. data_length
        info_text = "Zabbix Response, Len=" .. data_length .. " (" .. pktinfo.src_port .. " → " .. pktinfo.dst_port .. ")"
    end

    pktinfo.cols.info = info_text

    local subtree = tree:add(zabbix_protocol, buffer(), tree_text)
    subtree:add_le(p_header, buffer(0,4))
    subtree:add_le(p_version, buffer(4,1))
    subtree:add_le(p_data_length, buffer(5,4))
    subtree:add_le(p_reserved, buffer(9,4))
    local opertree = subtree:add(p_operation, operation):set_generated()
    if operation == "Request" then opertree:add(p_request,1):set_generated() else opertree:add(p_request,0):set_generated() end
    if operation == "Response" then opertree:add(p_response,1):set_generated() else opertree:add(p_response,0):set_generated() end
    subtree:add_le(p_data, buffer(13))
end

-- ###############################################################################
function doDissectCompressed(buffer, pktinfo, tree)
    local version = buffer(4,1):uint()
    local data_length = buffer(5,4):le_uint()
    local original_length = buffer(9,4):le_uint()
    local uncompressed_data = buffer(13):uncompress()
    local uncompressed_data_str = uncompressed_data:string()

    -- set default values, then modify them as needed:
    local operation = "(none)"
    local tree_text = "Zabbix Protocol, Version: " .. version .. ", Len: " .. data_length
    local info_text = "Zabbix Protocol, Version=" .. version .. ", Len=" .. data_length .. " (" .. pktinfo.src_port .. " → " .. pktinfo.dst_port .. ")"
    if string.find(uncompressed_data_str, "{\"request\":\"proxy data\"}") then
        -- {"request":"proxy data"}
        operation = "Proxy Data Request"
        tree_text = "Zabbix Request for Passive Proxy Data, Len: " .. data_length
        info_text = "Zabbix Request for Passive Proxy Data, Len=" .. data_length .. " (" .. pktinfo.src_port .. " → " .. pktinfo.dst_port .. ")"
    elseif string.find(uncompressed_data_str, "{\"request\":\"proxy tasks\"}") then
        -- {"request":"proxy tasks"}
        operation = "Proxy Tasks Request"
        tree_text = "Zabbix Request for Passive Proxy Tasks, Len: " .. data_length
        info_text = "Zabbix Request for Passive Proxy Tasks, Len=" .. data_length .. " (" .. pktinfo.src_port .. " → " .. pktinfo.dst_port .. ")"
    elseif string.find(uncompressed_data_str, "{\"session\":\"") then
        -- {"session":" ...
        operation = "Proxy Response"
        tree_text = "Zabbix Passive Proxy Response, Len: " .. data_length
        info_text = "Zabbix Passive Proxy Response, Len=" .. data_length .. " (" .. pktinfo.src_port .. " → " .. pktinfo.dst_port .. ")"
    elseif string.find(uncompressed_data_str, "{\"response\":\"") then
        -- {"response":" ...
        operation = "Server Response"
        tree_text = "Zabbix Server Response, Len: " .. data_length
        info_text = "Zabbix Server Response, Len=" .. data_length .. " (" .. pktinfo.src_port .. " → " .. pktinfo.dst_port .. ")"
    end

    pktinfo.cols.info = info_text

    local subtree = tree:add(zabbix_protocol, buffer(), tree_text)
    subtree:add_le(p_header, buffer(0,4))
    subtree:add_le(p_version, buffer(4,1), version, nil, "[Data is compressed]")
    subtree:add_le(p_data_length, buffer(5,4))
    subtree:add_le(p_uncompressed_length, buffer(9,4))
    subtree:add(buffer(13),"Data (" .. buffer(13):len() .. " bytes)")
    
    if operation ~= "(none)" then
        -- create a "generated" subtree for the True/False values
        local opertree = subtree:add(p_operation, operation):set_generated()
        if operation == "Proxy Data Request" then opertree:add(p_proxy_data_request,1):set_generated()
        else opertree:add(p_proxy_data_request,0):set_generated() end
        if operation == "Proxy Tasks Request" then opertree:add(p_proxy_tasks_request,1):set_generated()
        else opertree:add(p_proxy_tasks_request,0):set_generated() end
        if operation == "Proxy Response" then opertree:add(p_proxy_response,1):set_generated()
        else opertree:add(p_proxy_response,0):set_generated() end
        if operation == "Server Response" then opertree:add(p_server_response,1):set_generated()
        else opertree:add(p_server_response,0):set_generated() end
    end

    subtree:add(uncompressed_data,"[Uncompressed data]")

    return
end

-- #######################################
-- protocol dissector function
-- #######################################
function zabbix_protocol.dissector(buffer, pktinfo, tree)
    local ZBXD_HEADER_LEN = 13
    local pktlength = buffer:len()

    if pktlength < ZBXD_HEADER_LEN then
        -- cannot parse, return 0
        return 0
    end

    if buffer(0,4):string() ~= "ZBXD" then
        -- there is no ZBXD signature
        -- maybe this is encrypted, or not Zabbix after all
        return 0
    end

    -- set Protocol column manually to get it in mixed case instead of all caps
    pktinfo.cols.protocol = "Zabbix"

    -- set the default text for Info column, it will be overridden later if possible
    pktinfo.cols.info = "Zabbix data"

    -- get the protocol version and data length
    local version = buffer(4,1):uint()
    -- note the length field is only 4 bytes, verified from the Zabbix 4.0.0 sources, not 8 bytes
    -- the 4 next bytes are "reserved", used in version 3 (compressed) as shown later
    local data_length = buffer(5,4):le_uint()

    local bytes_needed = ZBXD_HEADER_LEN + data_length
    if bytes_needed > pktlength and default_settings.reassemble then
        -- we need more bytes than is in the current segment, try to get more
        pktinfo.desegment_offset = 0
        pktinfo.desegment_len = data_length + ZBXD_HEADER_LEN - pktlength
        -- dissect anyway to show something if the TCP setting "Allow subdissector to
        -- reassemble TCP streams" is disabled
        if version == 3 then
            -- 0x01 (ZBX_TCP_PROTOCOL) + 0x02 (ZBX_TCP_COMPRESS) -> this is compressed data
            doDissectCompressed(buffer, pktinfo, tree)
        else
            -- uncompressed (version 1) data or unknown version, just try to dissect
            doDissect(buffer, pktinfo, tree)
        end
        return
    end

    -- now we have the data to dissect, let's do it
    if version == 3 then
        -- 0x01 (ZBX_TCP_PROTOCOL) + 0x02 (ZBX_TCP_COMPRESS) -> this is compressed data
        doDissectCompressed(buffer, pktinfo, tree)
    else
        -- uncompressed (version 1) data or unknown version, just try to dissect
        doDissect(buffer, pktinfo, tree)
    end

    return
end


local function enableDissector()
    DissectorTable.get("tcp.port"):add(default_settings.ports, zabbix_protocol)
end
-- call it now, because we're enabled by default
enableDissector()

local function disableDissector()
    DissectorTable.get("tcp.port"):remove(default_settings.ports, zabbix_protocol)
end

-- register our preferences
zabbix_protocol.prefs.reassemble = Pref.bool("Reassemble Zabbix messages spanning multiple TCP segments",
    default_settings.reassemble, "Whether the Zabbix dissector should reassemble messages " ..
    "spanning multiple TCP segments. To use this option, you must also enable \"Allow subdissectors to " ..
    "reassemble TCP streams\" in the TCP protocol settings")

zabbix_protocol.prefs.ports = Pref.range("Port(s)", default_settings.ports, "Set the TCP port(s) for Zabbix, default is 10051", 65535)

zabbix_protocol.prefs.text = Pref.statictext("This dissector is written in Lua.","")


-- the function for handling preferences being changed
function zabbix_protocol.prefs_changed()
    if default_settings.reassemble ~= zabbix_protocol.prefs.reassemble then
        default_settings.reassemble = zabbix_protocol.prefs.reassemble
        -- capture file reload needed
        reload()
    elseif default_settings.ports ~= zabbix_protocol.prefs.ports then
        disableDissector()
        default_settings.ports = zabbix_protocol.prefs.ports
        enableDissector()
    end
end