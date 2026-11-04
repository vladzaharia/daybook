#!/bin/bash
# Gives every tracked file a modification time that follows from its content, so a file that hasn't changed
# has the same time in every checkout. Xcode and SwiftPM rebuild what changed by modification time, and a
# checkout dates every file now, so without this a restored build cache recompiles all of Daybook's own code.
#
#   scripts/ci/stable-mtimes.sh [DIRECTORY]     default: the repository holding this script
#
# The time is 2000-01-01 plus the first 28 bits of the file's blob hash, so it falls in 2000–2008: the same
# content always gets the same time, and different content a different one. Symbolic links, submodules, and
# files edited since the last `git add` (whose content isn't the one Git has a hash for) are left alone.
set -euo pipefail

directory="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$directory"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "stable-mtimes.sh: $directory isn't a Git checkout" >&2; exit 2; }
git ls-files --stage -z | perl -0 -ne '
    BEGIN { %edited = map { $_ => 1 } split /\0/, qx(git diff --name-only -z) }
    chomp;
    my ($meta, $path) = split /\t/, $_, 2;
    my ($mode, $blob) = split / /, $meta;
    next if $mode eq "120000" || $mode eq "160000" || $edited{$path} || !-f $path;
    my $time = 946684800 + hex(substr($blob, 0, 7));
    utime($time, $time, $path) or die "stable-mtimes.sh: $path: $!\n";
    $count++;
    END { print "stable-mtimes.sh: dated $count files by their content\n" }'
