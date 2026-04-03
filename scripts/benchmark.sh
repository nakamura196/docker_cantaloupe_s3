#!/bin/bash
# IIIF Viewer-like benchmark: simulates OpenSeadragon loading multiple tiles concurrently
# Usage: ./benchmark.sh 'folder%2Fimage.tif' [label]

IMAGE_ID="${1:?Usage: $0 <image_id> [label] -- e.g. $0 'folder%2Fimage.tif' cold}"
LABEL="${2:-test}"
BASE="http://127.0.0.1:8182/iiif/2/${IMAGE_ID}"
CONCURRENT=10  # typical browser concurrent connections
RESULTS_FILE="/tmp/bench_${LABEL}.txt"

# Generate tile URLs simulating a zoom level 4 view (scaleFactor=4, effective tile=2048px)
# This gives roughly a 13x7 grid = ~91 tiles, similar to a full viewport load
URLS_FILE="/tmp/tile_urls.txt"
> "$URLS_FILE"

TILE=2048  # 512 * scaleFactor 4
# Get image dimensions from info.json
DIMS=$(curl -s "${BASE}/info.json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['width'], d['height'])" 2>/dev/null)
W=$(echo "$DIMS" | cut -d' ' -f1)
H=$(echo "$DIMS" | cut -d' ' -f2)
if [ -z "$W" ] || [ -z "$H" ]; then echo "Error: cannot get image dimensions"; exit 1; fi

for ((y=0; y<H; y+=TILE)); do
  for ((x=0; x<W; x+=TILE)); do
    rw=$((TILE))
    rh=$((TILE))
    if ((x + rw > W)); then rw=$((W - x)); fi
    if ((y + rh > H)); then rh=$((H - y)); fi
    echo "${BASE}/${x},${y},${rw},${rh}/512,/0/default.jpg" >> "$URLS_FILE"
  done
done

TOTAL=$(wc -l < "$URLS_FILE")
echo "=== $LABEL: $TOTAL tiles, $CONCURRENT concurrent ==="

# Run with curl parallel (xargs)
START=$(date +%s%N)
xargs -a "$URLS_FILE" -P "$CONCURRENT" -I {} \
  curl -s -o /dev/null -w "%{time_total}\n" "{}" > "$RESULTS_FILE" 2>&1
END=$(date +%s%N)

WALL_MS=$(( (END - START) / 1000000 ))

# Stats
AVG=$(awk '{s+=$1; n++} END {printf "%.3f", s/n}' "$RESULTS_FILE")
MAX=$(sort -n "$RESULTS_FILE" | tail -1)
MIN=$(sort -n "$RESULTS_FILE" | head -1)
P95=$(sort -n "$RESULTS_FILE" | awk -v p=0.95 'NR==1{n=0} {a[n++]=$1} END {printf "%.3f", a[int(n*p)]}')

echo "  Total wall time : ${WALL_MS}ms"
echo "  Tiles           : $TOTAL"
echo "  Avg per tile    : ${AVG}s"
echo "  Min             : ${MIN}s"
echo "  Max             : ${MAX}s"
echo "  P95             : ${P95}s"
echo ""
