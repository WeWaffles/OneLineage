#!/system/bin/sh
# Read back every file of the host's APEXes that live on /data (decompressed
# or updated APEXes). After some switch sessions these returned dm-verity I/O
# errors and every One UI process that mapped them died with SIGBUS.
#
# Prints a summary; exits 1 if any read failed. Usage: check_host_apex.sh [label]
LABEL="${1:-check}"
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
modules=$(grep -o '<apex-info [^>]*>' /apex/apex-info-list.xml |
    grep 'isActive="true"' | grep 'modulePath="/data/apex/' |
    sed 's/.*moduleName="\([^"]*\)".*/\1/' | sort -u)
files=0; bad=0; badlist=""
for m in $modules; do
    [ -d "/apex/$m" ] || continue
    for f in $(find "/apex/$m" -type f 2>/dev/null); do
        files=$((files + 1))
        if ! cat "$f" > /dev/null 2>&1; then
            bad=$((bad + 1))
            badlist="$badlist $f"
        fi
    done
done
echo "[$LABEL] host APEXes on /data: $(echo $modules | wc -w) modules, $files files, $bad unreadable${badlist:+:$badlist}"
[ "$bad" -eq 0 ]
