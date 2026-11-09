# OpenRide — Real-World Validation (Lagos, Nigeria)

Validation of the full offline stack (routing, geocoding, vector tiles)
against a bundle built from **real OpenStreetMap data** for Lagos.

## Data source

| | |
|---|---|
| Source | https://download.openstreetmap.fr/extracts/africa/nigeria.html |
| File | `nigeria.osm.pbf` |
| Size | 786,164,352 bytes |
| Downloaded | 2026-11-09 |
| Region bbox (bundle) | lat 6.40–6.70, lon 3.20–3.55 (greater Lagos) |

## Extraction stats (bbox pre-filter, `extractBbox`)

| Metric | Value |
|---|---|
| Nodes scanned (pass 1) | 135,657,335 |
| Nodes in bbox | ~5.95M |
| Nodes materialized (pass 3, ways kept whole) | 5,971,908 |
| Ways scanned (pass 2) | 21,837,498 |
| Ways kept | 1,288,237 |
| Named POI nodes | 2,744 |
| Turn restrictions kept | 14 |

## Bundle artifacts

| File | Size | sha256 | Content |
|---|---|---|---|
| `graph.bin` | 21 MB (21,141,275 B) | `70e9a1a87f7269e9aac45396484ad16aeb222eca3a866a9ef2f70cc31f74b0c2` | 365,223 routing nodes, 737,669 edges, 14 turn restrictions |
| `geocoder.bin` | 550 KB (550,450 B) | `e4c047b6d7773d760e337ecd097d47eba59835c899183768693ee7042519c627` | offline geocoder index (built in ~8 s from extracted data) |
| `tiles.mbf` | 127 MB (127,071,833 B) | `2a0f4c8477b8538785ca1a2689120ed5f80813f696a5925fa9575b461de5c1af` | 1,694 vector tiles, zooms 5–15 (split-and-merge build) |

These digests are the integrity pins served by the DeliveryPlatform
`openrideBundles.list` manifest (contract C3).

## Routing validation (real numbers, `bin/validate_routes.dart`)

Graph load: 844 ms. No coordinate nudges were needed — all four landmark
endpoints snapped to routable nodes on the first attempt.

| Route | Profile | Distance | Time | Wall clock | Maneuvers |
|---|---|---|---|---|---|
| Unilag (6.5176, 3.3787) → Victoria Island (6.4281, 3.4219) | fastbike | 20.21 km | 59.3 min | 479 ms | 124 |
| Ikeja (6.6018, 3.3515) → Lekki Phase 1 (6.4474, 3.4723) | fastbike | 33.27 km | 88.4 min | 1019 ms | 141 |
| Unilag → Victoria Island | fastbike | 20.21 km | 59.3 min | 529 ms | 124 |
| Unilag → Victoria Island | carFast | 15.49 km | 10.8 min | 151 ms | 26 |

All assertions passed (12/12): routes found, road distances inside the
plausible bands (8–25 km for Unilag→VI, 15–45 km for Ikeja→Lekki),
maneuver lists non-empty. `carFast` takes a shorter/faster path
(15.49 km via expressways vs 20.21 km bike route) — the profiles produce
meaningfully different routes on real data.

Top-5 maneuvers, Unilag → Victoria Island (fastbike):

```
[0.00 km] Depart
[0.03 km] Turn right
[0.04 km] Turn left
[0.06 km] Turn left
[0.08 km] Enter the roundabout
```

`NoRouteException` is caught and reported by the runner (retry with
±0.002° coordinate nudges, max 8); none occurred in this run.

## Geocoder validation

`geocoder.bin` built standalone (`bin/build_geocoder.dart`) against the
re-extracted Lagos data: 5,971,908 nodes / 1,288,237 ways / 14 turn
restrictions; build took 7.7 s, peak memory well under the 4 GB container
limit. Queries (near 6.45, 3.40):

| Query | Hits | Top hit |
|---|---|---|
| "University of Lagos" | 4 | University of Lagos [amenity:university] score=0.927 @ 6.5164,3.3943 |
| "Eko Hotel" | 2 | Eko Hotel [tourism:hotel] score=1.021 @ 6.4268,3.4304 |
| "Lekki" | 20 | Lekki Phase I [place:town] score=0.975 @ 6.4414,3.4705 |

Assertion (≥1 hit overall, and per-query non-empty) passed for all three
well-known Lagos names.

## Tile validation

Built with `--split 4` (4 vertical slices at lon 3.2000 / 3.2875 / 3.375 /
3.4625 / 3.5500), then merged with `bin/merge_mbf.dart`. Per-slice
extraction/build (each slice = 3 streaming passes over the 786 MB PBF,
then `OsmTileBuilder`):

| Slice | lon range | Nodes | Ways | Tiles written (owned/built) | Time |
|---|---|---|---|---|---|
| 1 | 3.2000–3.2875 | 2,281,252 | 496,568 | 543 / 592 | 149 s |
| 2 | 3.2875–3.3750 | 2,133,584 | 458,844 | 347 / 562 | 151 s |
| 3 | 3.3750–3.4625 | 679,627 | 140,106 | 385 / 695 | 131 s |
| 4 | 3.4625–3.5500 | 910,843 | 194,808 | 419 / 545 | 133 s |

Merged result (`tiles.mbf`):

- 1,694 tiles; zooms present: 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
- `MbfReader` opens and binary-searches the sorted index cleanly
- z14 tile over Victoria Island (`tileFor(6.4281, 3.4219, 14)` =
  `14/8347/7898`): present, 136,892 bytes
- `renderTile` → **3,971 non-empty DrawCommands**
- (tile bounds exceed the extraction bbox because `extractBbox` keeps
  clipped ways whole — e.g. through-running highways extending far north)

Zooms 0–4 are absent because no features in the extract emit below zoom 5
(no `place=city` node survived the bbox filter; motorways start at z5).

## OOM constraint and the split-and-merge solution

The container has 4 GB RAM. The vector tile builder holds the whole
region's parsed features in RAM; building tiles for the full Lagos bbox
(5.97M nodes) was OOM-killed, as was a 2-slice attempt for the dense
western half (4.40M nodes — Lagos data is heavily skewed west of
lon 3.375). The solution is split-and-merge:

1. `bin/build_bundle_bbox.dart in.pbf outdir/ minLat minLon maxLat maxLon --split N`
   cuts the bbox into N vertical (longitude) slices and builds a separate
   tile store `tiles.slice$i.mbf` per slice (peak memory ≈ 1/N of the
   full-region build). The final Lagos tiles were built with **N=4**.
2. `bin/merge_mbf.dart out.mbf in1.mbf in2.mbf ...` merges the slice
   stores into a single `tiles.mbf` with the standard sorted (z,x,y)
   index — byte-layout identical to a direct build.

Seam correctness: ways crossing a slice boundary are kept whole on both
sides (`extractBbox` keeps every way touching a slice with ALL its
nodes), and each tile is written by exactly one slice — the one owning
the tile's west edge. Owned tiles are therefore byte-identical to a
direct build, except tiles at/around a seam, which can miss a way that
crosses the seam without any node on the owning side (rare with real OSM
node density; unit-tested in `test/mbf_merge_test.dart`).

## Tooling added (branch `realworld2`)

| File | Purpose |
|---|---|
| `packages/osm_bundle_tool/bin/validate_routes.dart` | landmark routing validation runner (distances, times, wall clock, top-5 maneuvers, NoRouteException-safe) |
| `packages/osm_bundle_tool/bin/build_geocoder.dart` | geocoder-only bundle build (re-extract + `Geocoder.build`) |
| `packages/osm_bundle_tool/lib/src/split_tiles.dart` | `--split N` slice tile building with per-tile slice ownership |
| `packages/osm_bundle_tool/lib/src/mbf_merge.dart` + `bin/merge_mbf.dart` | MBF store merge |
| `packages/osm_bundle_tool/test/mbf_merge_test.dart` | unit tests: merge readability, sorted index, split==direct off-seam |
| `packages/maps_core/lib/src/tilestore/mbf.dart` | `MbfReader.tileIds` (public tile enumeration for merging) |

## Reproduce

```sh
# bundle pieces (graph.bin already built; geocoder + tiles as below)
dart run packages/osm_bundle_tool/bin/build_geocoder.dart nigeria.osm.pbf \
  <outdir> 6.40 3.20 6.70 3.55
dart run packages/osm_bundle_tool/bin/build_bundle_bbox.dart nigeria.osm.pbf \
  /tmp/lagos-slices 6.40 3.20 6.70 3.55 --split 4
dart run packages/osm_bundle_tool/bin/merge_mbf.dart \
  <outdir>/tiles.mbf /tmp/lagos-slices/tiles.slice*.mbf

# validation
dart run packages/osm_bundle_tool/bin/validate_routes.dart <outdir>
BUNDLE_DIR=<outdir> dart run test/integration/realworld_check.dart
```
