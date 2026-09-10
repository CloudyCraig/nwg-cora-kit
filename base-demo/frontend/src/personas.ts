// Demo personas - the SPA's "current user" for the duration of a session.
//
// There is no real auth in this demo; persona is a SPA-side selection
// persisted in localStorage by PersonaContext. The selection drives:
//
//   1. customer.id / customer.tier on every outbound POST to /api/process
//      (so backend spans, logs and dashboards can split by tier).
//   2. The same attributes pushed onto the active RUM session via
//      SplunkRum.setGlobalAttributes (rum.ts::setRumPersona).
//   3. The header badge / tier chip in the SPA UI.
//
// Tiers are deliberately a small allow-list (3 values) so APM cardinality
// stays bounded. Adding a new tier means updating this file, the Helm
// `tierBehaviour.*` strings, and the dashboards in terraform/dashboard.tf.

export type Tier = "bronze" | "silver" | "gold";

// Geographic context for a persona. Optional so legacy code that doesn't
// care about location still type-checks; the SPA wires `location.city` /
// `location.country` / `location.region` through to the payment payload
// and pushes them onto the RUM session attributes when present. The
// gateway tags them on every span (see app/service.py::process) so APM /
// RUM / ITSI pivots by `customer.location` light up live the moment the
// presenter switches persona.
//
// Bounded cardinality is enforced server-side (short-string coercion in
// app/service.py); these values are part of an opinionated allow-list
// that mirrors the LOCATIONS table in traffic-generator/generate.py.
export interface PersonaLocation {
  city: string;
  country: string;   // ISO-3166-1 alpha-2
  region: string;    // matches LOCATIONS.region in the traffic-generator
  lat: number;
  lon: number;
}

export interface Persona {
  id: string;
  name: string;
  tier: Tier;
  // Single-emoji avatar, shown next to the name in the header switcher.
  // Pure aesthetic; not used for logic.
  avatar: string;
  // Optional geography. When set, the active payment payload + RUM session
  // attributes carry customer.location / customer.country / customer.region.
  // The UK trio leaves this undefined so legacy demos keep their shape.
  location?: PersonaLocation;
}

// Named personas used by the SPA. The original three are UK-domiciled (the
// historical demo shape); the four additions cover the major European
// markets so the persona switcher can drive a single human-of-known-location
// into the system - the SPA-driven counterpart to the traffic-generator's
// weighted LOCATION_MIX. The `id` is a stable opaque string that the
// back-end treats as the customer identifier on spans + logs.
export const PERSONAS: Persona[] = [
  { id: "cust-uk-001", name: "Olivia",   tier: "bronze", avatar: "\u{1F469}" },  // woman emoji
  { id: "cust-uk-002", name: "James",    tier: "silver", avatar: "\u{1F468}" },  // man emoji
  { id: "cust-uk-003", name: "Margaret", tier: "gold",   avatar: "\u{1F475}" },  // older woman emoji
  {
    id: "cust-es-001",
    name: "Sof\u00eda",
    tier: "bronze",
    avatar: "\u{1F469}\u200d\u{1F4BB}",
    location: { city: "madrid",    country: "ES", region: "EU-SOUTH",   lat: 40.4168, lon: -3.7038 },
  },
  {
    id: "cust-de-001",
    name: "Klaus",
    tier: "gold",
    avatar: "\u{1F468}\u200d\u{1F4BC}",
    location: { city: "frankfurt", country: "DE", region: "EU-CENTRAL", lat: 50.1109, lon:  8.6821 },
  },
  {
    id: "cust-fr-001",
    name: "Sophie",
    tier: "silver",
    avatar: "\u{1F469}\u200d\u{1F3A8}",
    location: { city: "paris",     country: "FR", region: "EU-WEST",    lat: 48.8566, lon:  2.3522 },
  },
  {
    id: "cust-it-001",
    name: "Marco",
    tier: "bronze",
    avatar: "\u{1F468}\u200d\u{1F373}",
    location: { city: "milan",     country: "IT", region: "EU-SOUTH",   lat: 45.4642, lon:  9.1900 },
  },
];

export const TIERS: Tier[] = ["bronze", "silver", "gold"];

// Default selection on first load. Margaret (Gold) is the canonical persona
// for the payment-meltdown story (docs/customer/story-rum-apm-postgres.md).
// Tier-mix / bronze-canary demos: switch to Olivia in the header switcher.
export const DEFAULT_PERSONA_ID = "cust-uk-003";

export function findPersona(id: string | null | undefined): Persona | undefined {
  if (!id) return undefined;
  return PERSONAS.find((p) => p.id === id);
}

// Brand colour per tier. Used by the header chip + history table badge.
// Bronze/Silver/Gold are intentionally close to the metallic-loyalty palette
// so the audience reads them at a glance without needing the legend.
export const TIER_COLOURS: Record<Tier, { bg: string; fg: string }> = {
  bronze: { bg: "#cd7f32", fg: "white" },
  silver: { bg: "#b0b0b8", fg: "#1c1c1c" },
  gold:   { bg: "#d4af37", fg: "#1c1c1c" },
};

export function tierLabel(tier: Tier): string {
  return tier.charAt(0).toUpperCase() + tier.slice(1);
}
