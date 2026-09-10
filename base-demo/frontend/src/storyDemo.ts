// Canonical customer + payment context for the payment-meltdown demo story
// (RUM → Session Replay → APM → DB Query Performance → ITSI Episode).
//
// Every surface — SPA cold load, chaos audit events, Presenter HUD — should
// reference these constants so the audience always sees the same persona
// (Margaret Gold, FPS pocket-money payment) without the presenter re-selecting.

import { PaymentRequest } from "./api";
import { Persona, findPersona } from "./personas";

export const STORY_MELTDOWN_PERSONA_ID = "cust-uk-003";
export const STORY_MELTDOWN_SCHEME: PaymentRequest["scheme"] = "FPS";
export const STORY_MELTDOWN_PAYEE_ID = "payee-margaret-henry";
export const STORY_MELTDOWN_AMOUNT_MINOR = 2_500;
export const STORY_MELTDOWN_REFERENCE = "Pocket money";

/** JSON-friendly block stamped on chaos-audit events for ITSI / SIEM pivots. */
export const STORY_MELTDOWN_AUDIT_CONTEXT = {
  customer_id: STORY_MELTDOWN_PERSONA_ID,
  customer_name: "Margaret",
  customer_tier: "gold",
  payment_scheme: STORY_MELTDOWN_SCHEME,
  payee_name: "Henry (grandson)",
  payment_reference: STORY_MELTDOWN_REFERENCE,
  amount_minor_units: STORY_MELTDOWN_AMOUNT_MINOR,
} as const;

export function meltdownPersona(): Persona {
  const p = findPersona(STORY_MELTDOWN_PERSONA_ID);
  if (!p) {
    throw new Error(`story persona ${STORY_MELTDOWN_PERSONA_ID} missing from personas.ts`);
  }
  return p;
}

/** One-line label for Presenter HUD / ops cards. */
export function meltdownStoryLabel(): string {
  return "Margaret (Gold) · FPS · £25.00 to Henry — Pocket money";
}
