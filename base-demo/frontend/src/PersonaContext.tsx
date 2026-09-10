// PersonaContext - the single source of truth for "who is logged in" inside
// the SPA. Persona is selected by the user via the header switcher and
// persisted to localStorage so a refresh keeps the selection.
//
// Side-effects on selection change:
//   - localStorage write (so the next page load keeps the choice)
//   - RUM session attributes refreshed (rum.ts::setRumPersona) so that any
//     RUM event emitted after this change carries customer.id and
//     customer.tier; the Splunk RUM "Sessions" view can then split by tier.
//
// This is NOT real authentication. There is no token, no server-side
// validation, and no session boundary. The backend trusts whatever
// customer_id / customer_tier the SPA sends in the body. That is fine for
// the demo (and explicitly called out in the talk-track) but anyone using
// this template for production must replace this with a real auth context.

import {
  ReactNode,
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";

import {
  DEFAULT_PERSONA_ID,
  PERSONAS,
  Persona,
  findPersona,
} from "./personas";
import { recordPageAction, setRumPersona } from "./rum";

const STORAGE_KEY = "natwest-demo-persona";

interface PersonaContextValue {
  persona: Persona;
  setPersonaById: (id: string) => void;
  personas: Persona[];
}

const PersonaContext = createContext<PersonaContextValue | null>(null);

function loadInitialPersona(): Persona {
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY);
    const match = findPersona(stored);
    if (match) return match;
  } catch {
    // Private mode / disabled storage - silently fall through to default.
  }
  // Non-null assertion: PERSONAS is a non-empty const array seeded in
  // personas.ts and DEFAULT_PERSONA_ID is one of its ids by construction.
  return findPersona(DEFAULT_PERSONA_ID) ?? PERSONAS[0]!;
}

export function PersonaProvider({ children }: { children: ReactNode }) {
  const [persona, setPersona] = useState<Persona>(() => loadInitialPersona());

  // Push the initial persona into RUM as soon as the provider mounts so the
  // first page-view RUM event already carries customer.tier. RUM init runs
  // before React mounts (see main.tsx), so the SDK is guaranteed to be
  // ready by this point.
  useEffect(() => {
    setRumPersona(persona);
  }, [persona]);

  const setPersonaById = useCallback(
    (id: string) => {
      const next = findPersona(id);
      if (!next) return;
      // Capture the previous persona BEFORE we call setPersona() so the
      // RUM action carries an accurate from/to. We read from the closed-
      // over `persona` value rather than calling setPersona with an
      // updater function, because we want the *committed* state at the
      // time the click happened (not a hypothetical mid-batch state).
      const previous = persona;
      setPersona(next);
      try {
        window.localStorage.setItem(STORAGE_KEY, next.id);
      } catch {
        // ignore - quota / private mode
      }
      // Skip the RUM event when the operator selects the persona that
      // was already active (no-op switch); the picker UI already
      // disables the active option, so this is purely defensive.
      if (previous.id === next.id) return;
      recordPageAction("persona.switched", {
        "persona.from": previous.id,
        "persona.to": next.id,
        "tier.from": previous.tier,
        "tier.to": next.tier,
        "location.from": previous.location?.city ?? "",
        "location.to": next.location?.city ?? "",
        "country.from": previous.location?.country ?? "",
        "country.to": next.location?.country ?? "",
      });
    },
    [persona],
  );

  const value = useMemo<PersonaContextValue>(
    () => ({ persona, setPersonaById, personas: PERSONAS }),
    [persona, setPersonaById],
  );

  return (
    <PersonaContext.Provider value={value}>{children}</PersonaContext.Provider>
  );
}

export function usePersona(): PersonaContextValue {
  const ctx = useContext(PersonaContext);
  if (!ctx) {
    throw new Error("usePersona must be used inside <PersonaProvider>");
  }
  return ctx;
}
