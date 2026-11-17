// Foundry 1.8 probes anvil_nodeInfo to pick a "network family". Alchemy answers
// that with HTTP 400, which forge treats as fatal rather than as "not anvil".
// This shim answers that one method with a clean JSON-RPC "method not found"
// so forge falls back to EVM, and forwards everything else untouched.
import { createServer } from "node:http";
import { existsSync, readFileSync } from "node:fs";
// The upstream: RPC_URL_UPSTREAM, else RPC_URL in the repo's .env.
const ENV_FILE = new URL("../.env", import.meta.url);
const env = existsSync(ENV_FILE) ? readFileSync(ENV_FILE, "utf8") : "";
const UPSTREAM = (
  process.env.RPC_URL_UPSTREAM ?? env.match(/^RPC_URL=(.*)$/m)?.[1] ?? ""
).trim();
if (!UPSTREAM)
  throw new Error("set RPC_URL_UPSTREAM, or RPC_URL in the repo's .env");

createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", async () => {
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      parsed = null;
    }
    const one = Array.isArray(parsed) ? parsed[0] : parsed;
    if (one && String(one.method).startsWith("anvil_")) {
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(
        JSON.stringify({
          jsonrpc: "2.0",
          id: one.id ?? 0,
          error: { code: -32601, message: "Method not found" },
        }),
      );
    }
    try {
      const up = await fetch(UPSTREAM, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
      });
      const text = await up.text();
      res.writeHead(up.status, { "content-type": "application/json" });
      res.end(text);
    } catch (e) {
      res.writeHead(502, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          jsonrpc: "2.0",
          id: one?.id ?? 0,
          error: { code: -32000, message: String(e) },
        }),
      );
    }
  });
}).listen(8547, () => console.log("shim on 8547"));
