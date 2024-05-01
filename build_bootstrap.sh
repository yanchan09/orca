#!/bin/sh

# SPDX-FileCopyrightText: 2024 yanchan09 <yan@omg.lol>
#
# SPDX-License-Identifier: MPL-2.0

set -e

zig build-exe -O ReleaseSafe -fstrip bootstrap.zig
zig build-exe -O ReleaseSafe -fstrip walls.zig
mv bootstrap bootstrap-root/init
mv walls bootstrap-root/walls
./mkinitramfs.sh bootstrap-root crack/bootstrap.cpio
