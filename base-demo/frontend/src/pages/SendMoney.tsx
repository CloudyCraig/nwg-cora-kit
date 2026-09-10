// Send Money — primary action surface of the SPA.
//
// Compared to the previous build, the form is now structured around the
// way real online-banking apps lay out a payment: pick a payee, set the
// amount, optional reference, then send. Scheme/currency/country fields
// live under an "Advanced" disclosure so the audience reads the form as
// a customer-facing screen rather than a developer test page.
//
// All observability behaviour from the previous build is preserved:
//   * recordPageAction("Send payment", ...) fires before the network
//     call so the RUM session carries the named span we pivot from.
//   * The mobile-channel PSD2 SCA overlay still triggers for amounts
//     above MOBILE_SCA_THRESHOLD_MINOR, with the same recordPageAction
//     bookends ("SCA challenge issued / approved / abandoned").
//   * appendHistory(summariseResponse(...)) still seeds localStorage so
//     the Recent Payments page and the Home activity preview can show
//     a "this browser" row even when the gateway's in-memory buffer
//     rotates away.
//   * customer_id / customer_tier on the payload still come from
//     PersonaContext, so the dashboard split-by-tier view lights up
//     after a persona switch.

import {
  Dispatch,
  FormEvent,
  SetStateAction,
  useEffect,
  useMemo,
  useState,
} from "react";
import { useLocation } from "react-router-dom";

import {
  PaymentRequest,
  PaymentResponse,
  buildSamplePayment,
  submitPayment,
} from "../api";
import CoraChat from "../components/CoraChat";
import StatusPill, { statusKindFor } from "../components/StatusPill";
import TraceLink from "../components/TraceLink";
import { AppConfig } from "../config";
import {
  formatMinor,
  formatSortCode,
  maskAccount,
  minorToPoundsString,
  parsePoundsToMinor,
} from "../format";
import { appendHistory, summariseResponse } from "../history";
import { usePersona } from "../PersonaContext";
import { TIER_COLOURS, tierLabel } from "../personas";
import { accountFor } from "../accounts";
import { Payee, payeesFor, findPayee } from "../payees";
import {
  recordPageAction,
  reportPaymentDegraded,
  DEGRADED_PAYMENT_CLIENT_MS,
} from "../rum";
import {
  STORY_MELTDOWN_PAYEE_ID,
  STORY_MELTDOWN_PERSONA_ID,
} from "../storyDemo";

interface Props {
  config: AppConfig;
}

const SCHEMES: PaymentRequest["scheme"][] = ["FPS", "BACS", "CHAPS", "SEPA", "SWIFT"];
const CURRENCIES: PaymentRequest["currency"][] = ["GBP", "EUR", "USD"];

// PSD2 SCA threshold (in minor units = pence). Anything over this on
// the mobile channel triggers a Strong Customer Authentication push
// notification before the payment is dispatched. Reflects the EBA RTS
// "low-value" exemption ceiling of EUR 30 (~ GBP 25 = 2500 pence).
const MOBILE_SCA_THRESHOLD_MINOR = 2500;

// Push-auth simulated wait time in ms. Short enough to demo without
// stalling the audience, long enough to be visible.
const SCA_PUSH_WAIT_MS = 1800;

// Sentinel value used by selectedPayeeId to represent "I'm sending to a
// new payee" (i.e. raw form mode with no saved-payee defaults).
const NEW_PAYEE_ID = "__new__";

// Upper bound for the "send multiple payments" demo helper. Sending more
// than one runs the identical per-payment path (Send payment ->
// payment.completed) in a sequential loop so each one is a distinct RUM
// session action + APM trace. Capped so a fat-fingered value can't fire
// thousands of requests at the gateway.
const MAX_BATCH = 100;

// Small gap between batch sends so each produces a cleanly separated
// trace and the progress counter can repaint between iterations.
const BATCH_SPACING_MS = 120;

interface SuccessSnapshot {
  payload: PaymentRequest;
  response: PaymentResponse;
  payeeName: string;
  payeeAccount: string | null;
  payeeSortCode: string | null;
  reference: string;
}

type Status =
  | { kind: "idle" }
  | { kind: "ok"; snapshot: SuccessSnapshot }
  | { kind: "batch"; total: number; ok: number; err: number; avgMs: number }
  | { kind: "error"; message: string };

// Build the initial editable form state for a saved-payee selection. The
// "new payee" branch reuses buildSamplePayment so the demo defaults
// (scheme=FPS, currency=GBP, debtor/creditor=GB) match the traffic
// generator's baseline payload.
function formFromPayee(
  payee: Payee | undefined,
  config: AppConfig,
): PaymentRequest {
  const base = buildSamplePayment({}, config);
  if (!payee) return base;
  return {
    ...base,
    scheme: payee.scheme,
    currency: payee.currency,
    creditor_country: payee.creditorCountry,
    amount_minor_units: payee.amountMinor,
  };
}

export default function SendMoney({ config }: Props) {
  const { persona } = usePersona();
  const account = accountFor(persona);
  const tierColour = TIER_COLOURS[persona.tier];
  const location = useLocation();

  // Saved payees are persona-scoped; re-derived when the user switches
  // personas via the header. useMemo keeps the array stable across re-
  // renders so the chips don't lose focus while typing in the amount.
  const payees = useMemo(() => payeesFor(persona.id), [persona.id]);

  const [selectedPayeeId, setSelectedPayeeId] = useState<string>(
    () => payees[0]?.id ?? NEW_PAYEE_ID,
  );
  const [form, setForm] = useState<PaymentRequest>(
    () => formFromPayee(payees[0], config),
  );
  // The amount is shown as a pounds-and-pence string in the input but
  // sent as integer minor units to the backend. Keep both in state so a
  // half-typed "12." doesn't snap back to "12.00" between keystrokes.
  const [amountInput, setAmountInput] = useState<string>(
    () => minorToPoundsString(payees[0]?.amountMinor ?? form.amount_minor_units),
  );
  const [reference, setReference] = useState<string>(payees[0]?.reference ?? "");
  const [advancedOpen, setAdvancedOpen] = useState<boolean>(false);
  const [submitting, setSubmitting] = useState(false);
  const [status, setStatus] = useState<Status>({ kind: "idle" });

  // "Send multiple" demo helper. Defaults to 1 so the normal single-send
  // flow (and its success-card animation) is completely unchanged. Any
  // value > 1 runs the batch path instead. batchProgress drives the
  // "Sending 3/10..." button label while a batch is in flight.
  const [quantity, setQuantity] = useState<number>(1);
  const [batchProgress, setBatchProgress] = useState<{ done: number; total: number } | null>(null);

  // PSD2 Strong Customer Authentication overlay state. Only ever shown
  // in the mobile channel and only for amounts above the low-value
  // exemption threshold. The overlay is purely client-side simulation
  // for the demo; it does NOT replace the backend's emit_sca_event()
  // record, which is the authoritative compliance audit trail.
  const [scaPrompt, setScaPrompt] = useState<{
    kind: "prompt" | "approving";
    amountGbp: string;
  } | null>(null);

  // Re-seed the form when the persona changes so the first payee chip
  // is preselected and the amount input reflects its default. We avoid
  // touching the form state when the user has typed into the new-payee
  // amount and *then* switched persona — but that's an extremely rare
  // edge case for a demo, and explicit selection is the safer default.
  useEffect(() => {
    const first = payees[0];
    if (first) {
      setSelectedPayeeId(first.id);
      setForm(formFromPayee(first, config));
      setAmountInput(minorToPoundsString(first.amountMinor));
      setReference(first.reference);
    } else {
      setSelectedPayeeId(NEW_PAYEE_ID);
      setForm(formFromPayee(undefined, config));
      setAmountInput(minorToPoundsString(formFromPayee(undefined, config).amount_minor_units));
      setReference("");
    }
    setStatus({ kind: "idle" });
  }, [payees, config]);

  // Allow the Home page to deep-link with ?intent=bill / ?intent=transfer /
  // ?intent=meltdown (canonical payment-meltdown story payee + FPS rail).
  useEffect(() => {
    const params = new URLSearchParams(location.search);
    const intent = params.get("intent");
    if (intent === "meltdown") {
      if (persona.id !== STORY_MELTDOWN_PERSONA_ID) {
        return;
      }
      const storyPayee = findPayee(STORY_MELTDOWN_PERSONA_ID, STORY_MELTDOWN_PAYEE_ID);
      if (storyPayee) {
        setSelectedPayeeId(storyPayee.id);
        setForm(formFromPayee(storyPayee, config));
        setAmountInput(minorToPoundsString(storyPayee.amountMinor));
        setReference(storyPayee.reference);
        setStatus({ kind: "idle" });
      }
      return;
    }
    if (intent === "transfer") {
      setSelectedPayeeId(NEW_PAYEE_ID);
      const fresh = formFromPayee(undefined, config);
      setForm(fresh);
      setAmountInput(minorToPoundsString(fresh.amount_minor_units));
      setReference("");
      setStatus({ kind: "idle" });
      return;
    }
    if (intent === "bill") {
      const billPayee = payees.find((p) => p.scheme === "BACS") ?? payees[0];
      if (billPayee) {
        setSelectedPayeeId(billPayee.id);
        setForm(formFromPayee(billPayee, config));
        setAmountInput(minorToPoundsString(billPayee.amountMinor));
        setReference(billPayee.reference);
        setStatus({ kind: "idle" });
      }
    }
  }, [location.search, payees, config, persona.id]);

  function update<K extends keyof PaymentRequest>(key: K, value: PaymentRequest[K]) {
    setForm((prev) => ({ ...prev, [key]: value }));
  }

  function selectPayee(id: string) {
    setStatus({ kind: "idle" });
    if (id === NEW_PAYEE_ID) {
      setSelectedPayeeId(NEW_PAYEE_ID);
      const fresh = formFromPayee(undefined, config);
      setForm(fresh);
      setAmountInput(minorToPoundsString(fresh.amount_minor_units));
      setReference("");
      // Operator picked the "new payee" branch - capture the intent
      // even though there's no concrete payee row, so the funnel
      // pivot in Tag Spotlight (saved-payee vs new-payee usage) still
      // gets the second arm. Keep the dimension shape stable with the
      // saved-payee branch by stamping placeholder values.
      recordPageAction("payee.selected", {
        "payee.id": NEW_PAYEE_ID,
        "payee.country": "",
        "payee.scheme": "",
        "payee.amount_minor": fresh.amount_minor_units,
      });
      return;
    }
    const payee = findPayee(persona.id, id);
    if (!payee) return;
    setSelectedPayeeId(id);
    setForm(formFromPayee(payee, config));
    setAmountInput(minorToPoundsString(payee.amountMinor));
    setReference(payee.reference);
    recordPageAction("payee.selected", {
      "payee.id": payee.id,
      "payee.country": payee.creditorCountry,
      "payee.scheme": payee.scheme,
      "payee.amount_minor": payee.amountMinor,
    });
  }

  function onAmountChange(raw: string) {
    setAmountInput(raw);
    const minor = parsePoundsToMinor(raw);
    if (!Number.isNaN(minor)) {
      update("amount_minor_units", minor);
    }
  }

  const selectedPayee = selectedPayeeId === NEW_PAYEE_ID
    ? undefined
    : findPayee(persona.id, selectedPayeeId);

  // Send exactly one payment with the full observability bookends. This
  // is the single source of truth shared by the single-send path and the
  // batch loop, so each payment - whether it's one click or one of fifty
  // - emits the identical "Send payment" -> network -> "payment.completed"
  // sequence and seeds Recent Payments history. Never throws: transport
  // and gateway errors are captured and returned as { ok: false }.
  async function sendOnePayment(
    payload: PaymentRequest,
  ): Promise<{ ok: boolean; response?: PaymentResponse; durationMs: number; message?: string }> {
    recordPageAction("Send payment", {
      "payment.id": payload.payment_id,
      "payment.scheme": payload.scheme,
      "payment.currency": payload.currency,
      "payment.amount_minor_units": payload.amount_minor_units,
      "customer.id": payload.customer_id,
      "customer.tier": payload.customer_tier,
    });
    const submitStartedAt = performance.now();
    try {
      const response = await submitPayment(config, payload);
      const clientDurationMs = Math.round(performance.now() - submitStartedAt);
      // A "partial" acceptance means the gateway absorbed a downstream
      // failure (e.g. sanctions-aml's RegionalDependencyError under the
      // madrid-payment-degradation scenario's error_rate) and still
      // returned 200. Surface it to the customer as a hard decline — a
      // real bank does not accept a payment that failed compliance
      // screening. The APM story is unchanged (the trace still shows the
      // absorbed 5xx as root cause); the SPA now shows the decline and
      // the DXA funnel drops the user before Payment Success.
      const failedServices = Array.isArray(response.downstream_results)
        ? (response.downstream_results as Array<{ ok?: boolean; service?: string }>)
            .filter((r) => r && r.ok === false)
            .map((r) => r.service ?? "downstream")
        : [];
      if (response.status === "partial" || failedServices.length > 0) {
        const message = failedServices.length
          ? `Payment declined: ${failedServices.join(", ")} could not process the payment`
          : "Payment declined during downstream processing";
        recordPageAction("payment.completed", {
          "payment.id": payload.payment_id,
          "payment.scheme": payload.scheme,
          "payment.currency": payload.currency,
          "payment.amount_minor_units": payload.amount_minor_units,
          "payment.outcome": "error",
          "error.kind": "downstream_declined",
          "error.message": message,
          "payment.server_status": String(response.status ?? ""),
          "client.duration_ms": clientDurationMs,
          "customer.tier": payload.customer_tier,
        });
        reportPaymentDegraded({
          reason: "error",
          durationMs: clientDurationMs,
          scheme: payload.scheme,
          country: payload.customer_country,
          location: payload.customer_location,
          tier: payload.customer_tier,
          message,
        });
        appendHistory(summariseResponse(payload, response, persona));
        return { ok: false, durationMs: clientDurationMs, message };
      }
      recordPageAction("payment.completed", {
        "payment.id": payload.payment_id,
        "payment.scheme": payload.scheme,
        "payment.currency": payload.currency,
        "payment.amount_minor_units": payload.amount_minor_units,
        "payment.outcome": "success",
        "payment.server_status": String(response.status ?? ""),
        "client.duration_ms": clientDurationMs,
        "customer.tier": payload.customer_tier,
      });
      // A successful-but-slow payment is the Madrid / ES sanctions-aml
      // degradation (slow HTTP 200, ~2.3s vs ~80ms baseline). Flag it to RUM so
      // the session is findable in Session Search even though the gateway
      // absorbed the downstream 500 and returned 200. APM trace is untouched.
      if (clientDurationMs >= DEGRADED_PAYMENT_CLIENT_MS) {
        reportPaymentDegraded({
          reason: "slow",
          durationMs: clientDurationMs,
          scheme: payload.scheme,
          country: payload.customer_country,
          location: payload.customer_location,
          tier: payload.customer_tier,
        });
      }
      appendHistory(summariseResponse(payload, response, persona));
      return { ok: true, response, durationMs: clientDurationMs };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const clientDurationMs = Math.round(performance.now() - submitStartedAt);
      const errKind = err instanceof TypeError ? "network" : "http_error";
      recordPageAction("payment.completed", {
        "payment.id": payload.payment_id,
        "payment.scheme": payload.scheme,
        "payment.currency": payload.currency,
        "payment.amount_minor_units": payload.amount_minor_units,
        "payment.outcome": "error",
        "error.kind": errKind,
        "error.message": message,
        "client.duration_ms": clientDurationMs,
        "customer.tier": payload.customer_tier,
      });
      // Hard failure path (network error / propagated 5xx) — also a first-class
      // RUM error so the session is flagged regardless of how the fault surfaces.
      reportPaymentDegraded({
        reason: "error",
        durationMs: clientDurationMs,
        scheme: payload.scheme,
        country: payload.customer_country,
        location: payload.customer_location,
        tier: payload.customer_tier,
        message,
      });
      return { ok: false, durationMs: clientDurationMs, message };
    }
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    setStatus({ kind: "idle" });

    // Final coercion. If the user typed something un-parseable into the
    // amount field, fall back to whatever's already in form (which we
    // last accepted as a valid number). The button is disabled while the
    // input is invalid so this is just defence-in-depth.
    const minor = parsePoundsToMinor(amountInput);
    const amount_minor_units = Number.isNaN(minor)
      ? form.amount_minor_units
      : minor;

    // Defence-in-depth: a programmatic submit (e.g. Enter key while the
    // submit button is hidden, browser autofill double-fire) can race
    // around the disabled-button guard and reach handleSubmit with
    // un-parseable / zero amount. Emit a `validation.failed` RUM event
    // and short-circuit so the gateway never sees the bad payload.
    if (Number.isNaN(minor) || amount_minor_units <= 0) {
      recordPageAction("validation.failed", {
        "field": "amount",
        "reason": Number.isNaN(minor) ? "unparseable" : "non_positive",
        "attempted.scheme": form.scheme,
        "attempted.amount.minor": Number.isNaN(minor) ? -1 : amount_minor_units,
      });
      setSubmitting(false);
      setStatus({
        kind: "error",
        message: "Enter a positive amount before sending.",
      });
      return;
    }

    // Always mint a fresh payment_id so each click produces a distinct
    // trace in Splunk APM. Customer fields come from the live persona
    // selection so a mid-session switch is reflected immediately.
    const payload: PaymentRequest = {
      ...form,
      amount_minor_units,
      payment_id: buildSamplePayment({}, config).payment_id,
      customer_id: persona.id,
      customer_tier: persona.tier,
      // Carry the persona's geography end-to-end when present. The UK
      // trio leaves persona.location undefined; the gateway tolerates the
      // missing fields and falls back to its existing GB defaults.
      ...(persona.location && {
        customer_location: persona.location.city,
        customer_country: persona.location.country,
        customer_region: persona.location.region,
        customer_lat: persona.location.lat,
        customer_lon: persona.location.lon,
      }),
    };

    // How many payments this submit fires. Clamped to [1, MAX_BATCH].
    // A value of 1 keeps the original single-send behaviour (success
    // card + SCA) completely unchanged.
    const qtyToSend = Math.max(1, Math.min(MAX_BATCH, Math.round(quantity) || 1));

    // PSD2 Strong Customer Authentication challenge for the mobile
    // channel. Two RUM page actions bracket the simulated approve-on-
    // phone flow so the session timeline shows a clear MFA -> payment
    // sequence; both events carry sca.method=push_notification so the
    // Splunk Observability Tag Spotlight pivot reads correctly. Only ever
    // shown for a single send - a batch is a volume/demo helper and would
    // otherwise stack N approve-on-phone overlays (the backend still
    // records its own emit_sca_event() regardless).
    const needsSca =
      qtyToSend === 1
      && config.channel === "mobile"
      && payload.amount_minor_units > MOBILE_SCA_THRESHOLD_MINOR;
    if (needsSca) {
      const amountGbp = (payload.amount_minor_units / 100).toFixed(2);
      recordPageAction("SCA challenge issued", {
        "sca.method": "push_notification",
        "sca.outcome": "challenged",
        "payment.id": payload.payment_id,
        "payment.amount_minor_units": payload.amount_minor_units,
        "channel": "mobile",
      });
      setScaPrompt({ kind: "prompt", amountGbp });
      try {
        await waitForScaApproval(setScaPrompt);
      } catch {
        recordPageAction("SCA challenge abandoned", {
          "sca.method": "push_notification",
          "sca.outcome": "abandoned",
          "payment.id": payload.payment_id,
          "channel": "mobile",
        });
        setScaPrompt(null);
        setSubmitting(false);
        setStatus({ kind: "error", message: "SCA approval cancelled" });
        return;
      }
      recordPageAction("SCA challenge approved", {
        "sca.method": "push_notification",
        "sca.outcome": "passed",
        "payment.id": payload.payment_id,
        "channel": "mobile",
      });
      setScaPrompt(null);
    }
    // Wall-clock + funnel-bottom emission now live in sendOnePayment so
    // the single-send and batch paths stay byte-identical per payment.
    // The "Send payment" page action, traceparent-carrying fetch, and
    // "payment.completed" event all happen inside that helper.
    try {
      if (qtyToSend === 1) {
        // Single send: identical outcome to before - SuccessCard on
        // success, inline error line on failure.
        const res = await sendOnePayment(payload);
        if (res.ok && res.response) {
          const snapshot: SuccessSnapshot = {
            payload,
            response: res.response,
            payeeName: selectedPayee?.name ?? "New payee",
            payeeAccount: selectedPayee?.accountNumber ?? null,
            payeeSortCode: selectedPayee?.sortCode ?? null,
            reference,
          };
          setStatus({ kind: "ok", snapshot });
        } else {
          setStatus({ kind: "error", message: res.message ?? "Payment failed" });
        }
        return;
      }

      // Batch send: run the identical per-payment path sequentially so
      // each one is a distinct RUM session action + APM trace. We
      // deliberately do NOT switch to the per-payment SuccessCard - the
      // form stays put and a compact summary is shown at the end - so the
      // snappy single-send visual experience is never disturbed.
      setBatchProgress({ done: 0, total: qtyToSend });
      let ok = 0;
      let err = 0;
      const durations: number[] = [];
      for (let i = 0; i < qtyToSend; i++) {
        const p: PaymentRequest = {
          ...payload,
          payment_id: buildSamplePayment({}, config).payment_id,
        };
        const res = await sendOnePayment(p);
        if (res.ok) ok++;
        else err++;
        durations.push(res.durationMs);
        setBatchProgress({ done: i + 1, total: qtyToSend });
        if (i < qtyToSend - 1) {
          await new Promise((resolve) => setTimeout(resolve, BATCH_SPACING_MS));
        }
      }
      const avgMs = durations.length
        ? Math.round(durations.reduce((a, b) => a + b, 0) / durations.length)
        : 0;
      setStatus({ kind: "batch", total: qtyToSend, ok, err, avgMs });
    } finally {
      setSubmitting(false);
      setBatchProgress(null);
    }
  }

  // After a successful send, "Send another" wipes the success card and
  // re-arms the form with the same payee so the audience can clack
  // through three payments in a row without the UI feeling sticky.
  function sendAnother() {
    setStatus({ kind: "idle" });
    const fresh = formFromPayee(selectedPayee, config);
    setForm(fresh);
    setAmountInput(minorToPoundsString(fresh.amount_minor_units));
  }

  const amountMinor = parsePoundsToMinor(amountInput);
  const amountValid = !Number.isNaN(amountMinor) && amountMinor > 0;
  const willTriggerSca = config.channel === "mobile"
    && amountValid
    && amountMinor > MOBILE_SCA_THRESHOLD_MINOR;

  if (status.kind === "ok") {
    return <SuccessCard
      snapshot={status.snapshot}
      realm={config.rumRealm}
      onSendAnother={sendAnother}
    />;
  }

  return (
    <section className="card send-card">
      <div className="card__header">
        <h2>Send money</h2>
        <span className="card__sub">
          From {account.productName} &middot; {formatSortCode(account.sortCode)} &middot;{" "}
          {maskAccount(account.accountNumber)}
        </span>
      </div>

      <div className="persona-banner">
        <span aria-hidden="true">{persona.avatar}</span>
        <span>
          Sending as <strong>{persona.name}</strong>
        </span>
        <span
          className="tier-chip"
          style={{ background: tierColour.bg, color: tierColour.fg }}
        >
          {tierLabel(persona.tier)}
        </span>
      </div>

      <form onSubmit={handleSubmit} className="send-form">
        <fieldset className="send-form__group">
          <legend>Who are you paying?</legend>
          <div className="payee-grid" role="radiogroup" aria-label="Saved payees">
            {payees.map((payee) => (
              <PayeeChip
                key={payee.id}
                payee={payee}
                selected={payee.id === selectedPayeeId}
                onSelect={() => selectPayee(payee.id)}
              />
            ))}
            <button
              type="button"
              className={`payee-chip payee-chip--new${selectedPayeeId === NEW_PAYEE_ID ? " payee-chip--selected" : ""}`}
              role="radio"
              aria-checked={selectedPayeeId === NEW_PAYEE_ID}
              onClick={() => selectPayee(NEW_PAYEE_ID)}
            >
              <span className="payee-chip__avatar" aria-hidden="true">+</span>
              <span className="payee-chip__body">
                <span className="payee-chip__name">New payee</span>
                <span className="payee-chip__sub">Send to anyone</span>
              </span>
            </button>
          </div>
        </fieldset>

        <fieldset className="send-form__group">
          <legend>How much &amp; what for?</legend>
          <div className="row">
            <div className="field">
              <label htmlFor="amount">Amount</label>
              <div className="amount-input">
                <span className="amount-input__symbol" aria-hidden="true">£</span>
                <input
                  id="amount"
                  type="text"
                  inputMode="decimal"
                  value={amountInput}
                  onChange={(e) => onAmountChange(e.target.value)}
                  aria-invalid={!amountValid}
                  aria-describedby="amount-help"
                  spellCheck={false}
                  autoComplete="off"
                />
              </div>
              <span id="amount-help" className="field__help">
                {willTriggerSca
                  ? "Above £25 on mobile — Strong Customer Authentication will be required."
                  : amountValid
                    ? "Faster Payments clear in seconds."
                    : "Enter a positive amount in pounds."}
              </span>
            </div>
            <div className="field">
              <label htmlFor="scheme">Payment scheme</label>
              <select
                id="scheme"
                value={form.scheme}
                onChange={(e) =>
                  update("scheme", e.target.value as PaymentRequest["scheme"])
                }
              >
                {SCHEMES.map((s) => (
                  <option key={s} value={s}>
                    {schemeLabel(s)}
                  </option>
                ))}
              </select>
            </div>
          </div>
          <div className="field">
            <label htmlFor="reference">Reference <span className="field__optional">(optional)</span></label>
            <input
              id="reference"
              type="text"
              maxLength={35}
              value={reference}
              onChange={(e) => setReference(e.target.value)}
              placeholder="What's this payment for?"
              autoComplete="off"
            />
            <span className="field__help">Up to 35 characters. The payee will see this on their statement.</span>
          </div>
        </fieldset>

        <details
          className="send-form__advanced"
          open={advancedOpen}
          onToggle={(e) => setAdvancedOpen((e.target as HTMLDetailsElement).open)}
        >
          <summary>Advanced options</summary>
          <div className="row">
            <div className="field">
              <label htmlFor="currency">Currency</label>
              <select
                id="currency"
                value={form.currency}
                onChange={(e) =>
                  update("currency", e.target.value as PaymentRequest["currency"])
                }
              >
                {CURRENCIES.map((c) => (
                  <option key={c} value={c}>
                    {c}
                  </option>
                ))}
              </select>
            </div>
            <div className="field">
              <label htmlFor="debtor-country">Debtor country</label>
              <input
                id="debtor-country"
                type="text"
                maxLength={2}
                value={form.debtor_country}
                onChange={(e) => update("debtor_country", e.target.value.toUpperCase())}
              />
            </div>
            <div className="field">
              <label htmlFor="creditor-country">Creditor country</label>
              <input
                id="creditor-country"
                type="text"
                maxLength={2}
                value={form.creditor_country}
                onChange={(e) => update("creditor_country", e.target.value.toUpperCase())}
              />
            </div>
          </div>
        </details>

        <div className="send-form__footer">
          <div className="send-form__summary">
            <span className="send-form__summary-label">Total</span>
            <span className="send-form__summary-amount">
              {amountValid ? formatMinor(amountMinor, form.currency) : "—"}
            </span>
          </div>
          <div className="field" style={{ flex: "0 0 auto", maxWidth: "6rem" }}>
            <label htmlFor="quantity">Payments</label>
            <input
              id="quantity"
              type="number"
              min={1}
              max={MAX_BATCH}
              step={1}
              value={quantity}
              onChange={(e) => {
                const n = parseInt(e.target.value, 10);
                setQuantity(Number.isNaN(n) ? 1 : Math.max(1, Math.min(MAX_BATCH, n)));
              }}
              disabled={submitting}
              title={`Send this many payments in one go (1\u2013${MAX_BATCH})`}
            />
          </div>
          <button
            type="submit"
            className="primary"
            disabled={submitting || !amountValid}
          >
            {submitting
              ? (batchProgress
                  ? `Sending ${batchProgress.done}/${batchProgress.total}\u2026`
                  : "Sending\u2026")
              : (quantity > 1 ? `Send ${quantity} payments` : "Review and send")}
          </button>
        </div>
      </form>

      {status.kind === "error" && (
        <div className="status-line error" role="alert">
          We couldn&apos;t complete that payment: {status.message}
        </div>
      )}

      {status.kind === "batch" && (
        <div className="status-line" role="status" style={{ marginTop: "0.75rem" }}>
          Sent {status.total} payment{status.total === 1 ? "" : "s"} &middot;{" "}
          {status.ok} succeeded{status.err > 0 ? `, ${status.err} failed` : ""} &middot;{" "}
          avg {status.avgMs} ms client time. Each one is its own RUM action &amp; APM trace.
        </div>
      )}

      {scaPrompt && (
        <div
          className="sca-overlay"
          role="dialog"
          aria-modal="true"
          aria-label="Strong Customer Authentication"
        >
          <div className="sca-card">
            <div className="sca-bell" aria-hidden="true">&#128276;</div>
            <h3>Approve on phone</h3>
            <p className="sca-amount">&pound;{scaPrompt.amountGbp}</p>
            <p className="sca-sub">
              PSD2 Strong Customer Authentication required for this payment.
              Please approve the push notification on your registered device.
            </p>
            {scaPrompt.kind === "approving"
              ? <p className="sca-status">Approved &#10003; &mdash; routing payment&hellip;</p>
              : <div className="sca-spinner" aria-hidden="true" />}
          </div>
        </div>
      )}
      <CoraChat />
    </section>
  );
}

// Friendly scheme label. The raw acronym is fine, but spelling out FPS
// at the demo lets the audience read it without us having to mention
// the UK rails explicitly in the talk-track.
function schemeLabel(s: PaymentRequest["scheme"]): string {
  switch (s) {
    case "FPS": return "FPS (Faster Payments)";
    case "BACS": return "BACS (Direct Debit)";
    case "CHAPS": return "CHAPS (Same-day high value)";
    case "SEPA": return "SEPA (EUR Single Euro Payments Area)";
    case "SWIFT": return "SWIFT (International)";
  }
}

function PayeeChip({
  payee,
  selected,
  onSelect,
}: {
  payee: Payee;
  selected: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      role="radio"
      aria-checked={selected}
      className={`payee-chip${selected ? " payee-chip--selected" : ""}`}
      onClick={onSelect}
    >
      <span className="payee-chip__avatar" aria-hidden="true">{payee.avatar}</span>
      <span className="payee-chip__body">
        <span className="payee-chip__name">{payee.name}</span>
        <span className="payee-chip__sub">{maskAccount(payee.accountNumber)}</span>
      </span>
    </button>
  );
}

interface SuccessCardProps {
  snapshot: SuccessSnapshot;
  realm: string | undefined;
  onSendAnother: () => void;
}

function SuccessCard({ snapshot, realm, onSendAnother }: SuccessCardProps) {
  const { payload, response, payeeName, payeeAccount, payeeSortCode, reference } = snapshot;
  const traceId = typeof response.trace_id === "string" ? response.trace_id : null;
  const kind = statusKindFor(response.status);
  return (
    <section className="card success-card">
      <div className={`success-card__hero success-card__hero--${kind}`}>
        <span className="success-card__icon" aria-hidden="true">
          {kind === "ok" ? "\u2713" : kind === "warn" ? "!" : kind === "error" ? "\u2715" : "\u2026"}
        </span>
        <div className="success-card__hero-text">
          <h2>
            {kind === "ok" ? "Payment sent" : kind === "warn" ? "Payment throttled" : kind === "error" ? "Payment declined" : "Payment submitted"}
          </h2>
          <StatusPill status={response.status} />
        </div>
      </div>

      <dl className="success-card__details">
        <div>
          <dt>Amount</dt>
          <dd className="success-card__amount">
            {formatMinor(payload.amount_minor_units, payload.currency)}
          </dd>
        </div>
        <div>
          <dt>To</dt>
          <dd>
            <span className="success-card__payee">{payeeName}</span>
            {(payeeSortCode || payeeAccount) && (
              <span className="success-card__payee-sub">
                {payeeSortCode && <span>Sort code {formatSortCode(payeeSortCode)}</span>}
                {payeeAccount && (
                  <>
                    {payeeSortCode && <span aria-hidden="true"> &middot; </span>}
                    <span>Account {maskAccount(payeeAccount)}</span>
                  </>
                )}
              </span>
            )}
          </dd>
        </div>
        <div>
          <dt>Scheme</dt>
          <dd>{schemeLabel(payload.scheme)}</dd>
        </div>
        {reference.trim() !== "" && (
          <div>
            <dt>Reference</dt>
            <dd>{reference}</dd>
          </div>
        )}
        <div>
          <dt>Payment ID</dt>
          <dd className="mono">{payload.payment_id}</dd>
        </div>
        <div>
          <dt>Trace</dt>
          <dd>
            <TraceLink traceId={traceId} realm={realm} short={false} />
          </dd>
        </div>
        {typeof response.duration_ms === "number" && (
          <div>
            <dt>Latency</dt>
            <dd>{response.duration_ms} ms</dd>
          </div>
        )}
      </dl>

      <div className="success-card__actions">
        <button type="button" className="primary" onClick={onSendAnother}>
          Send another
        </button>
      </div>
    </section>
  );
}

// Wait `SCA_PUSH_WAIT_MS` ms then flip the overlay to the "approving"
// state for a quick visual confirmation. Returns a Promise that
// resolves once the simulated approval completes.
type ScaState = { kind: "prompt" | "approving"; amountGbp: string } | null;
function waitForScaApproval(
  setScaPrompt: Dispatch<SetStateAction<ScaState>>,
): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(() => {
      setScaPrompt((prev) =>
        prev ? { kind: "approving", amountGbp: prev.amountGbp } : null,
      );
      // Brief settle so the audience sees the "approved" state.
      setTimeout(() => resolve(), 600);
    }, SCA_PUSH_WAIT_MS);
  });
}
