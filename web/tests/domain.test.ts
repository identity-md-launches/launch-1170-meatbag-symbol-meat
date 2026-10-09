import test from "node:test";
import assert from "node:assert/strict";
import { entryError, bytes, amountValue, countdown, fmt } from "../src/domain";
import { panelRequestUrl, ORIGIN_REQUEST, oracleUrl } from "../src/config";
import { sendWalletTransaction, type Connection } from "../src/wallet";
test("ASCII boundary is bytes, not JavaScript string length", () => {
  assert.equal(entryError("a".repeat(200)), "");
  assert.match(entryError("a".repeat(201)), /200 bytes/);
  for (const s of ["🧠", "café", "a\nb", "a\tb", "a\u007fb", "“Hello”"])
    assert.match(entryError(s), /ASCII/);
  assert.match(entryError(""), /Write something/);
  assert.equal(bytes("🧠"), 4);
  assert.equal(entryError("I say 'ow'. 100% human!"), "");
});
test("amount parser rejects exponent, signs, commas, excess precision and zero", () => {
  for (const s of [
    "0",
    "-1",
    "1e3",
    "1,000",
    "Infinity",
    "0x01",
    "",
    " 1",
    "0.0000000000000000001",
  ])
    assert.throws(() => amountValue(s));
  assert.equal(amountValue(".001"), 1000000000000000n);
  assert.equal(amountValue("1.000000000000000001"), 1000000000000000001n);
});
test("countdown and formatting preserve boundaries and tiny nonzero amounts", () => {
  assert.equal(countdown(86400), "24:00:00");
  assert.equal(countdown(-1), "00:00:00");
  assert.equal(countdown(3661), "01:01:01");
  assert.equal(fmt(1n), "<0.00001");
  assert.equal(fmt(0n), "0");
});
test("panel UUID decoding produces the verified oracle-list endpoint", () => {
  const h =
    "0x6aedb1098fd946a9b66d0e50cf746b3a00000000000000000000000000000000";
  assert.equal(
    panelRequestUrl(h),
    "https://api.imd.fun/oracle/requests?jobId=6aedb109-8fd9-46a9-b66d-0e50cf746b3a",
  );
  assert.equal(panelRequestUrl("0x" + "0".repeat(64)), null);
  assert.equal(panelRequestUrl("0x123"), null);
  assert(oracleUrl(ORIGIN_REQUEST).endsWith(ORIGIN_REQUEST));
});
test("wallet send rechecks mainnet and the selected account before estimating or sending", async () => {
  let touched = false;
  const c = {
    account: "0x123",
    wallet: {
      provider: {
        request: async ({ method }: { method: string }) =>
          method === "eth_chainId" ? "0xa" : ["0x123"],
      },
    },
    signer: {
      estimateGas: async () => {
        touched = true;
        return 1n;
      },
    },
  } as unknown as Connection;
  await assert.rejects(() => sendWalletTransaction(c, {}), /Ethereum mainnet/);
  assert.equal(touched, false);
  c.wallet.provider.request = async ({ method }) =>
    method === "eth_chainId" ? "0x1" : ["0x456"];
  await assert.rejects(() => sendWalletTransaction(c, {}), /account changed/);
  assert.equal(touched, false);
});
