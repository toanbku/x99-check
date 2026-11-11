#!/usr/bin/env bash
# X99 DUAL CHECK cho Linux (dung khi boot Ubuntu Live USB: may khong co Windows, hoac Windows Home chi thay 1 CPU)
#
# Chay:   sudo bash check.sh            (day du: test RAM ~5 phut + chay nang CPU 10 phut)
#         sudo bash check.sh --quick    (thu nhanh: 1 phut moi phan)
# Doi cau hinh mong doi bang bien moi truong, vd:  sudo EXPECT_CPU=2680 bash check.sh
#
# Ma thoat: 0 = khong thay loi, 1 = co LOI hoac CHU Y, 2 = ban than script bi loi.

set -u
export LC_ALL=C

if [ "$(id -u)" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi

STRESS_MIN=${STRESS_MIN:-10}
MEM_MIN=${MEM_MIN:-5}
MEM_PASSES=${MEM_PASSES:-2}
MEM_PCT=${MEM_PCT:-80}
EXPECT_SOCKETS=${EXPECT_SOCKETS:-2}
EXPECT_THREADS=${EXPECT_THREADS:-72}
EXPECT_RAM_GB=${EXPECT_RAM_GB:-128}
EXPECT_DIMMS=${EXPECT_DIMMS:-4}
EXPECT_DIMM_GB=${EXPECT_DIMM_GB:-32}
EXPECT_CPU=${EXPECT_CPU:-2686}
EXPECT_BRAND=${EXPECT_BRAND:-Samsung}
NO_STRESSNG=${NO_STRESSNG:-0}
INJECT=${INJECT:-0}
SKIP_TESTS=0
for a in "$@"; do
  case "$a" in
    --quick) STRESS_MIN=1; MEM_MIN=1; MEM_PASSES=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
  esac
done

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
ISSUES=(); WARNS=()
section() { printf '\n%s== %s ==%s\n' "$C" "$1" "$N"; }
ok()      { printf '  %s[OK]%s    %s\n' "$G" "$N" "$1"; }
bad()     { printf '  %s[LOI]%s   %s\n' "$R" "$N" "$1"; ISSUES+=("$1"); }
warn()    { printf '  %s[CHU Y]%s %s\n' "$Y" "$N" "$1"; WARNS+=("$1"); }
info()    { printf '          %s\n' "$1"; }

TMPD=$(mktemp -d)
MON=""
cleanup() { [ -n "$MON" ] && kill "$MON" 2>/dev/null; rm -rf "$TMPD"; }
trap cleanup EXIT

REPORT_DIR=${REPORT_DIR:-$PWD}
[ -w "$REPORT_DIR" ] || REPORT_DIR=/tmp
REPORT="$REPORT_DIR/x99-report-$(date +%Y%m%d-%H%M).txt"
exec > >(tee -a "$REPORT") 2>&1

num() { local v="${1//[!0-9]/}"; echo "${v:-0}"; }

dimm_brand() {
  local pn="$1" mf="$2"
  case "$pn" in M3*) echo Samsung; return ;; HMA*) echo "SK Hynix"; return ;; esac
  if [[ "$pn" =~ ^[0-9]{1,2}AS[FS] ]]; then echo Micron; return; fi
  if [[ "$pn" =~ ^(KVR|KSM|KTD|KTH|KTL|KCP) ]]; then echo Kingston; return; fi
  case "$mf" in
    *Samsung*|00CE*|80CE*|CE00*) echo Samsung ;;
    *Hynix*|00AD*|80AD*|AD00*) echo "SK Hynix" ;;
    *Micron*|002C*|802C*|2C00*) echo Micron ;;
    *Kingston*|0198*|8098*) echo Kingston ;;
    *) echo "${mf:-?}" ;;
  esac
}

dimm_kind() {
  local pn="$1" td="$2"
  if [[ "$pn" =~ ^M3(93|86|78|91) ]]; then
    case "${BASH_REMATCH[1]}" in 93) echo RDIMM ;; 86) echo LRDIMM ;; 78) echo UDIMM ;; 91) echo UDIMM-ECC ;; esac; return
  fi
  if [[ "$pn" =~ ^HMA...([RLU]) ]]; then
    case "${BASH_REMATCH[1]}" in R) echo RDIMM ;; L) echo LRDIMM ;; U) echo UDIMM ;; esac; return
  fi
  if [[ "$pn" =~ 72([PLA])Z ]]; then
    case "${BASH_REMATCH[1]}" in P) echo RDIMM ;; L) echo LRDIMM ;; A) echo UDIMM ;; esac; return
  fi
  case "$td" in *LRDIMM*) echo LRDIMM ;; *Registered*) echo RDIMM ;; *Unbuffered*) echo UDIMM ;; *) echo '?' ;; esac
}

cpu_temps() {
  local out="" h f lbl v
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = coretemp ] || continue
    for f in "$h"/temp*_label; do
      [ -f "$f" ] || continue
      lbl=$(cat "$f")
      case "$lbl" in
        Package*) v=$(cat "${f%_label}_input" 2>/dev/null || echo 0); out+="CPU${lbl#Package id } $((v / 1000))C " ;;
      esac
    done
  done
  echo "${out:-n/a }"
}

edac_counts() {
  local ce=0 ue=0 f
  for f in /sys/devices/system/edac/mc/mc*/ce_count; do [ -f "$f" ] && ce=$((ce + $(cat "$f"))); done
  for f in /sys/devices/system/edac/mc/mc*/ue_count; do [ -f "$f" ] && ue=$((ue + $(cat "$f"))); done
  echo "$ce $ue"
}

mce_count() { dmesg 2>/dev/null | grep -ciE 'mce:|machine check|hardware error' || true; }

monitor() {
  local every="$1" start=$SECONDS t mhz
  while :; do
    sleep "$every"
    t=$(cpu_temps)
    mhz=$(awk -F: '/^cpu MHz/ { s += $2; n++ } END { if (n) printf "%d", s / n }' /proc/cpuinfo)
    printf '          %4ds | nhiet: %s| xung TB: %sMHz | ECC da sua: %s\n' $((SECONDS - start)) "$t" "${mhz:-?}" "$(edac_counts | cut -d' ' -f1)"
    echo "$t" >> "$TMPD/temps"
  done
}

ensure_stressng() {
  [ "$NO_STRESSNG" = 1 ] && return 1
  command -v stress-ng >/dev/null && return 0
  info "Chua co stress-ng, thu cai (can co mang)..."
  if ! (timeout 300 apt-get install -y -qq stress-ng) >/dev/null 2>&1; then
    (timeout 60 add-apt-repository -y universe && timeout 180 apt-get update -qq &&
      timeout 300 apt-get install -y -qq stress-ng) >/dev/null 2>&1
  fi
  command -v stress-ng >/dev/null
}

write_py() {
  cat > "$TMPD/x99test.py" <<'PY'
import math, os, sys, time
import multiprocessing as mp

GB = 1 << 30
BLK = 1 << 20

def mem_worker(wid, nchunks, passes, inject, q):
    bufs = []
    for _ in range(nchunks):
        try:
            bufs.append(bytearray(GB))
        except MemoryError:
            break
    rnd = os.urandom(BLK)
    pats = [b'\x00' * BLK, b'\xff' * BLK, b'\x55' * BLK, b'\xaa' * BLK, rnd, bytes(255 - x for x in rnd)]
    errs, first = 0, []
    for p in range(passes):
        for pi, pat in enumerate(pats):
            refs = []
            for ci, b in enumerate(bufs):
                k = (ci * 4099 + wid * 131 + pi * 17) % BLK
                ref = pat[k:] + pat[:k]
                refs.append(ref)
                mv = memoryview(b)
                mv[0:BLK] = ref
                n = BLK
                while n < GB:
                    m = min(n, GB - n)
                    mv[n:n + m] = mv[0:m]
                    n += m
                mv.release()
            if inject and p == 0 and pi == 0 and bufs:
                bufs[0][12345] ^= 0x10
            for ci, b in enumerate(bufs):
                ref = refs[ci]
                for off in range(0, GB, BLK):
                    if b[off:off + BLK] != ref:
                        errs += 1
                        if len(first) < 5:
                            first.append('tien trinh %d, GB thu %d, offset 0x%x' % (wid, ci, off))
    q.put((wid, len(bufs), errs, first))

def work():
    x, acc = 1.0, 0
    for i in range(1, 200001):
        x = math.sqrt(x * 1.000001 + i) + math.sin(i * 0.001)
        acc = (((acc << 7) | (acc >> 57)) & 0xFFFFFFFFFFFFFFFF) ^ (int(x * 1000) + i)
    return repr(x) + ':' + str(acc)

def cpu_worker(deadline, ref, q):
    loops = errs = 0
    while time.time() < deadline:
        if work() != ref:
            errs += 1
        loops += 1
    q.put((loops, errs))

def collect(ps, q):
    res = []
    while len(res) < len(ps):
        try:
            res.append(q.get(timeout=5))
        except Exception:
            if not any(p.is_alive() for p in ps) and q.empty():
                break
    for p in ps:
        p.join(timeout=5)
    return res

if __name__ == '__main__':
    mode = sys.argv[1]
    nproc = os.cpu_count() or 1
    q = mp.Queue()
    if mode == 'mem':
        total, passes, inject = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == '1'
        w = max(1, min(nproc, total))
        per = [total // w + (1 if i < total % w else 0) for i in range(w)]
        ps = [mp.Process(target=mem_worker, args=(i, per[i], passes, inject and i == 0, q)) for i in range(w)]
        for p in ps:
            p.start()
        res = collect(ps, q)
        for r in res:
            for line in r[3]:
                print('MEMERR ' + line)
        print('RESULT alloc=%d errors=%d died=%d' % (sum(r[1] for r in res), sum(r[2] for r in res), len(ps) - len(res)))
    else:
        secs, inject = int(sys.argv[2]), sys.argv[3] == '1'
        ref = work() + ('x' if inject else '')
        deadline = time.time() + secs
        ps = [mp.Process(target=cpu_worker, args=(deadline, ref, q)) for _ in range(nproc)]
        for p in ps:
            p.start()
        res = collect(ps, q)
        print('RESULT loops=%d errors=%d died=%d' % (sum(r[0] for r in res), sum(r[1] for r in res), len(ps) - len(res)))
PY
}

# ---------------------------------------------------------------------------
printf '\n%s=============== X99 DUAL CHECK (Linux) ===============%s\n' "$C" "$N"
echo "Mong doi: $EXPECT_SOCKETS CPU E5-$EXPECT_CPU, $EXPECT_THREADS luong, $EXPECT_DIMMS thanh RAM ${EXPECT_DIMM_GB}GB = ${EXPECT_RAM_GB}GB, hang $EXPECT_BRAND"
modprobe sb_edac >/dev/null 2>&1 || true
modprobe coretemp >/dev/null 2>&1 || true
HAVE_DMI=1; command -v dmidecode >/dev/null || HAVE_DMI=0

# --- 1. Main + BIOS -----------------------------------------------------------
section '1. Main + BIOS'
if [ "$HAVE_DMI" = 1 ]; then
  board="$(dmidecode -s baseboard-manufacturer 2>/dev/null) $(dmidecode -s baseboard-product-name 2>/dev/null)"
  info "Main: $board"
  info "BIOS: $(dmidecode -s bios-version 2>/dev/null) ($(dmidecode -s bios-release-date 2>/dev/null))"
  case "$board" in *"Default string"*|*"To be filled"*) info "-> Main OEM khong ten tuoi (thuong re hon Huananzhi khoang 1 trieu)." ;; esac
else
  warn "Khong co lenh dmidecode, khong doc duoc main/RAM (sudo apt install dmidecode)"
fi

# --- 2. CPU -----------------------------------------------------------------
section '2. CPU'
model=$(lscpu | sed -n 's/^Model name: *//p' | head -1)
sockets=$(grep '^physical id' /proc/cpuinfo | sort -u | wc -l)
[ "$sockets" -gt 0 ] || sockets=$(num "$(lscpu | sed -n 's/^Socket(s): *//p' | head -1)")
threads=$(nproc --all)
info "$model | $sockets CPU | $threads luong"
if [ "$sockets" -ge "$EXPECT_SOCKETS" ]; then ok "Nhan $sockets CPU"; else bad "Chi nhan $sockets/$EXPECT_SOCKETS CPU -> CPU, chan socket hoac main co van de"; fi
if grep -q -- "$EXPECT_CPU" <<<"$model"; then ok "Dung CPU E5-$EXPECT_CPU"; else bad "CPU khong phai E5-$EXPECT_CPU: $model"; fi
if [ "$threads" -ge "$EXPECT_THREADS" ]; then ok "Du $threads luong"; else bad "Chi co $threads/$EXPECT_THREADS luong (thieu CPU, hoac Hyper-Threading bi tat trong BIOS)"; fi

# --- 3. RAM -----------------------------------------------------------------
section '3. RAM'
count=0; total=0; parts=""; kinds=""; brands=""; ddrs=""; minspd=99999
if [ "$HAVE_DMI" = 1 ]; then
  dmidecode -t 17 2>/dev/null | awk -F': ' '
    function out() { if (sz != "" && sz !~ /No Module|Not Installed|^0/) print sz "\t" loc " " bank "\t" mf "\t" pn "\t" spd "\t" cspd "\t" td "\t" typ }
    /^Memory Device/ { out(); sz = loc = bank = mf = pn = spd = cspd = td = typ = "" }
    /^\tSize:/ { sz = $2 }
    /^\tLocator:/ { loc = $2 }
    /^\tBank Locator:/ { bank = $2 }
    /^\tManufacturer:/ { mf = $2 }
    /^\tPart Number:/ { pn = $2; sub(/ +$/, "", pn) }
    /^\tSpeed:/ { spd = $2 }
    /^\tConfigured (Memory|Clock) Speed:/ { cspd = $2 }
    /^\tType Detail:/ { td = $2 }
    /^\tType:/ { typ = $2 }
    END { out() }' > "$TMPD/dimms"
  printf '          %-28s %5s  %-10s %-22s %-9s %-6s %s\n' KHE GB HANG MA LOAI DDR BUS
  while IFS=$'\t' read -r sz slot mf pn spd cspd td typ; do
    gb=$(num "$sz")
    case "$sz" in *MB*) gb=$((gb / 1024)) ;; *TB*) gb=$((gb * 1024)) ;; esac
    br=$(dimm_brand "$pn" "$mf"); kd=$(dimm_kind "$pn" "$td"); s=$(num "$spd")
    printf '          %-28s %5s  %-10s %-22s %-9s %-6s %s\n' "$slot" "$gb" "$br" "${pn:-?}" "$kd" "$typ" "$spd / $cspd"
    count=$((count + 1)); total=$((total + gb))
    parts+="$pn"$'\n'; kinds+="$kd"$'\n'; brands+="$br"$'\n'; ddrs+="$typ"$'\n'
    [ "$s" -gt 0 ] && [ "$s" -lt "$minspd" ] && minspd=$s
    [ "$gb" -ne "$EXPECT_DIMM_GB" ] && bad "Thanh o khe $slot la ${gb}GB, khong phai ${EXPECT_DIMM_GB}GB"
  done < "$TMPD/dimms"

  if [ "$count" -eq "$EXPECT_DIMMS" ]; then ok "Du $count thanh RAM"; else bad "Thay $count thanh RAM, mong doi $EXPECT_DIMMS"; fi
  if [ "$total" -ge "$EXPECT_RAM_GB" ]; then ok "Tong ${total}GB"; else bad "Tong RAM chi ${total}GB (mong doi ${EXPECT_RAM_GB}GB)"; fi
  np=$(printf '%s' "$parts" | sort -u | grep -c .)
  if [ "$np" -le 1 ]; then ok "Cac thanh cung ma: $(printf '%s' "$parts" | sort -u | tr -d '\n')"; else warn "RAM khong dong bo, $np ma khac nhau: $(printf '%s' "$parts" | sort -u | tr '\n' ' ')"; fi
  uk=$(printf '%s' "$kinds" | sort -u | tr '\n' ' ')
  if grep -qx RDIMM <<<"$kinds" && grep -qx LRDIMM <<<"$kinds"; then bad "Tron RDIMM voi LRDIMM -> khong chay chung duoc"
  elif grep -q UDIMM <<<"$kinds"; then warn "Co thanh UDIMM (khong phai ECC REG nhu nguoi ban noi)"
  else ok "Loai: $uk"; fi
  nb=$(printf '%s' "$brands" | grep -vc "$EXPECT_BRAND" || true)
  if [ "$nb" -eq 0 ]; then ok "Hang: $EXPECT_BRAND"; else warn "Co $nb thanh khong phai $EXPECT_BRAND: $(printf '%s' "$brands" | grep -v "$EXPECT_BRAND" | sort -u | tr '\n' ' ')"; fi
  grep -q DDR3 <<<"$ddrs" && warn "RAM la DDR3, khong phai DDR4"
  [ "$minspd" -lt 2133 ] && warn "Co thanh bus $minspd (thap hon 2133)"
fi
memtotal_gb=$(awk '/MemTotal/ { printf "%d", $2 / 1048576 + 0.5 }' /proc/meminfo)
info "Linux thay ${memtotal_gb}GB RAM"
nodes=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
if [ "$nodes" -gt 0 ]; then
  line=""; empty=0
  for nd in /sys/devices/system/node/node[0-9]*; do
    t=$(awk '/MemTotal/ { printf "%d", $4 / 1048576 + 0.5 }' "$nd/meminfo")
    line+="CPU${nd##*node} ${t}GB | "
    [ "$t" -lt 2 ] && empty=1
  done
  info "RAM theo tung CPU: ${line% | }"
  if [ "$nodes" -ge 2 ]; then
    if [ "$empty" = 1 ]; then warn "Co CPU khong co RAM rieng -> nen cam moi CPU 2 thanh"; else ok "RAM chia cho ca 2 CPU"; fi
  elif [ "$sockets" -ge 2 ]; then info "NUMA dang tat trong BIOS (khong sao)."; fi
fi

# --- 4 + 5. Test --------------------------------------------------------------
if [ "$SKIP_TESTS" = 1 ]; then
  section '4. Test RAM + CPU: BO QUA (--skip-tests)'
else
  read -r ce0 ue0 <<<"$(edac_counts)"
  mce0=$(mce_count)
  if ls -d /sys/devices/system/edac/mc/mc* >/dev/null 2>&1; then info "Dang theo doi loi ECC qua EDAC."; else info "(Khong doc duoc bo dem ECC/EDAC tren may nay)"; fi
  info "Nhiet do luc nghi: $(cpu_temps)"
  USE_SNG=0; ensure_stressng && USE_SNG=1
  [ "$USE_SNG" = 1 ] && info "Dung stress-ng." || { info "Khong co stress-ng, dung bo test Python du phong."; write_py; }

  section '4. Test RAM (ghi roi doc lai)'
  avail_kb=$(awk '/MemAvailable/ { print $2 }' /proc/meminfo)
  monitor 15 & MON=$!
  if [ "$USE_SNG" = 1 ]; then
    w=$(( threads < 32 ? threads : 32 ))
    per_kb=$(( avail_kb * MEM_PCT / 100 / w ))
    info "Test $(( per_kb * w / 1048576 ))GB voi $w tien trinh trong $MEM_MIN phut..."
    stress-ng --vm "$w" --vm-bytes "${per_kb}k" --vm-method all --verify --vm-keep -t "${MEM_MIN}m" --metrics-brief > "$TMPD/mem.out" 2>&1
    rc=$?
    grep -iE 'fail|error|corrupt' "$TMPD/mem.out" | grep -v 'failed: 0' | head -10 | while read -r l; do info "$l"; done
    if [ "$rc" -eq 0 ]; then ok "RAM test $MEM_MIN phut: khong sai"
    elif [ "$rc" -eq 2 ]; then bad "RAM SAI DU LIEU (stress-ng verify bao loi) -> co thanh RAM loi"
    else warn "stress-ng thoat ma $rc (co the thieu RAM / bi kill), xem $REPORT"; fi
  else
    gb=$(( avail_kb * MEM_PCT / 100 / 1048576 - 1 ))
    [ "$gb" -lt 1 ] && gb=1
    info "Test ${gb}GB x $MEM_PASSES pass x 6 mau..."
    python3 -u "$TMPD/x99test.py" mem "$gb" "$MEM_PASSES" "$INJECT" > "$TMPD/mem.out" 2>&1
    grep '^MEMERR' "$TMPD/mem.out" | head -10 | while read -r l; do info "${l#MEMERR }"; done
    res=$(grep '^RESULT' "$TMPD/mem.out" | tail -1)
    alloc=$(sed -n 's/.*alloc=\([0-9]*\).*/\1/p' <<<"$res"); errs=$(sed -n 's/.*errors=\([0-9]*\).*/\1/p' <<<"$res"); died=$(sed -n 's/.*died=\([0-9]*\).*/\1/p' <<<"$res")
    if [ -z "$res" ]; then warn "Test RAM khong chay xong: $(tail -3 "$TMPD/mem.out" | tr '\n' ' ')"
    elif [ "${errs:-0}" -gt 0 ]; then bad "RAM SAI DU LIEU: $errs khoi 1MB doc ra khac luc ghi -> co thanh RAM loi"
    else ok "Da test ${alloc}GB x $MEM_PASSES pass x 6 mau: khong sai"; fi
    [ "${died:-0}" -gt 0 ] && warn "$died tien trinh test RAM bi kill (thieu RAM?)"
  fi

  section "5. Chay nang CPU $STRESS_MIN phut"
  info "Trong luc nay may KHONG duoc tat, treo hay dung hinh."
  if [ "$USE_SNG" = 1 ]; then
    stress-ng --cpu 0 --cpu-method all --verify -t "${STRESS_MIN}m" --metrics-brief > "$TMPD/cpu.out" 2>&1
    rc=$?
    grep -iE 'fail|error' "$TMPD/cpu.out" | grep -v 'failed: 0' | head -10 | while read -r l; do info "$l"; done
    if [ "$rc" -eq 0 ]; then ok "Chay nang $STRESS_MIN phut, stress-ng verify khong sai"
    elif [ "$rc" -eq 2 ]; then bad "CPU TINH SAI khi chay nang (stress-ng verify) -> CPU/main/nguon khong on dinh"
    else warn "stress-ng CPU thoat ma $rc"; fi
  else
    python3 -u "$TMPD/x99test.py" cpu "$((STRESS_MIN * 60))" "$INJECT" > "$TMPD/cpu.out" 2>&1
    res=$(grep '^RESULT' "$TMPD/cpu.out" | tail -1)
    loops=$(sed -n 's/.*loops=\([0-9]*\).*/\1/p' <<<"$res"); errs=$(sed -n 's/.*errors=\([0-9]*\).*/\1/p' <<<"$res")
    if [ -z "$res" ]; then warn "Test CPU khong chay xong: $(tail -3 "$TMPD/cpu.out" | tr '\n' ' ')"
    elif [ "${errs:-0}" -gt 0 ]; then bad "CPU TINH SAI $errs lan khi chay nang -> CPU/main/nguon khong on dinh"
    else ok "Chay nang $STRESS_MIN phut, $loops lan tinh, khong sai lan nao"; fi
  fi
  kill "$MON" 2>/dev/null; wait "$MON" 2>/dev/null; MON=""

  section '6. Nhiet do + loi phan cung trong luc test'
  maxt=$(grep -o '[0-9]*C' "$TMPD/temps" 2>/dev/null | tr -d C | sort -n | tail -1)
  if [ -n "$maxt" ]; then
    if [ "$maxt" -ge 90 ]; then bad "Nhiet CPU len toi ${maxt}C -> qua nong (tan kem / keo kho / lap sai)"
    elif [ "$maxt" -ge 80 ]; then warn "Nhiet CPU cao nhat ${maxt}C (hoi nong, nen thay keo tan nhiet)"
    else ok "Nhiet CPU cao nhat ${maxt}C"; fi
  else info "Khong doc duoc nhiet do CPU."; fi
  read -r ce1 ue1 <<<"$(edac_counts)"
  mce1=$(mce_count)
  if [ "$ue1" -gt "$ue0" ]; then bad "ECC bao $((ue1 - ue0)) loi KHONG sua duoc -> RAM loi"; fi
  if [ "$ce1" -gt "$ce0" ]; then bad "ECC phai sua $((ce1 - ce0)) loi trong luc test -> co thanh RAM yeu"; fi
  if [ "$mce1" -gt "$mce0" ]; then bad "Kernel ghi $((mce1 - mce0)) loi phan cung (MCE) trong luc test"; fi
  if [ "$ce1" -eq "$ce0" ] && [ "$ue1" -eq "$ue0" ] && [ "$mce1" -eq "$mce0" ]; then ok "Khong co loi phan cung (ECC/MCE) trong luc test"; fi
fi

# --- Tong ket -----------------------------------------------------------------
section 'TONG KET'
[ ${#ISSUES[@]} -eq 0 ] && [ ${#WARNS[@]} -eq 0 ] && printf '  %sKHONG THAY LOI.%s\n' "$G" "$N"
for m in "${ISSUES[@]+"${ISSUES[@]}"}"; do printf '  %s[LOI]%s   %s\n' "$R" "$N" "$m"; done
for m in "${WARNS[@]+"${WARNS[@]}"}"; do printf '  %s[CHU Y]%s %s\n' "$Y" "$N" "$m"; done
echo
echo "  Nho: trong luc test ma may TAT NGANG / TREO / DUNG HINH thi do la loi nang nhat."
echo "  Bao cao da luu: $REPORT"
if [ ${#ISSUES[@]} -gt 0 ] || [ ${#WARNS[@]} -gt 0 ]; then exit 1; fi
exit 0
