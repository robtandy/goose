#!/bin/sh
# Builds the measurement programs of docs/design/shared_memory.md, and runs
# each of them three times; README.md has the results.
#
#     bench/shared_memory/run.sh DIR [CC]
#
# DIR is a scratch directory on the file system whose files are to be mapped
# (it needs 2 GB free); CC is the C compiler, clang by default, and GOOSE the
# compiler that builds colsum.goose, goose on the PATH by default. The cold-cache
# rows drop the file's pages first and take about 15 s each on a slow volume;
# set COLD=0 to skip them. Linux.
set -e
dir=${1:?usage: run.sh DIR [CC]}
cc=${2:-clang}
here=$(cd "$(dirname "$0")" && pwd)
bin="$dir/bin"
mkdir -p "$bin"
for p in mapbench release mprot attach sigbus colfile; do
    "$cc" -O2 -Wall -Wextra -pthread -o "$bin/$p" "$here/$p.c"
done
goose="${GOOSE:-goose}"
"$goose" build -O2 --cc "$cc" -o "$bin/colsum" "$here/colsum.goose"
col="$dir/col.i64"
[ -f "$col" ] || "$bin/colfile" write "$col" 268435456   # 2^28 i64s, 2 GB

echo "== scanning a cached file"
cat "$col" > /dev/null
for rep in 1 2 3; do
    for t in 1 16; do
        "$bin/mapbench" "$col" pread $t
        "$bin/mapbench" "$col" readall $t
        "$bin/mapbench" "$col" mmap $t 2
        "$bin/mapbench" "$col" mmap_populate $t
        "$bin/mapbench" "$col" mmap_popread $t
        "$bin/mapbench" "$col" mmap_willneed $t
    done
done
echo "== the same sum in Goose"
for rep in 1 2 3; do
    for t in 1 16; do
        "$bin/colsum" "$col" pread $t
        "$bin/colsum" "$col" read_file $t
        "$bin/colsum" "$col" view $t 2
    done
done
if [ "${COLD:-1}" != 0 ]; then
    echo "== the same file, not cached"
    for m in pread mmap mmap_willneed mmap_popread; do
        for t in 1 16; do
            "$bin/colfile" drop "$col"
            "$bin/mapbench" "$col" $m $t | head -n 1
        done
    done
    cat "$col" > /dev/null
fi

echo "== releasing memory when threads end together"
for rep in 1 2 3; do
    for how in munmap dontneed keep; do
        "$bin/release" 16 1 64 $how
        "$bin/release" 16 4 16 $how
        "$bin/release" 1 1 64 $how
    done
done

echo "== making a region read-only"
for rep in 1 2 3; do
    for mb in 4 64; do
        "$bin/mprot" 0 $mb
        "$bin/mprot" 15 $mb
    done
done

echo "== the attachment count"
for rep in 1 2 3; do
    "$bin/attach" 1 10000000
    "$bin/attach" 4 2000000
    "$bin/attach" 16 1000000
done

echo "== truncation"
"$bin/sigbus" "$dir" || true
