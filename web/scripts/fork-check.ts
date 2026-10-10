/** All writes go ONLY to an ephemeral local Anvil fork. No deployment or signing key. */
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import assert from "node:assert/strict";
import {
  AbiCoder,
  Contract,
  Interface,
  JsonRpcProvider,
  parseEther,
  toBeHex,
  zeroPadValue,
  keccak256,
  type TransactionRequest,
} from "ethers";
import { A, C, ERC20_ABI, RPC } from "../src/config";
import {
  approveTx,
  gameTx,
  game,
  hook,
  permitTx,
  quoteSwap,
  readSnapshot,
  sellApproval,
  swapTx,
  verifyDeployment,
  readLetters,
  readAccount,
  readUnclaimed,
  treasury,
  treasuryTx,
  simulateCall,
} from "../src/chain";
import { heartbeat, pendingEligibility } from "../src/pending";
const block = JSON.parse(
  readFileSync(
    new URL("../provenance/verification.json", import.meta.url),
    "utf8",
  ),
).block;
const port = 18547;
const anvil = spawn(
  "anvil",
  [
    "--fork-url",
    process.env.FORK_RPC_URL || RPC,
    "--fork-block-number",
    String(block),
    "--chain-id",
    "1",
    "--port",
    String(port),
    "--silent",
    "--no-storage-caching",
    "--fork-state-by-number",
    "--no-fork-node-info",
    "--compute-units-per-second",
    "100",
  ],
  { stdio: ["ignore", "pipe", "pipe"] },
);
let stderr = "";
anvil.stderr.on("data", (b) => (stderr += b.toString()));
const p = new JsonRpcProvider(`http://127.0.0.1:${port}`, 1, {
  staticNetwork: true,
  cacheTimeout: 0,
});
p.pollingInterval = 100;
const report: {
  block: number;
  results: { name: string; status: string; detail?: string }[];
  limitations: string[];
} = { block, results: [], limitations: [] };
function pass(name: string, detail?: string) {
  report.results.push({ name, status: "passed", detail });
  console.log("PASS", name, detail || "");
}
async function attempt(name: string, fn: () => Promise<void>) {
  try {
    await fn();
    pass(name);
  } catch (e) {
    report.results.push({ name, status: "failed", detail: String(e) });
    console.error("FAIL", name, String(e));
  }
}
const word = (v: bigint) => zeroPadValue(toBeHex(v), 32);
const slot = (type: string, key: string | number, base: number) =>
  keccak256(AbiCoder.defaultAbiCoder().encode([type, "uint256"], [key, base]));
async function setStorage(address: string, key: string, value: bigint) {
  await p.send("anvil_setStorageAt", [address, key, word(value)]);
}
try {
  for (let i = 0; i < 100; i++) {
    try {
      await p.send("eth_chainId", []);
      break;
    } catch {
      if (anvil.exitCode !== null) throw Error(stderr);
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  assert.equal(await p.send("eth_chainId", []), "0x1");
  const signer = await p.getSigner(0),
    actor = await signer.getAddress();
  const send = async (tx: TransactionRequest) => {
    await simulateCall(tx, actor, p);
    const receipt = await (
      await signer.sendTransaction({ ...tx, gasLimit: 4000000n })
    ).wait();
    assert.equal(receipt?.status, 1);
    return receipt!;
  };
  const reverted = async (tx: TransactionRequest) => {
    await assert.rejects(() => send(tx));
  };
  const g = game(p),
    h = hook(p),
    token = new Contract(A.token, ERC20_ABI, p);
  await attempt(
    "All five deployed runtime hashes and immutable wiring",
    async () => {
      await verifyDeployment(p);
    },
  );
  await attempt(
    "Full official Message feed from deployment block",
    async () => {
      const s = await readSnapshot(p);
      const l = await readLetters(s.block, () => {}, p);
      assert.equal(l.length, s.lettersCount);
      assert(l.some((x) => x.text.includes("71 chose MEATBAG")));
    },
  );
  await attempt(
    "Pending heartbeat: zero, dust, partial, capped balance and cooldown; exact eth_call and receipt",
    async () => {
      const saved = await p.send("evm_snapshot", []);
      try {
        const t = treasury(p);
        for (const balance of [
          0n,
          1n,
          parseEther("0.005"),
          parseEther("0.02"),
        ]) {
          await p.send("anvil_setBalance", [A.treasury, toBeHex(balance)]);
          await setStorage(A.treasury, word(1n), 0n);
          const s = await readSnapshot(p);
          const expected = heartbeat(balance, s.nextRunAt, s.timestamp);
          assert.equal(pendingEligibility(s).heartbeat, balance > 0n);
          if (!expected.eligible) {
            await assert.rejects(
              () => simulateCall(treasuryTx(), actor, p),
              /NothingToSend/,
            );
            continue;
          }
          const swarmBefore = await p.getBalance(s.swarm);
          const receipt = await send(treasuryTx());
          const mined = await p.getBlock(receipt.blockNumber);
          assert.equal(
            await p.getBalance(s.swarm),
            swarmBefore + expected.amount,
          );
          assert.equal(await t.lastRunAt(), BigInt(mined!.timestamp));
          assert.equal(
            await t.nextRunAt(),
            BigInt(mined!.timestamp + expected.cooldown),
          );
          if (expected.cooldown) {
            assert.equal(
              pendingEligibility(await readSnapshot(p)).heartbeat,
              false,
            );
            await assert.rejects(
              () => simulateCall(treasuryTx(), actor, p),
              /TooSoon/,
            );
          }
        }
        await p.send("evm_setNextBlockTimestamp", [
          Number(await t.nextRunAt()),
        ]);
        await p.send("evm_mine", []);
        assert.equal(pendingEligibility(await readSnapshot(p)).heartbeat, true);
        await send(treasuryTx());
      } finally {
        await p.send("evm_revert", [saved]);
      }
    },
  );
  report.limitations.push(
    "Heartbeat boundaries use local Anvil balances and cooldown storage only; all transfers execute the pinned deployed treasury bytecode.",
  );
  await attempt(
    "Buy MEAT: live v4 quote and frontend Universal Router calldata",
    async () => {
      const before = await token.balanceOf(actor);
      const q = await quoteSwap(true, parseEther("0.001"), 100, p);
      const b = await p.getBlock("latest");
      await send(swapTx(q, b!.timestamp + 300));
      assert((await token.balanceOf(actor)) - before >= q.min);
    },
  );
  await attempt("Approve MEAT to Permit2: exact input amount", async () => {
    const amount = (await token.balanceOf(actor)) / 2n;
    await send(approveTx(A.token, A.permit2, amount));
    assert.equal(await token.allowance(actor, A.permit2), amount);
    assert.equal(await sellApproval(actor, amount, p), "permit");
  });
  await attempt(
    "Authorize Universal Router in Permit2: exact amount and expiry",
    async () => {
      const amount = (await token.balanceOf(actor)) / 2n;
      const b = await p.getBlock("latest");
      await send(permitTx(amount, b!.timestamp + 1200));
      assert.equal(await sellApproval(actor, amount, p), "ready");
    },
  );
  await attempt(
    "Sell MEAT: live v4 quote and frontend Universal Router calldata",
    async () => {
      const amount = (await token.balanceOf(actor)) / 2n;
      const q = await quoteSwap(false, amount, 100, p);
      const before = await token.balanceOf(actor);
      const b = await p.getBlock("latest");
      const r = await send(swapTx(q, b!.timestamp + 300));
      assert.equal(before - (await token.balanceOf(actor)), amount);
      const fees = r.logs
        .filter((l) => l.address.toLowerCase() === A.hook.toLowerCase())
        .map((l) => {
          try {
            return new Interface(C.MeatbagHook.abi).parseLog(l);
          } catch {
            return null;
          }
        });
      assert(fees.some((f) => f?.name === "FeeTaken" && !f.args.buy));
    },
  );
  await attempt("Swap minimum-output and deadline guards", async () => {
    const q = await quoteSwap(true, parseEther("0.001"), 100, p);
    const b = await p.getBlock("latest");
    await reverted(swapTx({ ...q, min: q.out * 100n }, b!.timestamp + 300));
    await reverted(swapTx(q, b!.timestamp - 1));
  });
  await attempt(
    "enter(): printable ASCII and exact current slot price",
    async () => {
      const price = await g.nextSlotPrice();
      await send(
        gameTx(
          "enter",
          ["I still check the fridge twice, as if it had a second opinion."],
          price,
        ),
      );
      assert.equal(await g.hasEntered(await g.today(), actor), true);
    },
  );
  await attempt(
    "Entry guards: duplicate wallet, emoji and incorrect payment",
    async () => {
      const price = await g.nextSlotPrice();
      await reverted(gameTx("enter", ["Again."], price));
      await reverted(gameTx("enter", ["🧠"], price));
      await reverted(gameTx("enter", ["Wrong payment."], 0n));
    },
  );
  await attempt(
    "Pending first-verdict letter: eligibility, eth_call, herald event and cleared action",
    async () => {
      const saved = await p.send("evm_snapshot", []);
      try {
        const d = Number(await g.today());
        const key = slot("uint256", d, 12);
        const packed = BigInt(await p.getStorage(A.game, key));
        await setStorage(A.game, key, (packed & ~255n) | 3n);
        await setStorage(A.game, word(9n), await g.roundCount());
        await setStorage(A.game, word(11n), 0n);
        const before = await readSnapshot(p);
        assert.equal(pendingEligibility(before).letter, true);
        await send(gameTx("announceFirstVerdict"));
        const after = await readSnapshot(p);
        assert.equal(after.firstVerdictAnnounced, true);
        assert.equal(after.lettersCount, before.lettersCount + 1);
        assert.equal(pendingEligibility(after).letter, false);
      } finally {
        await p.send("evm_revert", [saved]);
      }
    },
  );
  report.limitations.push(
    "The first-verdict callback state is a local settled-round/cursor/announcement fixture; no oracle signature is fabricated and the original herald call executes on forked deployed code.",
  );
  // IMD balance fixture only. Locate the real balance mapping by reversible storage probes.
  const imd = new Contract(A.imd, ERC20_ABI, p);
  let imdFunded = false;
  for (let base = 0; base < 50; base++) {
    const key = slot("address", actor, base);
    const old = await p.getStorage(A.imd, key);
    await setStorage(A.imd, key, parseEther("10"));
    if ((await imd.balanceOf(actor)) === parseEther("10")) {
      imdFunded = true;
      break;
    }
    await p.send("anvil_setStorageAt", [A.imd, key, old]);
  }
  assert(imdFunded, "Could not create IMD fixture");
  report.limitations.push(
    "IMD balance for the local Anvil account is supplied through a test-only storage fixture. Production token supply and state are unchanged.",
  );
  await attempt("Approve IMD to game: exact live judgePrice()", async () => {
    const price = await g.judgePrice();
    await send(approveTx(A.imd, A.game, price));
    assert.equal(await imd.allowance(actor, A.game), price);
  });
  const day = Number(await g.today());
  await p.send("evm_setNextBlockTimestamp", [(day + 1) * 86400 + 10]);
  await p.send("evm_mine", []);
  let judged = false;
  await attempt(
    "judge(): actual live Intake request and 3% caller reward",
    async () => {
      const pot = await g.pot();
      const before = await g.claimable(actor);
      assert.equal(pendingEligibility(await readSnapshot(p)).judge, true);
      await send(gameTx("judge"));
      assert.equal((await g.claimable(actor)) - before, (pot * 3n) / 100n);
      assert.equal(Number((await g.round(day)).status), 2);
      judged = true;
    },
  );
  await attempt(
    "claim(): judge reward paid; double claim rejected",
    async () => {
      assert(judged, "Judge did not succeed");
      const amount = await g.claimable(actor);
      assert(amount > 0n);
      const prizes = await readUnclaimed(await p.getBlockNumber(), p);
      assert.equal(
        prizes.find((prize) => prize.address === actor.toLowerCase())?.amount,
        amount,
      );
      await send(gameTx("claim"));
      assert.equal(await g.claimable(actor), 0n);
      assert(
        !(await readUnclaimed(await p.getBlockNumber(), p)).some(
          (prize) => prize.address === actor.toLowerCase(),
        ),
      );
      await reverted(gameTx("claim"));
    },
  );
  // A real callback signature is not available. Create a winner-credit fixture on the real game.
  await attempt(
    "claim(): winner-credit fixture paid by deployed game",
    async () => {
      const amount = parseEther("0.0001");
      const total = await g.totalClaimable();
      await p.send("anvil_setBalance", [
        A.game,
        toBeHex((await p.getBalance(A.game)) + amount),
      ]);
      await setStorage(A.game, slot("address", actor, 7), amount);
      await setStorage(A.game, word(6n), total + amount);
      await send(gameTx("claim"));
      assert.equal(await g.claimable(actor), 0n);
      assert.equal(await g.totalClaimable(), total);
    },
  );
  report.limitations.push(
    "The winner claim is tested with a local claimable/totalClaimable storage fixture; no live oracle signing key or real offchain verdict is requested.",
  );
  await attempt(
    "declareHungJury(): early rejection, timeout transition and carryover",
    async () => {
      await reverted(gameTx("declareHungJury"));
      const at = Number(await g.hungJuryAt());
      await p.send("evm_setNextBlockTimestamp", [at + 1]);
      await p.send("evm_mine", []);
      const pot = await g.pot();
      assert.equal(pendingEligibility(await readSnapshot(p)).hung, true);
      await send(gameTx("declareHungJury"));
      assert.equal(Number((await g.round(day)).status), 4);
      assert.equal(await g.pot(), pot);
    },
  );
  const days = [day];
  // Make seven real entered rounds, with six timeouts through the public method.
  for (let i = 1; i < 7; i++) {
    const d = Number(await g.today());
    days.push(d);
    await send(
      gameTx("enter", [`Fork-only human entry ${i}.`], await g.nextSlotPrice()),
    );
    const at = Number(await g.hungJuryAt());
    await p.send("evm_setNextBlockTimestamp", [at + 1]);
    await p.send("evm_mine", []);
    if (i < 6) await send(gameTx("declareHungJury"));
  }
  await attempt("sunset(): no due sunset rejected", async () => {
    await reverted(gameTx("sunset"));
  });
  // Model the exact deferred-sunset state left by the seventh weak-panel callback.
  const last = days[6];
  const roundKey = slot("uint256", last, 12);
  const packed = BigInt(await p.getStorage(A.game, roundKey));
  await setStorage(A.game, roundKey, (packed & ~255n) | 4n);
  await setStorage(A.game, word(9n), (await g.cursor()) + 1n);
  await setStorage(A.game, word(10n), 7n);
  report.limitations.push(
    "sunset() uses a local fixture for the seventh weak-panel callback (round status, cursor, streak), because the live oracle signature is unavailable. Earlier entries and hung transitions run on the deployed game.",
  );
  await attempt(
    "sunset(): seven-round pot split creates equal shares",
    async () => {
      assert.equal(await g.sunsetDue(), true);
      assert.equal(pendingEligibility(await readSnapshot(p)).sunset, true);
      const pot = await g.pot();
      await send(gameTx("sunset"));
      assert.equal(await g.sunsetDue(), false);
      for (const d of days)
        assert.equal((await g.round(d)).sunsetShare, pot / 7n);
    },
  );
  await attempt(
    "claimSunset(): eligible entrant paid; double claim rejected",
    async () => {
      const before = await g.totalClaimable();
      const share = (await g.round(day)).sunsetShare;
      assert(share > 0n);
      assert(
        (await readAccount(actor, await readSnapshot(p), p)).sunsets.some(
          (share) => share.day === day,
        ),
      );
      await send(gameTx("claimSunset", [day]));
      assert.equal(await g.sunsetClaimed(day, actor), true);
      assert.equal(await g.totalClaimable(), before - share);
      await reverted(gameTx("claimSunset", [day]));
    },
  );
  await attempt(
    "Claim reader discovers older unclaimed sunset rounds",
    async () => {
      const state = await readSnapshot(p);
      const a = await readAccount(actor, state, p);
      assert.equal(a.sunsets.length, 6);
      assert(!a.sunsets.some((x) => x.day === day));
    },
  );
  console.log(JSON.stringify(report, null, 2));
  writeFileSync(
    process.argv[2] || "/tmp/meatbag-fork-results.json",
    JSON.stringify(report, null, 2) + "\n",
  );
  if (report.results.some((r) => r.status === "failed")) process.exitCode = 1;
} finally {
  p.destroy();
  anvil.kill("SIGTERM");
}
