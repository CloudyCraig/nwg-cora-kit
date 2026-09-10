import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";

import App from "./App";
import { loadConfig } from "./config";
import { initNetworkContext, initRum } from "./rum";
import "./styles.css";

// RUM has to initialise before the React tree mounts so the SDK can
// observe the document-load and first-paint events for this navigation.
const config = loadConfig();
initRum(config);
// Sample the Network Information API once RUM is alive so every
// subsequent span carries network.effective_type / downlink_mbps /
// rtt_ms / save_data as session globals (and a one-shot
// `network.context` page action lands in the session timeline).
// Passing config also enables the audit beacon to /api/network/event
// so the ITSI correlation search can fire on connection flips.
initNetworkContext(config);

const rootEl = document.getElementById("root");
if (!rootEl) {
  throw new Error("missing #root element in index.html");
}

ReactDOM.createRoot(rootEl).render(
  <React.StrictMode>
    <BrowserRouter>
      <App config={config} />
    </BrowserRouter>
  </React.StrictMode>,
);
