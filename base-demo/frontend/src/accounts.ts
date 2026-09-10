// Demo "current account" associated with each persona.
//
// There is no real bank back-end behind this; the SPA shows an account
// header on the Home page (sort code, masked account number, available
// balance) so the audience sees something that reads like an online-banking
// app rather than a payments form. The numbers are deterministic per
// persona so a refresh / persona switch is consistent for the entire demo
// session.
//
// The "available balance" is also used by the Recent Payments preview to
// show a running pseudo-balance after each accepted payment — it is
// purely cosmetic; the back-end never reads or returns it.

import { Persona, Tier } from "./personas";

export interface Account {
  sortCode: string;       // 6-digit, formatted via format.ts::formatSortCode
  accountNumber: string;  // 8-digit, masked via format.ts::maskAccount
  productName: string;    // e.g. "Reward current account"
  // Available balance in minor units (pence). Deterministic per persona —
  // bronze customers carry a smaller balance than gold so the audience
  // immediately reads "this is a different customer profile" without us
  // having to call it out in the talk-track.
  availableBalanceMinor: number;
  // Optional overdraft headroom in minor units, mirrored from the public
  // NatWest reward-current-account product page. Renders as "of which
  // £500.00 is overdraft" under the balance.
  overdraftLimitMinor: number;
}

// Stable UK sort code shared across the UK personas. 60-00-01 is
// published as a documentation sort code by UK Finance, so it cannot
// collide with a real customer.
const SORT_CODE_UK = "600001";

// Per-country sort codes for the EU personas. Opaque 6-digit strings
// modelled on bank-of-Spain / Bundesbank / Banque-de-France / Banca-
// d'Italia documentation ranges that are reserved for demos and not
// assigned to live accounts. Six digits so format.ts::formatSortCode
// keeps rendering them as XX-XX-XX without code changes.
const SORT_CODE_ES = "002001";
const SORT_CODE_DE = "500700";
const SORT_CODE_FR = "300040";
const SORT_CODE_IT = "010001";

// Per-tier defaults. Persona-specific overrides (see ACCOUNTS_BY_PERSONA)
// can override any field. Keeping a separate tier baseline means adding
// a new persona is one line + a balance.
const TIER_BASELINE: Record<Tier, Pick<Account, "productName" | "availableBalanceMinor" | "overdraftLimitMinor">> = {
  bronze: {
    productName: "Select current account",
    availableBalanceMinor: 124_783,    // £1,247.83
    overdraftLimitMinor: 50_000,       // £500.00
  },
  silver: {
    productName: "Reward current account",
    availableBalanceMinor: 453_120,    // £4,531.20
    overdraftLimitMinor: 200_000,      // £2,000.00
  },
  gold: {
    productName: "Premier reserve account",
    availableBalanceMinor: 1_840_255,  // £18,402.55
    overdraftLimitMinor: 500_000,      // £5,000.00
  },
};

const ACCOUNTS_BY_PERSONA: Record<string, Partial<Account>> = {
  "cust-uk-001": { sortCode: SORT_CODE_UK, accountNumber: "34567812" },
  "cust-uk-002": { sortCode: SORT_CODE_UK, accountNumber: "45678923" },
  "cust-uk-003": { sortCode: SORT_CODE_UK, accountNumber: "56789034" },

  // EU personas. Product names follow the NatWest Europe naming
  // convention so the audience reads them at a glance as a different
  // brand line. Distinct account numbers keep the masked ".... 1234"
  // shown in the Home hero genuinely identifying the customer (the
  // fallback derivation used to produce "0000 0001" for every EU
  // persona, which was visually broken).
  "cust-es-001": {
    sortCode: SORT_CODE_ES,
    accountNumber: "61003421",
    productName: "Cuenta Corriente NatWest Europe",
    availableBalanceMinor: 86_400,        // EUR 864.00 - bronze
  },
  "cust-de-001": {
    sortCode: SORT_CODE_DE,
    accountNumber: "71009870",
    productName: "Premium Konto NatWest Europe",
    availableBalanceMinor: 2_245_900,     // EUR 22,459.00 - gold
    overdraftLimitMinor: 500_000,         // EUR 5,000.00
  },
  "cust-fr-001": {
    sortCode: SORT_CODE_FR,
    accountNumber: "55012744",
    productName: "Compte Premier NatWest Europe",
    availableBalanceMinor: 412_800,       // EUR 4,128.00 - silver
  },
  "cust-it-001": {
    sortCode: SORT_CODE_IT,
    accountNumber: "63005512",
    productName: "Conto Corrente NatWest Europe",
    availableBalanceMinor: 98_320,        // EUR 983.20 - bronze
  },
};

// Map ISO-3166-1 alpha-2 country code -> sort code for the EU
// fallback path. Lets a future EU persona render with a country-
// appropriate sort code even without an explicit ACCOUNTS_BY_PERSONA
// entry. UK falls through to SORT_CODE_UK below.
const COUNTRY_SORT_CODE: Record<string, string> = {
  ES: SORT_CODE_ES,
  DE: SORT_CODE_DE,
  FR: SORT_CODE_FR,
  IT: SORT_CODE_IT,
};

export function accountFor(persona: Persona): Account {
  const baseline = TIER_BASELINE[persona.tier];
  const override = ACCOUNTS_BY_PERSONA[persona.id] ?? {};
  const country = persona.location?.country;
  // Sort code: explicit override -> country-derived -> UK default.
  // Without the country lookup, every EU persona without an override
  // would render with the UK demo sort code 60-00-01, which looks
  // wrong next to a Madrid / Frankfurt / Paris / Milan address.
  const sortCode = override.sortCode
    ?? (country && COUNTRY_SORT_CODE[country])
    ?? SORT_CODE_UK;
  return {
    sortCode,
    // Use last-4 of the persona id as a stable fallback when a persona
    // isn't in the override map (so a future addition still renders).
    accountNumber: override.accountNumber ?? `0000${persona.id.replace(/\D/g, "").slice(-4) || "0000"}`,
    productName: override.productName ?? baseline.productName,
    availableBalanceMinor:
      override.availableBalanceMinor ?? baseline.availableBalanceMinor,
    overdraftLimitMinor:
      override.overdraftLimitMinor ?? baseline.overdraftLimitMinor,
  };
}
