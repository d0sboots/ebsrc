#!/usr/bin/python3

import sys

btz = sys.stdin.buffer.read()

def hexprint_range(r):
    lines = []
    addrs = list(range(r[0], r[1], 16)) + [r[1]]
    for i in range(len(addrs) - 1):
        substr = btz[addrs[i]:addrs[i+1]]
        lines.append('  "[' + " ".join(f'{x:02x}' for x in substr) + ']"')
    return "\n".join(lines)

range1 = [0x041A9E, 0x041BCA]
range2 = [0x04FD4B, 0x050000]

if len(btz) < range2[1]:
    raise ValueError(f"Input isn't long enough: 0x{len(btz):x} vs 0x{range2[1]:x}")

print(f"""
// This is a technical improvement to the speed of Earthbound's decomp
// routine - it speeds it up about 2x in terms of master clocks.
// For safety, add the following to used-ranges.yml:
//
// - (0x{range2[0]:06X}, 0x{range2[1]-1:06X})
//
// Otherwise, this should be a drop-in replacement without needing any other adjustments.

// The source code for this lives at https://github.com/d0sboots/ebsrc/tree/decomp_speed
// Look there for comments, explanation, and how this works.
// This ccscript version just has the compiled machine code.

// Copyright 2026 David Walker
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the “Software”),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.

// Replace the main definition of the decompression function.
ROM[0xC{range1[0]:05X}] = {{
{hexprint_range(range1)}
}}

// Add two 256-byte lookup tables, and some additional code that
// didn't fit in the main routine.
ROM[0xC{range2[0]:05X}] = {{
{hexprint_range(range2)}
}}
""".strip())
