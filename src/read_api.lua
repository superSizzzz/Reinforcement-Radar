-- Read-only process memory access for Helldivers 2.
--
-- Declares only GetModuleHandleA, GetCurrentProcess, ReadProcessMemory and
-- GetTickCount64. There is no write, protection or allocation call anywhere in
-- this module, and the build refuses to assemble if one appears.
--
-- Every read validates the address range first and returns nil instead of
-- raising, so probing a speculative pointer is safe.

return function()
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')

    ffi.cdef [[
        void *GetModuleHandleA(const char *name);
        void *GetCurrentProcess(void);
        uint64_t GetTickCount64(void);
        int ReadProcessMemory(void *process, const void *address, void *buffer,
                              size_t size, size_t *read);
    ]]

    local kernel = ffi.load('kernel32')
    local process = kernel.GetCurrentProcess()

    local u16buf = ffi.new('uint16_t[1]')
    local u32buf = ffi.new('uint32_t[1]')
    local u64buf = ffi.new('uint64_t[1]')
    local f32buf = ffi.new('float[1]')

    local MIN_ADDRESS = 65536
    local MAX_ADDRESS = 140737488355328  -- 0x800000000000
    local MAX_READ = 2097152             -- 2 MiB, same ceiling as the proven reader

    local api = {}

    -- Base address of a loaded module. nil for the main executable.
    --
    -- GetModuleHandleA yields an opaque void* cdata, and tonumber() does NOT
    -- accept a pointer cdata directly -- it returns nil. The cast to uintptr_t
    -- first is what makes the conversion work. Verified against the live game:
    -- the handle came back as cdata with GetLastError()==0, and only the
    -- conversion was failing.
    function api.module(name)
        local handle = kernel.GetModuleHandleA(name)
        if handle == nil then return nil end
        return tonumber(ffi.cast('uintptr_t', handle))
    end

    function api.time()
        return tonumber(kernel.GetTickCount64()) / 1000
    end

    -- Read `size` bytes. Returns nil for an unmapped or partly readable range.
    function api.read(address, size)
        if type(address) ~= 'number' or type(size) ~= 'number' then return nil end
        if address < MIN_ADDRESS or address >= MAX_ADDRESS then return nil end
        if size < 1 or size > MAX_READ then return nil end
        local buffer = ffi.new('uint8_t[?]', size)
        local count = ffi.new('size_t[1]')
        local ok = kernel.ReadProcessMemory(process, ffi.cast('const void *', address),
                                            buffer, size, count)
        if ok == 0 or tonumber(count[0]) ~= size then return nil end
        return ffi.string(buffer, size)
    end

    local function scalar(address, ctype, buffer, size)
        if type(address) ~= 'number' then return nil end
        local bytes = api.read(address, size)
        if not bytes then return nil end
        ffi.copy(buffer, bytes, size)
        return tonumber(buffer[0])
    end

    function api.u8(address)
        local bytes = api.read(address, 1)
        if not bytes then return nil end
        return bytes:byte(1)
    end

    function api.u16(address) return scalar(address, 'uint16_t', u16buf, 2) end
    function api.u32(address) return scalar(address, 'uint32_t', u32buf, 4) end
    function api.f32(address) return scalar(address, 'float', f32buf, 4) end

    -- Read 8 bytes at `address` as an unsigned 64-bit integer.
    function api.u64(address)
        return scalar(address, 'uint64_t', u64buf, 8)
    end

    -- Follow a pointer stored at `address`, rejecting null and implausible values.
    function api.pointer(address)
        local value = api.u64(address)
        if value == nil or value < MIN_ADDRESS or value >= MAX_ADDRESS then return nil end
        return value
    end

    -- A finite float is the cheapest sanity check on a raw field.
    function api.finite(value, maximum)
        if type(value) ~= 'number' then return false end
        if value ~= value then return false end
        return math.abs(value) <= (maximum or 1000000)
    end

    return api
end
