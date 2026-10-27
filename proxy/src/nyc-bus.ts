/**
 * New York's buses, from MTA Bus Time: New York City Transit and the MTA Bus Company (most of the
 * Queens routes). Lines, stops and street shapes come from its OneBusAway server like Seattle's (see
 * seattle.ts), but its OneBusAway arrivals are always empty; live times and bus positions come from
 * its SIRI StopMonitoring call instead. Served under /v1/nyc/... next to the subway (see nyc.ts).
 * The key is the MTA_BUSTIME_KEY secret.
 */

import type { Region, SeattleDeps, StopData, Visit } from "./seattle";

const SIRI = "https://bustime.mta.info/api/siri/stop-monitoring.json";

export const NYC_BUS: Region = {
  base: "https://bustime.mta.info/api/where",
  agencies: ["MTA NYCT", "MTABC"],
  cache: "nycbus",
  stopPattern: /^MTA_\d+$/,
  // Type 711 is MTA's substitute buses, like "J Shuttle Bus" during track work.
  skipRoute: (route) => route.type === 711,
  stopName: (name) => titleCase(name),
  fetchStop,
};

/** Every line's next buses at a stop: when, which way, and where each bus is now. */
async function fetchStop(stop: string, deps: SeattleDeps): Promise<StopData> {
  const url = new URL(SIRI);
  url.search = new URLSearchParams({
    key: deps.apiKey,
    version: "2",
    MonitoringRef: stop.replace(/^MTA_/, ""),
    MaximumStopVisits: "30",
  }).toString();
  const response = await fetch(url);
  if (response.status === 429) throw deps.rateLimited();
  if (!response.ok) throw deps.upstream(response.status);
  const delivery = (await response.json() as any)?.Siri?.ServiceDelivery?.StopMonitoringDelivery?.[0] ?? {};
  const visits: Visit[] = [];
  let name = "";
  for (const visit of delivery.MonitoredStopVisit ?? []) {
    const journey = visit.MonitoredVehicleJourney ?? {};
    const call = journey.MonitoredCall ?? {};
    name ||= first(call.StopPointName);
    const expected = call.ExpectedDepartureTime ?? call.ExpectedArrivalTime;
    const time = expected ?? call.AimedDepartureTime ?? call.AimedArrivalTime;
    if (!time) continue;
    // A bus still finishing its previous trip, or waiting out a layover, reports where it is now,
    // which isn't on its way to this stop yet.
    const progress = String(journey.ProgressStatus ?? "");
    const live = Boolean(expected && journey.Monitored && journey.VehicleLocation) && !/prevTrip|layover/.test(progress);
    const entry: Visit = {
      routeId: String(journey.LineRef ?? ""),
      direction: String(journey.DirectionRef ?? ""),
      destination: titleCase(first(journey.DestinationName)),
      time: new Date(time).toISOString(),
      live,
    };
    if (live) {
      // MTA's bearing is counterclockwise from east; the app's is clockwise from north.
      const bearing = Number(journey.Bearing);
      entry.vehicle = {
        lat: Number(journey.VehicleLocation.Latitude),
        lon: Number(journey.VehicleLocation.Longitude),
        bearing: Number.isFinite(bearing) ? (((90 - bearing) % 360) + 360) % 360 : undefined,
      };
    }
    visits.push(entry);
  }
  visits.sort((a, b) => Date.parse(a.time) - Date.parse(b.time));
  return { name: titleCase(name), visits };
}

/** SIRI wraps names in lists in version 2. */
function first(value: unknown): string {
  return String((Array.isArray(value) ? value[0] : value) ?? "").replace(/\s+/g, " ").trim();
}

/** "5 AV/UNION ST" → "5 Av/Union St", "BAY RIDGE via 5 AV" → "Bay Ridge via 5 Av", like the subway's names. */
export function titleCase(name: string): string {
  return name.toLowerCase()
    .replace(/(^|[\s/&(-])([a-z])/g, (_, before, letter) => before + letter.toUpperCase())
    .replace(/ Via /g, " via ");
}
