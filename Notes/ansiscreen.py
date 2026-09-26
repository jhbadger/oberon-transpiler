#!/usr/bin/env python3
"""Render an ANSI/VT100 byte stream as the text a terminal would show.

frotz drives a real screen (cursor positioning, line deletion, scroll
regions), so piping it to a file gives interleaved escape codes rather than
the game's text in order. This replays the stream onto a grid and, with
--scroll, also keeps every line that scrolled off the top, which is what you
want for reading a transcript.
"""
import sys, re, argparse

ap = argparse.ArgumentParser()
ap.add_argument("--rows", type=int, default=24)
ap.add_argument("--cols", type=int, default=80)
ap.add_argument("--scroll", action="store_true", help="also print lines that scrolled off")
a = ap.parse_args()

R, C = a.rows, a.cols
grid = [[" "] * C for _ in range(R)]
scrollback = []
cy = cx = 0
top, bot = 0, R - 1
saved = (0, 0)

def scroll_up(n=1):
    global grid
    for _ in range(n):
        if a.scroll:
            scrollback.append("".join(grid[top]).rstrip())
        del grid[top]
        grid.insert(bot, [" "] * C)

data = sys.stdin.buffer.read().decode("latin-1")
i = 0
csi = re.compile(r"\[([0-9;?]*)([A-Za-z@])")
while i < len(data):
    ch = data[i]
    if ch == "\x1b":
        m = csi.match(data, i + 1)
        if m:
            params, cmd = m.group(1), m.group(2)
            nums = [int(p) for p in params.split(";") if p.isdigit()]
            n = nums[0] if nums else 0
            if cmd == "H" or cmd == "f":
                cy = (nums[0] - 1) if len(nums) > 0 else 0
                cx = (nums[1] - 1) if len(nums) > 1 else 0
            elif cmd == "d":
                cy = (n - 1) if n else 0
            elif cmd == "G":
                cx = (n - 1) if n else 0
            elif cmd == "A": cy -= max(n, 1)
            elif cmd == "B": cy += max(n, 1)
            elif cmd == "C": cx += max(n, 1)
            elif cmd == "D": cx -= max(n, 1)
            elif cmd == "b":                      # repeat last char
                for _ in range(max(n, 1)):
                    if 0 <= cy < R and 0 <= cx < C:
                        grid[cy][cx] = last
                    cx += 1
            elif cmd == "J":
                if n in (0, 2):
                    start = 0 if n == 2 else cy
                    for y in range(start, R):
                        grid[y] = [" "] * C
            elif cmd == "K":
                if 0 <= cy < R:
                    if n == 0:
                        for x in range(cx, C): grid[cy][x] = " "
                    elif n == 1:
                        for x in range(0, min(cx + 1, C)): grid[cy][x] = " "
                    else:
                        grid[cy] = [" "] * C
            elif cmd == "M":                      # delete lines at cursor
                for _ in range(max(n, 1)):
                    if a.scroll and 0 <= cy < R:
                        scrollback.append("".join(grid[cy]).rstrip())
                    if 0 <= cy < R:
                        del grid[cy]; grid.insert(bot, [" "] * C)
            elif cmd == "L":                      # insert lines
                for _ in range(max(n, 1)):
                    if 0 <= cy < R:
                        grid.insert(cy, [" "] * C); del grid[bot + 1]
            elif cmd == "r":
                top = (nums[0] - 1) if len(nums) > 0 else 0
                bot = (nums[1] - 1) if len(nums) > 1 else R - 1
            i = m.end()
            continue
        if data[i + 1 : i + 2] in ("(", ")", "#"):
            i += 3; continue
        if data[i + 1 : i + 2] == "7": saved = (cy, cx); i += 2; continue
        if data[i + 1 : i + 2] == "8": cy, cx = saved; i += 2; continue
        i += 2; continue
    if ch == "\r":
        cx = 0
    elif ch == "\n":
        cy += 1
        if cy > bot: scroll_up(cy - bot); cy = bot
    elif ch == "\b":
        cx = max(0, cx - 1)
    elif ch == "\t":
        cx = (cx // 8 + 1) * 8
    elif ch >= " ":
        if cx >= C:
            cx = 0; cy += 1
            if cy > bot: scroll_up(cy - bot); cy = bot
        if 0 <= cy < R:
            grid[cy][cx] = ch
        last = ch
        cx += 1
    i += 1

out = scrollback + ["".join(row).rstrip() for row in grid]
# collapse runs of blank lines so the padding at the bottom doesn't dominate
res, blank = [], 0
for line in out:
    if line.strip():
        res.append(line); blank = 0
    else:
        blank += 1
        if blank <= 1: res.append("")
print("\n".join(res))
