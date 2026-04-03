#!/bin/bash
# Mirador realistic simulation
# Simulates: info.json → thumbnail → initial viewport tiles → zoom-in tiles
# All with concurrent access like a real browser

IMAGE_ID="${1:?Usage: $0 <image_id> [label] [concurrent] -- e.g. $0 'folder%2Fimage.tif' cold 6}"
LABEL="${2:-test}"
CONCURRENT="${3:-6}"  # Chrome default: 6 connections per host
BASE="http://127.0.0.1:8182/iiif/2/${IMAGE_ID}"
# Get image dimensions from info.json
DIMS=$(curl -s "${BASE}/info.json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['width'], d['height'])" 2>/dev/null)
W=$(echo "$DIMS" | cut -d' ' -f1)
H=$(echo "$DIMS" | cut -d' ' -f2)
if [ -z "$W" ] || [ -z "$H" ]; then echo "Error: cannot get image dimensions"; exit 1; fi

echo "=== $LABEL (concurrent=$CONCURRENT) ==="

# Phase 1: info.json + thumbnail (Mirador first requests)
echo "--- Phase 1: info.json + thumbnail ---"
START1=$(date +%s%N)
curl -s -o /dev/null -w "info.json: %{time_total}s\n" "${BASE}/info.json" &
curl -s -o /dev/null -w "thumbnail: %{time_total}s\n" "${BASE}/full/200,/0/default.jpg" &
wait
END1=$(date +%s%N)
echo "  Phase 1 wall time: $(( (END1 - START1) / 1000000 ))ms"

# Phase 2: Initial viewport at zoom level (scaleFactor=8, tile=4096px)
# Typical initial view: ~4x2 = 8 tiles
echo ""
echo "--- Phase 2: Initial viewport (zoom level, scaleFactor=8) ---"
URLS2="/tmp/mirador_phase2.txt"
> "$URLS2"
TILE=4096
for ((y=0; y<H; y+=TILE)); do
  for ((x=0; x<W; x+=TILE)); do
    rw=$TILE; rh=$TILE
    if ((x + rw > W)); then rw=$((W - x)); fi
    if ((y + rh > H)); then rh=$((H - y)); fi
    echo "${BASE}/${x},${y},${rw},${rh}/512,/0/default.jpg" >> "$URLS2"
  done
done
TOTAL2=$(wc -l < "$URLS2")
START2=$(date +%s%N)
xargs -a "$URLS2" -P "$CONCURRENT" -I {} \
  curl -s -o /dev/null -w "%{time_total}\n" "{}" > "/tmp/mirador_p2_${LABEL}.txt" 2>&1
END2=$(date +%s%N)
AVG2=$(awk '{s+=$1;n++} END{printf "%.3f",s/n}' "/tmp/mirador_p2_${LABEL}.txt")
MAX2=$(sort -n "/tmp/mirador_p2_${LABEL}.txt" | tail -1)
echo "  Tiles: $TOTAL2, Wall: $(( (END2 - START2) / 1000000 ))ms, Avg: ${AVG2}s, Max: ${MAX2}s"

# Phase 3: User zooms in (scaleFactor=2, tile=1024px, viewport ~10x5 = 50 tiles)
echo ""
echo "--- Phase 3: Zoom-in (scaleFactor=2, ~50 tiles) ---"
URLS3="/tmp/mirador_phase3.txt"
> "$URLS3"
TILE=1024
# Simulate zooming into center area
CX=$((W/4)); CY=$((H/4))
VW=$((1024*10)); VH=$((1024*5))
for ((y=CY; y<CY+VH && y<H; y+=TILE)); do
  for ((x=CX; x<CX+VW && x<W; x+=TILE)); do
    rw=$TILE; rh=$TILE
    if ((x + rw > W)); then rw=$((W - x)); fi
    if ((y + rh > H)); then rh=$((H - y)); fi
    echo "${BASE}/${x},${y},${rw},${rh}/512,/0/default.jpg" >> "$URLS3"
  done
done
TOTAL3=$(wc -l < "$URLS3")
START3=$(date +%s%N)
xargs -a "$URLS3" -P "$CONCURRENT" -I {} \
  curl -s -o /dev/null -w "%{time_total}\n" "{}" > "/tmp/mirador_p3_${LABEL}.txt" 2>&1
END3=$(date +%s%N)
AVG3=$(awk '{s+=$1;n++} END{printf "%.3f",s/n}' "/tmp/mirador_p3_${LABEL}.txt")
MAX3=$(sort -n "/tmp/mirador_p3_${LABEL}.txt" | tail -1)
P953=$(sort -n "/tmp/mirador_p3_${LABEL}.txt" | awk -v p=0.95 'NR==1{n=0}{a[n++]=$1}END{printf "%.3f",a[int(n*p)]}')
echo "  Tiles: $TOTAL3, Wall: $(( (END3 - START3) / 1000000 ))ms, Avg: ${AVG3}s, Max: ${MAX3}s, P95: ${P953}s"

# Phase 4: Simulate 3 concurrent users accessing different images/regions
echo ""
echo "--- Phase 4: 3 concurrent users (different regions) ---"
URLS4="/tmp/mirador_phase4.txt"
> "$URLS4"
TILE=2048
# User 1: top-left
for ((y=0; y<4096; y+=TILE)); do
  for ((x=0; x<6144; x+=TILE)); do
    rw=$TILE; rh=$TILE
    echo "${BASE}/${x},${y},${rw},${rh}/512,/0/default.jpg" >> "$URLS4"
  done
done
# User 2: center
for ((y=4096; y<8192; y+=TILE)); do
  for ((x=8192; x<14336; x+=TILE)); do
    rw=$TILE; rh=$TILE
    echo "${BASE}/${x},${y},${rw},${rh}/512,/0/default.jpg" >> "$URLS4"
  done
done
# User 3: bottom-right
for ((y=8192; y<H; y+=TILE)); do
  for ((x=18432; x<W; x+=TILE)); do
    rw=$TILE; rh=$TILE
    if ((x + rw > W)); then rw=$((W - x)); fi
    if ((y + rh > H)); then rh=$((H - y)); fi
    echo "${BASE}/${x},${y},${rw},${rh}/512,/0/default.jpg" >> "$URLS4"
  done
done
TOTAL4=$(wc -l < "$URLS4")
START4=$(date +%s%N)
xargs -a "$URLS4" -P $((CONCURRENT * 3)) -I {} \
  curl -s -o /dev/null -w "%{time_total}\n" "{}" > "/tmp/mirador_p4_${LABEL}.txt" 2>&1
END4=$(date +%s%N)
AVG4=$(awk '{s+=$1;n++} END{printf "%.3f",s/n}' "/tmp/mirador_p4_${LABEL}.txt")
MAX4=$(sort -n "/tmp/mirador_p4_${LABEL}.txt" | tail -1)
ERRORS=$(grep -v "^[0-9]" "/tmp/mirador_p4_${LABEL}.txt" | wc -l)
echo "  Tiles: $TOTAL4, Wall: $(( (END4 - START4) / 1000000 ))ms, Avg: ${AVG4}s, Max: ${MAX4}s, Errors: $ERRORS"

# Total
TOTAL_WALL=$(( (END4 - START1) / 1000000 ))
echo ""
echo "=== Total wall time: ${TOTAL_WALL}ms ==="
