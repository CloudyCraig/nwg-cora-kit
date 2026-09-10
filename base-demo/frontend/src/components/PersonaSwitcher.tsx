import { ChangeEvent } from "react";

import { usePersona } from "../PersonaContext";
import { TIER_COLOURS, tierLabel } from "../personas";

export default function PersonaSwitcher() {
  const { persona, setPersonaById, personas } = usePersona();
  const tierColour = TIER_COLOURS[persona.tier];

  function onChange(event: ChangeEvent<HTMLSelectElement>) {
    setPersonaById(event.target.value);
  }

  return (
    <div className="persona-switcher" data-testid="persona-switcher">
      <span className="persona-switcher__avatar" aria-hidden="true">
        {persona.avatar}
      </span>
      <select
        aria-label="Select customer persona"
        value={persona.id}
        onChange={onChange}
      >
        {personas.map((p) => (
          <option key={p.id} value={p.id}>
            {`${p.name} - ${tierLabel(p.tier)}`}
          </option>
        ))}
      </select>
      <span
        className="tier-chip"
        style={{ background: tierColour.bg, color: tierColour.fg }}
      >
        {tierLabel(persona.tier)}
      </span>
    </div>
  );
}
