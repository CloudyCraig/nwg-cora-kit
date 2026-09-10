// Saved-payee catalogue. Each persona has 3 saved payees and one "New
// payee" slot. Selecting a payee on the Send Money page pre-fills the
// form so the demo runs as a quick click-through rather than a typing
// exercise.
//
// Amounts are chosen so the SCA threshold (£25 = 2500 minor units on
// the mobile channel) is straddled across personas: at least one payee
// per persona is *under* the threshold (no SCA) and at least one is
// *over* (triggers the mobile push-notification overlay). That way Act
// II.B's PSD2 narrative works regardless of which persona is on stage.
//
// Schemes follow real-world rails:
//   FPS   - UK same-day, single payment, <=GBP 1m   (most retail payments)
//   BACS  - UK 3-day, recurring                     (utility direct debits)
//   CHAPS - UK same-day, large value                (mortgage, deposits)
//   SEPA  - EUR Single Euro Payments Area           (EU domestic + cross-border)
//   SWIFT - international, non-EUR or to/from UK    (cross-currency)
//
// EU personas (Sofia/Klaus/Sophie/Marco) default to SEPA for EU-
// domestic flows and SWIFT for cross-border-to-UK to demonstrate the
// payment.scheme split end-to-end in the Splunk APM service map.
//
// Reference is the free-text "what's it for" that the bank shows to the
// payee and the customer's audit trail. Mirrors NatWest's online-banking
// "Reference" field shown next to a payee on the confirm screen.

import { PaymentRequest } from "./api";

export interface Payee {
  id: string;
  // Friendly name shown on the payee chip and the success card.
  name: string;
  // Single emoji used as the payee avatar — purely visual; not used for
  // logic. Keep to one Unicode codepoint so the chips line up.
  avatar: string;
  // 8-digit account number rendered as masked "•••• 1234". The full
  // string is never sent to the back-end (the demo's process endpoint
  // doesn't take it) — we just show it in the UI to read like a real
  // online-banking confirm screen.
  accountNumber: string;
  // 6-digit sort code.
  sortCode: string;
  // Default payment amount in minor units (pence).
  amountMinor: number;
  // Default rail. The form's "Advanced" panel still lets the user
  // override per-send.
  scheme: PaymentRequest["scheme"];
  // Default currency. Most are GBP; the international payee uses EUR.
  currency: PaymentRequest["currency"];
  // Two-letter ISO country for debtor/creditor. UK by default.
  creditorCountry: string;
  // Optional reference. Displayed on the confirm screen and stored on
  // the audit trail; kept short so the form layout doesn't overflow.
  reference: string;
}

// Per-persona payee lists. Persona ids come from personas.ts.
const PAYEES: Record<string, Payee[]> = {
  "cust-uk-001": [
    {
      id: "payee-olivia-flatmate",
      name: "John (flatmate)",
      avatar: "\u{1F9D1}",          // person emoji
      sortCode: "234567",
      accountNumber: "11220001",
      amountMinor: 2_000,            // £20.00 — under SCA threshold
      scheme: "FPS",
      currency: "GBP",
      creditorCountry: "GB",
      reference: "Bills - May",
    },
    {
      id: "payee-olivia-tfl",
      name: "TfL pay-as-you-go",
      avatar: "\u{1F687}",          // metro emoji
      sortCode: "200070",
      accountNumber: "55333412",
      amountMinor: 1_500,            // £15.00 — under SCA threshold
      scheme: "FPS",
      currency: "GBP",
      creditorCountry: "GB",
      reference: "Top-up",
    },
    {
      id: "payee-olivia-mortgage",
      name: "Mortgage (Halifax)",
      avatar: "\u{1F3E0}",          // house emoji
      sortCode: "110011",
      accountNumber: "98714003",
      amountMinor: 84_200,           // £842.00 — well over SCA threshold
      scheme: "BACS",
      currency: "GBP",
      creditorCountry: "GB",
      reference: "Direct Debit 06",
    },
  ],
  "cust-uk-002": [
    {
      id: "payee-james-maria",
      name: "Maria",
      avatar: "\u{1F469}",
      sortCode: "234567",
      accountNumber: "44567812",
      amountMinor: 5_000,            // £50.00 — over SCA threshold
      scheme: "FPS",
      currency: "GBP",
      creditorCountry: "GB",
      reference: "Dinner Sat",
    },
    {
      id: "payee-james-sky",
      name: "Sky Broadband",
      avatar: "\u{1F4F6}",          // antenna emoji
      sortCode: "200084",
      accountNumber: "66120033",
      amountMinor: 3_599,            // £35.99 — over SCA threshold
      scheme: "BACS",
      currency: "GBP",
      creditorCountry: "GB",
      reference: "Account 8821-A",
    },
    {
      id: "payee-james-mum",
      name: "Mum",
      avatar: "\u{1F469}\u200D\u{1F9B3}", // older woman, ZWJ + white-hair
      sortCode: "601234",
      accountNumber: "22459001",
      amountMinor: 10_000,           // £100.00 — over SCA threshold
      scheme: "FPS",
      currency: "GBP",
      creditorCountry: "GB",
      reference: "Birthday",
    },
  ],
  "cust-uk-003": [
    {
      id: "payee-margaret-henry",
      name: "Henry (grandson)",
      avatar: "\u{1F466}",          // boy emoji
      sortCode: "234567",
      accountNumber: "77998812",
      amountMinor: 2_500,            // £25.00 — *at* SCA threshold
      scheme: "FPS",
      currency: "GBP",
      creditorCountry: "GB",
      reference: "Pocket money",
    },
    {
      id: "payee-margaret-garden",
      name: "Garden Services",
      avatar: "\u{1F33F}",
      sortCode: "401001",
      accountNumber: "33446677",
      amountMinor: 7_500,            // £75.00 — over SCA threshold
      scheme: "FPS",
      currency: "GBP",
      creditorCountry: "GB",
      reference: "May visit",
    },
    {
      id: "payee-margaret-charity",
      name: "British Red Cross",
      avatar: "\u{1F3E5}",          // hospital emoji (close enough)
      sortCode: "200012",
      accountNumber: "88112233",
      amountMinor: 25_000,           // £250.00 — over SCA threshold
      scheme: "CHAPS",
      currency: "GBP",
      creditorCountry: "GB",
      reference: "Monthly donation",
    },
  ],

  // Sofia - Madrid, ES, bronze. Mix of local SEPA (low value, no SCA)
  // and one SWIFT cross-border to drive the international/roaming flow
  // narrated in Act II.B (payment.roaming attribute on the span).
  "cust-es-001": [
    {
      id: "payee-sofia-maria",
      name: "Mar\u00eda (hermana)",
      avatar: "\u{1F469}",
      sortCode: "002001",
      accountNumber: "10043501",
      amountMinor: 1_500,            // EUR 15.00 - under SCA threshold
      scheme: "SEPA",
      currency: "EUR",
      creditorCountry: "ES",
      reference: "Cena s\u00e1bado",
    },
    {
      id: "payee-sofia-iberdrola",
      name: "Iberdrola",
      avatar: "\u26a1",
      sortCode: "002095",
      accountNumber: "20074412",
      amountMinor: 4_780,            // EUR 47.80 - over SCA threshold
      scheme: "SEPA",
      currency: "EUR",
      creditorCountry: "ES",
      reference: "Factura electricidad",
    },
    {
      id: "payee-sofia-mum-uk",
      name: "Mum (London)",
      avatar: "\u{1F469}\u200D\u{1F9B3}",
      sortCode: "600001",
      accountNumber: "34501122",
      amountMinor: 15_000,           // GBP 150.00 - over SCA threshold, cross-border
      scheme: "SWIFT",
      currency: "GBP",
      creditorCountry: "GB",
      reference: "Mensual",
    },
  ],

  // Klaus - Frankfurt, DE, gold. Premium amounts; SEPA for European
  // business flows + one SWIFT to the London office.
  "cust-de-001": [
    {
      id: "payee-klaus-hans",
      name: "Hans (Gesch\u00e4ftspartner)",
      avatar: "\u{1F468}\u200d\u{1F4BC}",
      sortCode: "500700",
      accountNumber: "30021045",
      amountMinor: 18_500,           // EUR 185.00 - well over SCA, SEPA
      scheme: "SEPA",
      currency: "EUR",
      creditorCountry: "DE",
      reference: "Beratung Mai",
    },
    {
      id: "payee-klaus-securities",
      name: "Deutsche Securities",
      avatar: "\u{1F3DB}",
      sortCode: "500100",
      accountNumber: "70098012",
      amountMinor: 250_000,          // EUR 2,500.00 - high value SEPA
      scheme: "SEPA",
      currency: "EUR",
      creditorCountry: "DE",
      reference: "Wertpapierkauf",
    },
    {
      id: "payee-klaus-london-office",
      name: "London office",
      avatar: "\u{1F3E2}",
      sortCode: "600001",
      accountNumber: "44011055",
      amountMinor: 500_000,          // GBP 5,000.00 - large CHAPS-equivalent cross-border
      scheme: "SWIFT",
      currency: "GBP",
      creditorCountry: "GB",
      reference: "Q2 settlement",
    },
  ],

  // Sophie - Paris, FR, silver. All-domestic SEPA so the persona's
  // payments contribute to the "EU-WEST" Tag Spotlight slice without
  // also creating cross-border noise.
  "cust-fr-001": [
    {
      id: "payee-sophie-cafe",
      name: "Caf\u00e9 Le Procope",
      avatar: "\u2615",
      sortCode: "300040",
      accountNumber: "11220034",
      amountMinor: 1_200,            // EUR 12.00 - under SCA threshold
      scheme: "SEPA",
      currency: "EUR",
      creditorCountry: "FR",
      reference: "D\u00e9jeuner",
    },
    {
      id: "payee-sophie-edf",
      name: "\u00c9lectricit\u00e9 de France",
      avatar: "\u26a1",
      sortCode: "300030",
      accountNumber: "55007781",
      amountMinor: 8_950,            // EUR 89.50 - over SCA threshold
      scheme: "SEPA",
      currency: "EUR",
      creditorCountry: "FR",
      reference: "Facture \u00e9lectricit\u00e9",
    },
    {
      id: "payee-sophie-msf",
      name: "M\u00e9decins Sans Fronti\u00e8res",
      avatar: "\u{1F3E5}",
      sortCode: "300070",
      accountNumber: "20012009",
      amountMinor: 5_000,            // EUR 50.00 - over SCA threshold
      scheme: "SEPA",
      currency: "EUR",
      creditorCountry: "FR",
      reference: "Don mensuel",
    },
  ],

  // Marco - Milan, IT, bronze. Domestic SEPA for low-value family
  // transfers + one SWIFT to a UK sibling to seed the cross-border
  // story without dominating Marco's profile.
  "cust-it-001": [
    {
      id: "payee-marco-famiglia",
      name: "Maria (famiglia)",
      avatar: "\u{1F469}",
      sortCode: "010001",
      accountNumber: "30055621",
      amountMinor: 2_000,            // EUR 20.00 - under SCA threshold
      scheme: "SEPA",
      currency: "EUR",
      creditorCountry: "IT",
      reference: "Spesa settimanale",
    },
    {
      id: "payee-marco-enel",
      name: "Enel Energia",
      avatar: "\u26a1",
      sortCode: "010050",
      accountNumber: "70033445",
      amountMinor: 6_240,            // EUR 62.40 - over SCA threshold
      scheme: "SEPA",
      currency: "EUR",
      creditorCountry: "IT",
      reference: "Bolletta luce",
    },
    {
      id: "payee-marco-sister-uk",
      name: "Sister (London)",
      avatar: "\u{1F469}",
      sortCode: "600001",
      accountNumber: "77123344",
      amountMinor: 7_500,            // GBP 75.00 - over SCA threshold, cross-border
      scheme: "SWIFT",
      currency: "GBP",
      creditorCountry: "GB",
      reference: "Birthday",
    },
  ],
};

export function payeesFor(personaId: string): Payee[] {
  return PAYEES[personaId] ?? [];
}

export function findPayee(personaId: string, payeeId: string): Payee | undefined {
  return payeesFor(personaId).find((p) => p.id === payeeId);
}
