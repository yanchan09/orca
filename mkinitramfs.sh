#!/bin/sh

# SPDX-FileCopyrightText: 2006 Rob Landley <rob@landley.net>
# SPDX-FileCopyrightText: 2006 TimeSys Corporation
# SPDX-FileCopyrightText: 2024 yanchan09 <yan@omg.lol>
#
# SPDX-License-Identifier: GPL-2.0-only

if [ $# -ne 2 ]
then
  echo "usage: mkinitramfs directory imagename.cpio"
  exit 1
fi

if [ -d "$1" ]
then
  echo "creating $2 from $1"
  (cd "$1"; find . | cpio -o -H newc) > "$2"
else
  echo "First argument must be a directory"
  exit 1
fi

