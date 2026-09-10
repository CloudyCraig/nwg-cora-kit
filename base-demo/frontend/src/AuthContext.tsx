// Demo-grade SPA auth context.
//
// What this is:
//   A client-side gate that hides the SPA behind a username + password
//   prompt. The plaintext password is NEVER shipped to the browser - the
//   build/deploy pipeline only injects a SHA-256 hash via /config.js, and
//   the login form hashes the user's input client-side and compares
//   (constant-time) to that hash.
//
// What this is NOT:
//   Real authentication. Anyone with devtools can disable the route guard,
//   read the hash, and brute-force a weak password offline. Replace with a
//   server-side session/JWT flow before this is public-internet long-lived.
//
// Session persistence:
//   We use sessionStorage (not localStorage) so closing the tab logs the
//   user out. The stored value is intentionally a non-secret marker
//   ({"username": "..."}) - no token, no hash. Re-auth on every fresh tab.

import {
  createContext,
  ReactNode,
  useCallback,
  useContext,
  useMemo,
  useState,
} from "react";

import { emitAuthBeacon } from "./api";
import { AppConfig } from "./config";
import { recordPageAction } from "./rum";

interface AuthState {
  enabled: boolean;
  isAuthed: boolean;
  username: string | null;
  login: (username: string, password: string) => Promise<boolean>;
  logout: () => void;
}

const AuthContext = createContext<AuthState | null>(null);

const SESSION_KEY = "nw-payments-auth";

async function sha256Hex(input: string): Promise<string> {
  // Prefer SubtleCrypto when available (HTTPS or localhost - "secure
  // contexts"). It's faster and uses native, side-channel-resistant crypto.
  // When the SPA is served over plain HTTP via the demo nginx proxy the
  // browser refuses access to crypto.subtle, in which case we fall back to
  // a pure-JS SHA-256. The fallback is verified at build time against the
  // FIPS 180-4 test vectors and the demo password's known digest.
  if (typeof crypto !== "undefined" && crypto.subtle && crypto.subtle.digest) {
    try {
      const enc = new TextEncoder().encode(input);
      const buf = await crypto.subtle.digest("SHA-256", enc);
      return Array.from(new Uint8Array(buf))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
    } catch {
      // Some browsers expose crypto.subtle but reject .digest in a
      // non-secure context with an InvalidAccessError. Fall through to
      // the pure-JS path so the demo still works over plain HTTP.
    }
  }
  return sha256HexFallback(input);
}

// Pure-JS SHA-256 (FIPS 180-4). Used only when the browser refuses access
// to crypto.subtle (typical when this SPA is served over plain HTTP).
// Verified against the standard test vectors:
//   ""                                         -> e3b0c442...
//   "abc"                                      -> ba7816bf...
//   "smartway"                                 -> 371e1a5e...
//   "The quick brown fox jumps over the lazy dog" -> d7a8fbb3...
//   56-byte padding-boundary fixture           -> 248d6a61...
function sha256HexFallback(input: string): string {
  const bytes: number[] = [];
  for (let i = 0; i < input.length; i++) {
    let c = input.charCodeAt(i);
    if (c < 0x80) {
      bytes.push(c);
    } else if (c < 0x800) {
      bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < input.length) {
      const c2 = input.charCodeAt(++i);
      const cp = 0x10000 + (((c & 0x3ff) << 10) | (c2 & 0x3ff));
      bytes.push(
        0xf0 | (cp >> 18),
        0x80 | ((cp >> 12) & 0x3f),
        0x80 | ((cp >> 6) & 0x3f),
        0x80 | (cp & 0x3f),
      );
    } else {
      bytes.push(
        0xe0 | (c >> 12),
        0x80 | ((c >> 6) & 0x3f),
        0x80 | (c & 0x3f),
      );
    }
  }
  const bitLen = bytes.length * 8;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) bytes.push(0);
  // 64-bit big-endian length. The high 32 bits are zero - input length
  // for a login password is far below 2^32 bits.
  for (let i = 0; i < 4; i++) bytes.push(0);
  bytes.push(
    (bitLen >>> 24) & 0xff,
    (bitLen >>> 16) & 0xff,
    (bitLen >>> 8) & 0xff,
    bitLen & 0xff,
  );

  const K = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ]);

  const H = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
    0x1f83d9ab, 0x5be0cd19,
  ]);

  const w = new Uint32Array(64);
  for (let i = 0; i < bytes.length; i += 64) {
    for (let t = 0; t < 16; t++) {
      w[t] =
        (bytes[i + t * 4] << 24) |
        (bytes[i + t * 4 + 1] << 16) |
        (bytes[i + t * 4 + 2] << 8) |
        bytes[i + t * 4 + 3];
    }
    for (let t = 16; t < 64; t++) {
      const s0 =
        ((w[t - 15] >>> 7) | (w[t - 15] << 25)) ^
        ((w[t - 15] >>> 18) | (w[t - 15] << 14)) ^
        (w[t - 15] >>> 3);
      const s1 =
        ((w[t - 2] >>> 17) | (w[t - 2] << 15)) ^
        ((w[t - 2] >>> 19) | (w[t - 2] << 13)) ^
        (w[t - 2] >>> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) >>> 0;
    }
    let a = H[0], b = H[1], c = H[2], d = H[3];
    let e = H[4], f = H[5], g = H[6], h = H[7];
    for (let t = 0; t < 64; t++) {
      const S1 =
        ((e >>> 6) | (e << 26)) ^
        ((e >>> 11) | (e << 21)) ^
        ((e >>> 25) | (e << 7));
      const ch = (e & f) ^ (~e & g);
      const temp1 = (h + S1 + ch + K[t] + w[t]) >>> 0;
      const S0 =
        ((a >>> 2) | (a << 30)) ^
        ((a >>> 13) | (a << 19)) ^
        ((a >>> 22) | (a << 10));
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (S0 + maj) >>> 0;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }
    H[0] = (H[0] + a) >>> 0;
    H[1] = (H[1] + b) >>> 0;
    H[2] = (H[2] + c) >>> 0;
    H[3] = (H[3] + d) >>> 0;
    H[4] = (H[4] + e) >>> 0;
    H[5] = (H[5] + f) >>> 0;
    H[6] = (H[6] + g) >>> 0;
    H[7] = (H[7] + h) >>> 0;
  }

  let hex = "";
  for (let i = 0; i < 8; i++) {
    hex += H[i].toString(16).padStart(8, "0");
  }
  return hex;
}

// Constant-time-ish string compare. JavaScript can't truly guarantee
// constant time (engine optimisations may short-circuit) but XOR-accumulate
// is the closest we can portably do, and removes the obvious early-exit
// length/byte timing oracles. For a SHA-256 hex hash both inputs are the
// same fixed 64-character length, so length-mismatch is a static fail.
function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

interface ProviderProps {
  children: ReactNode;
  config: AppConfig;
}

export function AuthProvider({ children, config }: ProviderProps) {
  const auth = config.auth;
  const [username, setUsername] = useState<string | null>(() => {
    if (!auth.enabled) {
      return null;
    }
    try {
      const raw = sessionStorage.getItem(SESSION_KEY);
      if (!raw) {
        return null;
      }
      const parsed = JSON.parse(raw) as { username?: unknown };
      return typeof parsed.username === "string" ? parsed.username : null;
    } catch {
      // sessionStorage may be disabled (e.g. private browsing on some
      // browsers) - fall back to "logged out" rather than crashing.
      return null;
    }
  });

  const login = useCallback(
    async (u: string, p: string): Promise<boolean> => {
      if (!auth.enabled) {
        return true;
      }
      // Generic failure (no enumeration of which field was wrong). We
      // intentionally do the username compare AFTER the hash so the timing
      // profile of "wrong username" matches "wrong password".
      const enteredHash = await sha256Hex(p);
      const expectedHash = (auth.passwordSha256 ?? "").toLowerCase();
      const userOk = u === auth.username;
      const passOk = constantTimeEquals(enteredHash, expectedHash);
      if (!userOk || !passOk) {
        recordPageAction("auth.login.failed", { "auth.username": u });
        // Fire-and-forget audit beacon to the gateway so the failed
        // login lands in the nwpay_audit Splunk index. Username is
        // server-coerced to <=64 chars; outcome is allow-listed.
        void emitAuthBeacon(config, { username: u, outcome: "failed" });
        return false;
      }
      try {
        sessionStorage.setItem(SESSION_KEY, JSON.stringify({ username: u }));
      } catch {
        // sessionStorage write failed (private mode); we still proceed in-
        // memory so the user gets a working session for this tab.
      }
      setUsername(u);
      recordPageAction("auth.login.success", { "auth.username": u });
      void emitAuthBeacon(config, { username: u, outcome: "success" });
      return true;
    },
    [auth.enabled, auth.username, auth.passwordSha256, config],
  );

  const logout = useCallback(() => {
    try {
      sessionStorage.removeItem(SESSION_KEY);
    } catch {
      // ignore
    }
    recordPageAction("auth.logout", {
      "auth.username": username ?? "",
    });
    if (username) {
      void emitAuthBeacon(config, { username, outcome: "logout" });
    }
    setUsername(null);
  }, [config, username]);

  const value = useMemo<AuthState>(
    () => ({
      enabled: auth.enabled,
      isAuthed: !auth.enabled || username !== null,
      username,
      login,
      logout,
    }),
    [auth.enabled, username, login, logout],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) {
    throw new Error("useAuth must be used inside an <AuthProvider>");
  }
  return ctx;
}
