// Draws images/cities.svg, the homepage's origin story on a map: the 37 and its stop at Church & 14th,
// every Muni line and BART around it, and the lower 48 (the Census Bureau's outlines, public domain, from
// us-atlas) with a card per city showing its trains in their colors, from the app's bundled line maps
// (App/Snapshots), tied by a line to where the city is. All in one projection, so the page can zoom out
// from the stop to San Francisco to the country as you scroll (the svg's data-view-* boxes; see "Origin
// story" in index.src.html). build.sh inlines it. Run it again when a city is added:
//
//     npm install --prefix /tmp/geo d3-geo@3.1.1 topojson-client@3.1.0 us-atlas@3.0.1
//     node site/scripts/cities.mjs /tmp/geo/node_modules

import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const modules = process.argv[2];
if (!modules) throw new Error("usage: node site/scripts/cities.mjs <node_modules with d3-geo, topojson-client, us-atlas>");
const require = createRequire(join(modules, "x.js"));
const { geoAlbers, geoConicEqualAreaRaw, geoPath } = require("d3-geo");
const { feature, mesh, merge } = require("topojson-client");
const states = require("us-atlas/states-10m.json");

const here = dirname(fileURLToPath(import.meta.url));
const snapshots = join(here, "..", "..", "App", "Snapshots");

// The cities in the order they joined, as the page pops them in; where each one's card goes (above
// the map or below it, left to right, so the lines to them don't cross); who runs what's there.
const CITIES = [
  { id: "sf", name: "San Francisco", agencies: "Muni · BART · ferries", at: [-122.4194, 37.7749], top: false, column: 0 },
  { id: "seattle", name: "Seattle", agencies: "Metro · Sound Transit", at: [-122.3321, 47.6062], top: true, column: 0 },
  { id: "nyc", name: "New York", agencies: "MTA · PATH · ferries", at: [-74.006, 40.7128], top: false, column: 3 },
  { id: "boston", name: "Boston", agencies: "MBTA", at: [-71.0589, 42.3601], top: true, column: 2 },
  { id: "chicago", name: "Chicago", agencies: "CTA", at: [-87.6298, 41.8781], top: true, column: 1 },
  { id: "dc", name: "Washington, D.C.", agencies: "Metro · Metrobus", at: [-77.0369, 38.9072], top: false, column: 2 },
  { id: "la", name: "Los Angeles", agencies: "LA Metro", at: [-118.2437, 34.0522], top: false, column: 1 },
];

const W = 1000, H = 980, CARD_W = 226, CARD_H = 168, MARGIN = 14;
const MAP = [[30, 205], [970, 770]];

// The lower 48: no Alaska, Hawaii or territories, whose FIPS codes are 02, 15 and 60 up.
const lower48 = { ...states.objects.states, geometries: states.objects.states.geometries.filter((g) => !["02", "15"].includes(g.id) && Number(g.id) < 60) };
const nation = merge(states, lower48.geometries);
const projection = geoAlbers().fitExtent(MAP, nation);
const path = geoPath(projection).digits(1);
const borders = mesh(states, lower48, (a, b) => a !== b);

/** As the app's (MapLine.isNetwork): subways, light rail, streetcars, cable cars, BART, PATH and the
 *  Staten Island Railway; not buses, ferries, water taxis or commuter trains. */
const isNetwork = (line, city) =>
  ["subway", "cableway"].includes(line.mode) || (line.mode === "metro" && !line.name.startsWith("Water Taxi"))
  || (line.mode === "rail" && (city === "sf" || city === "nyc"));

/** As the app's (Color.legible on a dark map): dark colors lifted so they show on the night-blue cards. */
function legible(hex) {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  const light = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  if (light >= 0.45) return hex;
  const lift = (c) => Math.round(c + (255 - c) * (0.45 - light) * 1.4).toString(16).padStart(2, "0");
  return `#${lift(r)}${lift(g)}${lift(b)}`;
}

const columns = (top) => CITIES.filter((c) => c.top === top).length;
function cardCenter(city) {
  const x = MARGIN + (W - 2 * MARGIN) / columns(city.top) * (city.column + 0.5);
  return [x, city.top ? MARGIN + CARD_H / 2 : H - MARGIN - CARD_H / 2];
}

const r1 = (n) => Math.round(n * 10) / 10;

// ---- San Francisco up close, in the same projection: a few units across, so in finer numbers.
const r4 = (n) => Math.round(n * 10000) / 10000;
const sfLines = JSON.parse(readFileSync(join(snapshots, "linemap-sf.json"), "utf8")).lines;
/** A line's shapes as a path, leaving out points closer than `step` units apart. */
function traced(line, step) {
  return line.shapes.filter((sh) => sh.length > 1).map((sh) => {
    const placed = sh.map(([lat, lon]) => projection([lon, lat]).map(r4))
      .filter((p, i, all) => i === 0 || i === all.length - 1 || Math.hypot(p[0] - all[i - 1][0], p[1] - all[i - 1][1]) >= step);
    return "M" + placed.map((p) => p.join(" ")).join("L");
  }).join("");
}
// Buses first and quiet, in Muni red; Metro, cable cars and BART on top in their colors.
const sfLayer = [...sfLines].sort((a, b) => (a.mode === "bus") === (b.mode === "bus") ? 0 : a.mode === "bus" ? -1 : 1)
  .filter((l) => l.id !== "37")
  .map((l) => `<path class="${l.mode === "bus" ? "bus" : "rail"}" d="${traced(l, 0.004)}"${l.mode === "bus" ? "" : ` stroke="${legible(l.color ?? "#BF1A26")}"`}/>`).join("");
const the37 = sfLines.find((l) => l.id === "37");
// The 37's stop toward the Haight, 14th St & Church St, where it all started.
const stop = projection([-122.42898, 37.76783]).map(r4);

/** A box around points, with room around it (a share of its size). */
function around(points, room) {
  const xs = points.map((p) => p[0]), ys = points.map((p) => p[1]);
  const [x0, x1, y0, y1] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
  const [w, h] = [x1 - x0, y1 - y0];
  return [x0 - w * room, y0 - h * room, w * (1 + 2 * room), h * (1 + 2 * room)].map(r4).join(" ");
}
const project = (line) => line.shapes.flat().map(([lat, lon]) => projection([lon, lat]));
// The 37 close up; then San Francisco itself (Muni's lines, not BART's run out into the East Bay).
const view37 = around(project(the37), 0.15);
const viewSF = around(sfLines.filter((l) => !/^[A-Z][a-z]+$|^OAK$/.test(l.id)).flatMap(project), 0.04);

/** A city's trains fitted into its card's picture, a path per line in its color. */
function network(city, box) {
  const lines = JSON.parse(readFileSync(join(snapshots, `linemap-${city.id}.json`), "utf8")).lines.filter((l) => isNetwork(l, city.id));
  const points = lines.flatMap((l) => l.shapes.flat());
  const lats = points.map((p) => p[0]), lons = points.map((p) => p[1]);
  const [minLat, maxLat, minLon, maxLon] = [Math.min(...lats), Math.max(...lats), Math.min(...lons), Math.max(...lons)];
  const squeeze = Math.cos(((minLat + maxLat) / 2) * Math.PI / 180);
  const scale = Math.min(box.w / ((maxLon - minLon) * squeeze), box.h / (maxLat - minLat));
  const place = ([lat, lon]) => [r1(box.x + box.w / 2 + (lon - (minLon + maxLon) / 2) * squeeze * scale),
                                 r1(box.y + box.h / 2 - (lat - (minLat + maxLat) / 2) * scale)];
  return lines.map((line) => {
    const d = line.shapes.filter((s) => s.length > 1).map((s) => {
      // Points closer than a unit apart don't show; leave them out.
      const placed = s.map(place).filter((p, i, all) => i === 0 || i === all.length - 1
        || Math.hypot(p[0] - all[i - 1][0], p[1] - all[i - 1][1]) >= 1);
      return "M" + placed.map((p) => p.join(" ")).join("L");
    }).join("");
    return `<path d="${d}" stroke="${legible(line.color ?? "#BF1A26")}"/>`;
  }).join("");
}

const cards = CITIES.map((city, i) => {
  const at = projection(city.at).map(r1);
  const [cx, cy] = cardCenter(city);
  const x = r1(cx - CARD_W / 2), y = r1(cy - CARD_H / 2);
  const edge = [cx, city.top ? y + CARD_H : y];
  const box = { x: x + 12, y: y + 12, w: CARD_W - 24, h: CARD_H - 70 };
  return `<g class="city" data-city="${city.id}" style="--i: ${i}">
<path class="leader" pathLength="1" d="M${at.join(" ")}L${edge.map(r1).join(" ")}"/>
<circle class="spot" cx="${at[0]}" cy="${at[1]}" r="7"/><circle class="ping" cx="${at[0]}" cy="${at[1]}" r="7"/>
<g class="card" style="transform-origin: ${r1(cx)}px ${r1(cy)}px">
<rect x="${x}" y="${y}" width="${CARD_W}" height="${CARD_H}" rx="18"/>
<g class="lines">${network(city, box)}</g>
<text class="name" x="${r1(cx)}" y="${r1(y + CARD_H - 32)}">${city.name.replace("&", "&amp;")}</text>
<text class="who" x="${r1(cx)}" y="${r1(y + CARD_H - 12)}">${city.agencies}</text>
</g></g>`;
}).join("\n");

const svg = `<svg class="us" viewBox="0 0 ${W} ${H}" data-view-37="${view37}" data-view-sf="${viewSF}" data-view-us="0 0 ${W} ${H}" role="img" aria-label="The 37 at Church and 14th Street in San Francisco, then every Muni line, then a map of the United States with the seven cities 37 Shades of Late covers: ${CITIES.map((c) => c.name).join(", ")}">
<path class="land" d="${path(nation)}"/>
<path class="borders" d="${path(borders)}"/>
<g class="sf">${sfLayer}</g>
<g class="the37"><path d="${traced(the37, 0.002)}"/><circle class="ring" cx="${stop[0]}" cy="${stop[1]}" r="0.012"/><circle class="stop" cx="${stop[0]}" cy="${stop[1]}" r="0.012"/></g>
${cards}
</svg>
`;
writeFileSync(join(here, "..", "images", "cities.svg"), svg);
// The same country and where each city is, for the stats page's map (src/stats.html).
writeFileSync(join(here, "..", "images", "us-map.json"), JSON.stringify({
  width: W, height: H, land: path(nation), borders: path(borders),
  cities: Object.fromEntries(CITIES.map((c) => [c.id, { name: c.name, at: projection(c.at).map(r1) }])),
  albers: albersParameters(),
}));

/** The projection, for the page to place any longitude and latitude itself (a phone's rough place):
 *  d3's Albers is a conic equal-area one, turned 96° and with parallels 29.5° and 45.5°, scaled by k
 *  and moved by dx, dy. */
function albersParameters() {
  const raw = geoConicEqualAreaRaw(29.5 * Math.PI / 180, 45.5 * Math.PI / 180);
  const k = projection.scale(), probe = [-100, 40];
  const [x, y] = raw((probe[0] + 96) * Math.PI / 180, probe[1] * Math.PI / 180);
  const [px, py] = projection(probe);
  return { k: r4(k), dx: r4(px - k * x), dy: r4(py + k * y) };
}
console.log(`images/cities.svg: ${Math.round(svg.length / 1024)} KB`);
