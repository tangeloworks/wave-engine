-- Pure-Lua Zstandard (RFC 8878) frame decompressor, used by binary.lua for
-- .rbxl chunks that Roblox Studio writes with zstd instead of LZ4.
--
-- The entropy stages (FSE table construction, Huffman weight decode and the
-- interleaved sequence bitstream) are ported from fzstd by Arjun Barrett,
-- https://github.com/101arrowz/fzstd, under the MIT License:
--
--     Copyright (c) 2020 Arjun Barrett
--
--     Permission is hereby granted, free of charge, to any person obtaining a
--     copy of this software and associated documentation files (the
--     "Software"), to deal in the Software without restriction, including
--     without limitation the rights to use, copy, modify, merge, publish,
--     distribute, sublicense, and/or sell copies of the Software, and to
--     permit persons to whom the Software is furnished to do so, subject to
--     the following conditions:
--
--     The above copyright notice and this permission notice shall be included
--     in all copies or substantial portions of the Software.
--
--     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
--     OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
--     MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
--     IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
--     CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
--     TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
--     SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- fzstd reads by absolute bit position, which maps cleanly onto Lua string
-- indexing. Sequence execution differs: it copies into one growing output
-- buffer that doubles as the back-reference window. Positions stay below
-- 2^31, so the LuaJIT `bit` (or Lua 5.2 `bit32`) shifts are safe.

local bit = rawget(_G, "bit") or rawget(_G, "bit32")
if not bit then
    error("rbx zstd backend requires the bit or bit32 library")
end

local band, bor = bit.band, bit.bor
local lshift, rshift = bit.lshift, bit.rshift
local byte = string.byte
local schar = string.char
local ssub = string.sub
local concat = table.concat
local unpack_fn = table.unpack or unpack
local floor = math.floor
local min = math.min

local zstd = {}

-- 0-based byte access into a Lua string, out-of-range reads as 0, matching the
-- Uint8Array semantics the reference relies on when it peeks past the end
local function B(s, i)
    return byte(s, i + 1) or 0
end

-- floor(log2(v)) for v >= 1, and -1 for v == 0. Multiply avoids the sign wrap a
-- left shift would hit near bit 31, every caller passes a small value anyway
local function msb(v)
    local b = -1
    local p = 1
    while p <= v do
        p = p * 2
        b = b + 1
    end
    return b
end

-- Literal-length / match-length extra-bit and baseline tables (RFC 8878 3.1.1.3),
-- indexed by code starting at 0. Offset codes carry their own bit count inline
local LLB = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }
local LLBL = { [0] = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
    8192, 16384, 32768, 65536 }
local MLB = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }
local MLBL = { [0] = 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
    19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
    35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
    4099, 8195, 16387, 32771, 65539 }

-- read a Finite State Entropy table description (forward bitstream) starting at
-- byte `bt`, returns the byte offset just past the description and the decode
-- table { b = accuracyLog, s = symbols, n = nbBits, t = nextStateBase }
local function read_fse(src, bt, max_accuracy_log)
    local tpos = lshift(bt, 3) + 4
    local al = band(B(src, bt), 15) + 5
    if al > max_accuracy_log then
        error("zstd: FSE accuracy log too high")
    end
    local sz = lshift(1, al)
    local probs = sz
    local sym = -1
    local ht = sz
    local freq = {}
    local syms = {}

    while sym < 255 and probs > 0 do
        local bits = msb(probs + 1)
        local cbt = rshift(tpos, 3)
        local msk = lshift(1, bits + 1) - 1
        local val = band(rshift(bor(B(src, cbt), lshift(B(src, cbt + 1), 8), lshift(B(src, cbt + 2), 16)), band(tpos, 7)), msk)
        local msk1fb = lshift(1, bits) - 1
        local msv = msk - probs - 1
        local sval = band(val, msk1fb)
        if sval < msv then
            tpos = tpos + bits
            val = sval
        else
            tpos = tpos + bits + 1
            if val > msk1fb then
                val = val - msv
            end
        end
        val = val - 1
        sym = sym + 1
        freq[sym] = val
        if val == -1 then
            probs = probs + val
            ht = ht - 1
            syms[ht] = sym
        else
            probs = probs - val
        end
        if val == 0 then
            local re
            repeat
                local rbt = rshift(tpos, 3)
                re = band(rshift(bor(B(src, rbt), lshift(B(src, rbt + 1), 8)), band(tpos, 7)), 3)
                tpos = tpos + 2
                sym = sym + re
            until re ~= 3
        end
    end
    if sym > 255 or probs ~= 0 then
        error("zstd: invalid FSE distribution")
    end

    local dstate = {}
    local sympos = 0
    local sstep = rshift(sz, 1) + rshift(sz, 3) + 3
    local smask = sz - 1
    for s = 0, sym do
        local sf = freq[s] or 0
        if sf < 1 then
            dstate[s] = -sf
        else
            dstate[s] = sf
            for _ = 1, sf do
                syms[sympos] = s
                repeat
                    sympos = band(sympos + sstep, smask)
                until sympos < ht
            end
        end
    end
    if sympos ~= 0 then
        error("zstd: FSE symbol spread mismatch")
    end

    local nbits = {}
    local nstate = {}
    for i = 0, sz - 1 do
        local s = syms[i]
        local ns = dstate[s]
        dstate[s] = ns + 1
        local nb = al - msb(ns)
        nbits[i] = nb
        nstate[i] = lshift(ns, nb) - sz
    end

    return rshift(tpos + 7, 3), { b = al, s = syms, n = nbits, t = nstate }
end

-- read a Huffman tree description starting at byte `bt`, returns the byte offset
-- just past it and a decode table { b = maxBits, s = symbols, n = nbBits }
local function read_huffman(src, bt)
    local hb = B(src, bt)
    local hw = {}
    local wc

    if hb < 128 then
        -- weights are themselves FSE-compressed
        local ebt, fdt = read_fse(src, bt + 1, 6)
        bt = bt + hb
        local epos = lshift(ebt, 3)
        local lb = B(src, bt)
        if lb == 0 then
            error("zstd: invalid Huffman weight stream")
        end
        local st1, st2 = 0, 0
        local btr1 = fdt.b
        local btr2 = btr1
        local fs, fn, ft = fdt.s, fdt.n, fdt.t
        bt = bt + 1
        local fpos = lshift(bt, 3) - 8 + msb(lb)
        wc = -1
        while true do
            fpos = fpos - btr1
            if fpos < epos then break end
            local cbt = rshift(fpos, 3)
            st1 = st1 + band(rshift(bor(B(src, cbt), lshift(B(src, cbt + 1), 8)), band(fpos, 7)), lshift(1, btr1) - 1)
            wc = wc + 1
            hw[wc] = fs[st1]
            fpos = fpos - btr2
            if fpos < epos then break end
            cbt = rshift(fpos, 3)
            st2 = st2 + band(rshift(bor(B(src, cbt), lshift(B(src, cbt + 1), 8)), band(fpos, 7)), lshift(1, btr2) - 1)
            wc = wc + 1
            hw[wc] = fs[st2]
            btr1 = fn[st1]; st1 = ft[st1]
            btr2 = fn[st2]; st2 = ft[st2]
        end
        wc = wc + 1
        if wc > 255 then
            error("zstd: too many Huffman weights")
        end
    else
        -- weights stored directly, 4 bits each
        wc = hb - 127
        local i = 0
        while i < wc do
            bt = bt + 1
            local b = B(src, bt)
            hw[i] = rshift(b, 4)
            hw[i + 1] = band(b, 15)
            i = i + 2
        end
        bt = bt + 1
    end

    -- derive the implicit final weight, then per-symbol bit lengths
    local wes = 0
    for i = 0, wc - 1 do
        local wt = hw[i]
        if wt > 11 then
            error("zstd: Huffman weight out of range")
        end
        if wt ~= 0 then
            wes = wes + lshift(1, wt - 1)
        end
    end
    local mb = msb(wes) + 1
    local ts = lshift(1, mb)
    local rem = ts - wes
    if band(rem, rem - 1) ~= 0 then
        error("zstd: invalid Huffman weight total")
    end
    hw[wc] = msb(rem) + 1
    wc = wc + 1

    local rc = {}
    for i = 0, 11 do rc[i] = 0 end
    for i = 0, wc - 1 do
        local wt = hw[i]
        local nbv = (wt ~= 0) and (mb + 1 - wt) or 0
        hw[i] = nbv
        rc[nbv] = rc[nbv] + 1
    end

    local ri = {}
    ri[mb] = 0
    local nb = {}
    for i = mb, 1, -1 do
        local pv = ri[i]
        local nxt = pv + rc[i] * lshift(1, mb - i)
        ri[i - 1] = nxt
        for k = pv, nxt - 1 do nb[k] = i end
    end
    if ri[0] ~= ts then
        error("zstd: Huffman table build mismatch")
    end
    local syms = {}
    for i = 0, wc - 1 do
        local bits = hw[i]
        if bits ~= 0 then
            local code = ri[bits]
            local nxt = code + lshift(1, mb - bits)
            ri[bits] = nxt
            for k = code, nxt - 1 do syms[k] = i end
        end
    end

    return bt, { b = mb, s = syms, n = nb }
end

-- decode a single Huffman-coded literal stream into out[start .. start+count-1]
local function decode_huffman_stream(dat, out, start, count, hu)
    if count <= 0 then return end
    local len = #dat
    local lb = byte(dat, len) or 0
    if lb == 0 then
        error("zstd: invalid Huffman literal stream")
    end
    local hub = hu.b
    local hsyms, hnb = hu.s, hu.n
    local msk = lshift(1, hub) - 1
    local eb = -hub
    local st = 0
    local btr = hub
    local pos = lshift(len, 3) - 8 + msb(lb) - btr
    local i = -1
    while pos > eb and i < count do
        -- pos runs down to eb = -hub, so it can go negative near the stream
        -- start, use signed floor-division (an arithmetic shift) here, not the
        -- unsigned rshift, or the final symbol reads from a bogus byte index
        local cbt = floor(pos / 8)
        local val = rshift(bor(B(dat, cbt), lshift(B(dat, cbt + 1), 8), lshift(B(dat, cbt + 2), 16)), band(pos, 7))
        st = band(bor(lshift(st, btr), val), msk)
        i = i + 1
        out[start + i] = hsyms[st]
        btr = hnb[st]
        pos = pos - btr
    end
    if pos ~= eb or i + 1 ~= count then
        error("zstd: Huffman literal stream did not consume exactly")
    end
end

-- decode the 4-stream Huffman literal layout (6-byte jump table + 4 streams)
local function decode_huffman_4x(dat, out, start, count, hu)
    local sz1 = rshift(count + 3, 2)
    local sz2 = sz1 * 2
    local sz3 = sz1 + sz2
    local j0 = bor(B(dat, 0), lshift(B(dat, 1), 8))
    local j1 = bor(B(dat, 2), lshift(B(dat, 3), 8))
    local j2 = bor(B(dat, 4), lshift(B(dat, 5), 8))
    local p = 6
    decode_huffman_stream(ssub(dat, p + 1, p + j0), out, start, sz1, hu); p = p + j0
    decode_huffman_stream(ssub(dat, p + 1, p + j1), out, start + sz1, sz1, hu); p = p + j1
    decode_huffman_stream(ssub(dat, p + 1, p + j2), out, start + sz2, sz1, hu); p = p + j2
    decode_huffman_stream(ssub(dat, p + 1, #dat), out, start + sz3, count - sz3, hu)
end

-- forward-declared default sequence FSE tables (built below)
local default_ml, default_of, default_ll

-- decode one compressed (btype 2) block into `out`, appending after `y` bytes
-- `state` carries the repeat offsets and the previous Huffman/FSE tables so the
-- treeless-literal and FSE-repeat modes can reuse them across blocks
local function decode_compressed_block(src, bt, ebt, out, y, state)
    local b3 = B(src, bt)
    local lbt = band(b3, 3)
    local sf = band(rshift(b3, 2), 3)
    local lss = rshift(b3, 4)
    local lcs = 0
    local s4 = 0

    if lbt < 2 then
        if band(sf, 1) ~= 0 then
            bt = bt + 1
            local v = lshift(B(src, bt), 4)
            if band(sf, 2) ~= 0 then
                bt = bt + 1
                v = bor(v, lshift(B(src, bt), 12))
            end
            lss = bor(lss, v)
        else
            lss = rshift(b3, 3)
        end
    else
        s4 = sf
        if sf < 2 then
            bt = bt + 1; local x = B(src, bt)
            lss = bor(lss, lshift(band(x, 63), 4))
            bt = bt + 1; local yb = B(src, bt)
            lcs = bor(rshift(x, 6), lshift(yb, 2))
        elseif sf == 2 then
            bt = bt + 1; local x = B(src, bt)
            bt = bt + 1; local yb = B(src, bt)
            lss = bor(lss, lshift(x, 4), lshift(band(yb, 3), 12))
            bt = bt + 1; local zb = B(src, bt)
            lcs = bor(rshift(yb, 2), lshift(zb, 6))
        else
            bt = bt + 1; local x = B(src, bt)
            bt = bt + 1; local yb = B(src, bt)
            lss = bor(lss, lshift(x, 4), lshift(band(yb, 63), 12))
            bt = bt + 1; local zb = B(src, bt)
            bt = bt + 1; local wb = B(src, bt)
            lcs = bor(rshift(yb, 6), lshift(zb, 2), lshift(wb, 10))
        end
    end
    bt = bt + 1

    -- literals section
    local lit = {}
    if lbt == 0 then
        for k = 0, lss - 1 do lit[k + 1] = B(src, bt + k) end
        bt = bt + lss
    elseif lbt == 1 then
        local v = B(src, bt); bt = bt + 1
        for k = 1, lss do lit[k] = v end
    else
        local hu = state.h
        if lbt == 2 then
            local newbt, hud = read_huffman(src, bt)
            lcs = lcs - (newbt - bt)
            bt = newbt
            state.h = hud
            hu = hud
        elseif not hu then
            error("zstd: treeless literals with no prior Huffman table")
        end
        local stream = ssub(src, bt + 1, bt + lcs)
        if lss > 0 then
            if s4 ~= 0 then
                decode_huffman_4x(stream, lit, 1, lss, hu)
            else
                decode_huffman_stream(stream, lit, 1, lss, hu)
            end
        end
        bt = bt + lcs
    end

    -- sequences section
    local ns = B(src, bt); bt = bt + 1
    if ns == 0 then
        for k = 1, lss do out[y + k] = lit[k] end
        return y + lss
    end
    if ns == 255 then
        ns = bor(B(src, bt), lshift(B(src, bt + 1), 8)) + 0x7F00
        bt = bt + 2
    elseif ns > 127 then
        ns = bor(lshift(ns - 128, 8), B(src, bt))
        bt = bt + 1
    end

    local scm = B(src, bt); bt = bt + 1
    if band(scm, 3) ~= 0 then
        error("zstd: reserved sequence compression bits set")
    end
    local dts = { [0] = default_ml, [1] = default_of, [2] = default_ll }
    for i = 2, 0, -1 do
        local md = band(rshift(scm, (i * 2) + 2), 3)
        if md == 1 then
            local rv = B(src, bt); bt = bt + 1
            dts[i] = { s = { [0] = rv }, n = { [0] = 0 }, t = { [0] = 0 }, b = 0 }
        elseif md == 2 then
            local newbt, tbl = read_fse(src, bt, 9 - band(i, 1))
            bt = newbt
            dts[i] = tbl
        elseif md == 3 then
            local prev = state.t
            if not prev then
                error("zstd: FSE repeat mode with no prior table")
            end
            dts[i] = prev[i]
        end
    end
    state.t = dts
    local mlt, oct, llt = dts[0], dts[1], dts[2]

    -- interleaved LL/OF/ML bitstream, read backwards from the block tail
    local lb = B(src, ebt - 1)
    if lb == 0 then
        error("zstd: invalid sequence bitstream")
    end
    local spos = lshift(ebt, 3) - 8 + msb(lb) - llt.b
    local cbt = rshift(spos, 3)
    local lst = band(rshift(bor(B(src, cbt), lshift(B(src, cbt + 1), 8)), band(spos, 7)), lshift(1, llt.b) - 1)
    spos = spos - oct.b; cbt = rshift(spos, 3)
    local ost = band(rshift(bor(B(src, cbt), lshift(B(src, cbt + 1), 8)), band(spos, 7)), lshift(1, oct.b) - 1)
    spos = spos - mlt.b; cbt = rshift(spos, 3)
    local mst = band(rshift(bor(B(src, cbt), lshift(B(src, cbt + 1), 8)), band(spos, 7)), lshift(1, mlt.b) - 1)

    local lls, lln, llt_t = llt.s, llt.n, llt.t
    local mls, mln, mlt_t = mlt.s, mlt.n, mlt.t
    local ofs, ofn, oct_t = oct.s, oct.n, oct.t
    local o1, o2, o3 = state.o[1], state.o[2], state.o[3]
    local litpos = 0

    for _ = 1, ns do
        local llc = lls[lst]; local lbtr = lln[lst]
        local mlc = mls[mst]; local mbtr = mln[mst]
        local ofc = ofs[ost]; local obtr = ofn[ost]

        spos = spos - ofc; cbt = rshift(spos, 3)
        local ofp = lshift(1, ofc)
        local off = ofp + band(rshift(bor(B(src, cbt), lshift(B(src, cbt + 1), 8), lshift(B(src, cbt + 2), 16), lshift(B(src, cbt + 3), 24)), band(spos, 7)), ofp - 1)

        local mlbits = MLB[mlc]
        spos = spos - mlbits; cbt = rshift(spos, 3)
        local ml = MLBL[mlc] + band(rshift(bor(B(src, cbt), lshift(B(src, cbt + 1), 8), lshift(B(src, cbt + 2), 16)), band(spos, 7)), lshift(1, mlbits) - 1)

        local llbits = LLB[llc]
        spos = spos - llbits; cbt = rshift(spos, 3)
        local ll = LLBL[llc] + band(rshift(bor(B(src, cbt), lshift(B(src, cbt + 1), 8), lshift(B(src, cbt + 2), 16)), band(spos, 7)), lshift(1, llbits) - 1)

        spos = spos - lbtr; cbt = rshift(spos, 3)
        lst = llt_t[lst] + band(rshift(bor(B(src, cbt), lshift(B(src, cbt + 1), 8)), band(spos, 7)), lshift(1, lbtr) - 1)
        spos = spos - mbtr; cbt = rshift(spos, 3)
        mst = mlt_t[mst] + band(rshift(bor(B(src, cbt), lshift(B(src, cbt + 1), 8)), band(spos, 7)), lshift(1, mbtr) - 1)
        spos = spos - obtr; cbt = rshift(spos, 3)
        ost = oct_t[ost] + band(rshift(bor(B(src, cbt), lshift(B(src, cbt + 1), 8)), band(spos, 7)), lshift(1, obtr) - 1)

        local realoff
        if off > 3 then
            o3 = o2; o2 = o1; o1 = off - 3; realoff = o1
        else
            local idx = off - ((ll ~= 0) and 1 or 0)
            if idx ~= 0 then
                if idx == 3 then
                    realoff = o1 - 1
                elseif idx == 1 then
                    realoff = o2
                else
                    realoff = o3
                end
                if idx > 1 then o3 = o2 end
                o2 = o1; o1 = realoff
            else
                realoff = o1
            end
        end

        for k = 1, ll do out[y + k] = lit[litpos + k] end
        y = y + ll; litpos = litpos + ll
        local msrc = y - realoff
        for k = 1, ml do out[y + k] = out[msrc + k] end
        y = y + ml
    end

    for k = litpos + 1, lss do
        y = y + 1
        out[y] = lit[k]
    end
    state.o[1], state.o[2], state.o[3] = o1, o2, o3
    return y
end

local function bytes_to_string(t, n)
    if n == 0 then return "" end
    local parts = {}
    local pi = 0
    local k = 1
    while k <= n do
        local j = min(k + 4095, n)
        pi = pi + 1
        parts[pi] = schar(unpack_fn(t, k, j))
        k = j + 1
    end
    return concat(parts)
end

-- Decompress a single zstd frame (`src`). `expected_size`, when provided, is the
-- caller's known output length (from the chunk header) and is used only for a
-- final sanity check, the block loop determines the real size regardless
--
-- returns the decompressed string plus the number of INPUT bytes the frame
-- occupied. the second return exists for multi-frame payloads (CSGPHS v8 stores
-- a frame count then that many back-to-back frames with no offset table), where
-- the only way to find frame N+1 is to know where frame N ended. existing
-- single-frame callers keep working -- an extra return value is dropped
function zstd.decompress(src, expected_size)
    local n3 = bor(B(src, 0), lshift(B(src, 1), 8), lshift(B(src, 2), 16))
    if n3 ~= 0x2FB528 or B(src, 3) ~= 253 then
        error("zstd: not a Zstandard frame")
    end
    local flg = B(src, 4)
    local single_segment = band(rshift(flg, 5), 1)
    local has_checksum = band(rshift(flg, 2), 1)
    local dict_flag = band(flg, 3)
    local fcf = rshift(flg, 6)
    if band(flg, 8) ~= 0 then
        error("zstd: reserved frame header bit set")
    end
    local bt = 6 - single_segment
    bt = bt + ((dict_flag == 3) and 4 or dict_flag)
    bt = bt + ((fcf ~= 0) and lshift(1, fcf) or single_segment)

    local out = {}
    local y = 0
    local state = { o = { 1, 4, 8 }, h = nil, t = nil }
    local src_len = #src

    while true do
        -- a corrupt frame whose last-block flag never appears would otherwise
        -- spin forever reading zero bytes past the end (B() returns 0), so bail
        -- once a block header can no longer fit in the payload
        if bt + 3 > src_len then
            error("zstd: frame ended without a last block (truncated or corrupt)")
        end
        local b0 = B(src, bt)
        local last_flag = band(b0, 1)
        local btype = band(rshift(b0, 1), 3)
        local sz = bor(rshift(b0, 3), lshift(B(src, bt + 1), 5), lshift(B(src, bt + 2), 13))
        bt = bt + 3
        if btype == 0 then
            for k = 0, sz - 1 do out[y + 1 + k] = B(src, bt + k) end
            y = y + sz
            bt = bt + sz
        elseif btype == 1 then
            local v = B(src, bt)
            for k = 1, sz do out[y + k] = v end
            y = y + sz
            bt = bt + 1
        elseif btype == 2 then
            y = decode_compressed_block(src, bt, bt + sz, out, y, state)
            bt = bt + sz
        else
            error("zstd: reserved block type")
        end
        -- guard against a corrupt block claiming far more output than the chunk
        -- header promised (bounds the output table so a bad frame can't balloon)
        if expected_size and y > expected_size then
            error("zstd: decoded output exceeded expected size")
        end
        if last_flag ~= 0 then break end
    end

    if has_checksum == 1 then
        bt = bt + 4
    end

    if expected_size and y ~= expected_size then
        error(string.format("zstd: size mismatch (got %d, expected %d)", y, expected_size))
    end
    return bytes_to_string(out, y), bt
end

-- default sequence FSE tables (built from the RFC default distributions,
-- encoded here as the raw table descriptions the reference uses)
default_ll = select(2, read_fse(schar(
    81, 16, 99, 140, 49, 198, 24, 99, 12, 33, 196, 24, 99, 102, 102, 134, 70, 146, 4), 0, 6))
default_ml = select(2, read_fse(schar(
    33, 20, 196, 24, 99, 140, 33, 132, 16, 66, 8, 33, 132, 16, 66, 8, 33, 68, 68, 68, 68, 68, 68, 68, 68, 36, 9), 0, 6))
default_of = select(2, read_fse(schar(
    32, 132, 16, 66, 102, 70, 68, 68, 68, 68, 36, 73, 2), 0, 5))

return zstd
