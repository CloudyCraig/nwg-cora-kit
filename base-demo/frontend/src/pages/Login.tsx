import { FormEvent, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";

import { useAuth } from "../AuthContext";
import NatWestLogo from "../components/NatWestLogo";

interface LocationState {
  from?: string;
}

export default function Login() {
  const auth = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const from = (location.state as LocationState | null)?.from ?? "/";

  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const ok = await auth.login(username, password);
      if (ok) {
        // Replace history so the back button doesn't bounce the user back
        // to /login after a successful sign-in.
        navigate(from, { replace: true });
      } else {
        // Generic message to avoid account enumeration. Username and
        // password are both validated against the same hash compare so
        // there's no observable behaviour difference between the two.
        setError("Invalid username or password.");
      }
    } catch (err) {
      // Visible failure mode. Without this catch, an unexpected throw
      // (e.g. crypto.subtle missing in a non-secure context, or storage
      // disabled) would surface as a button that "does nothing" because
      // the rejection only logs to the devtools console. We log the raw
      // error for debugging and show a user-friendly message.
      // eslint-disable-next-line no-console
      console.error("login failed unexpectedly:", err);
      setError("Sign in failed. Please refresh and try again.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="login-page">
      <form
        className="card login-card"
        onSubmit={handleSubmit}
        autoComplete="on"
      >
        <div className="login-brand">
          <NatWestLogo height={56} />
        </div>
        <h2>Sign in to Payments</h2>
        <p className="login-subtitle">Use your demo credentials to continue.</p>
        <div className="field">
          <label htmlFor="login-username">Username</label>
          <input
            id="login-username"
            name="username"
            type="text"
            autoComplete="username"
            inputMode="text"
            spellCheck={false}
            autoFocus
            required
            value={username}
            onChange={(e) => setUsername(e.target.value)}
          />
        </div>
        <div className="field">
          <label htmlFor="login-password">Password</label>
          <input
            id="login-password"
            name="password"
            type="password"
            autoComplete="current-password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        {error && (
          <div className="status-line error" role="alert">
            {error}
          </div>
        )}
        <button type="submit" className="primary" disabled={submitting}>
          {submitting ? "Signing in..." : "Sign in"}
        </button>
      </form>
    </div>
  );
}
