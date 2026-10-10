import { describe, it, expect, vi } from "vitest";
import { Interface } from "ethers";
import {
  firstVerdictDue,
  prizeDue,
  sunsetShareDue,
  heartbeat,
  hungJuryDue,
  judgeDue,
  pendingEligibility,
  pendingCount,
} from "../src/pending.ts";
import {
  readUnclaimed,
  gameTx,
  treasuryTx,
  simulateCall,
  simulationError,
} from "../src/chain.ts";
import { A, C, START_BLOCK } from "../src/config.ts";

const day = 20735,
  now = (day + 1) * 86400;
const state = {
  firstVerdictAnnounced: false,
  cursor: 1,
  previousRoundStatus: 3,
  treasuryBalance: 10n ** 16n,
  nextRunAt: now,
  timestamp: now,
  hungAt: now,
  sunsetDue: false,
  nextDay: day,
  nextRound: { status: 1 },
};
describe("pending eligibility at the read block", () => {
  it("first letter requires an unannounced settled round immediately behind the cursor", () => {
    expect(firstVerdictDue(false, 1, 3)).toBe(true);
    expect(firstVerdictDue(true, 1, 3)).toBe(false);
    expect(firstVerdictDue(false, 0, 3)).toBe(false);
    for (const status of [null, 0, 1, 2, 4])
      expect(firstVerdictDue(false, 1, status)).toBe(false);
  });
  it("claims require a positive credit; sunset shares also require an entry and no prior claim", () => {
    expect(prizeDue(1n)).toBe(true);
    expect(prizeDue(0n)).toBe(false);
    expect(sunsetShareDue(1n, true, false)).toBe(true);
    expect(sunsetShareDue(0n, true, false)).toBe(false);
    expect(sunsetShareDue(1n, false, false)).toBe(false);
    expect(sunsetShareDue(1n, true, true)).toBe(false);
  });
  it("heartbeat uses exact bigint min and integer floor, including dust and the boundary", () => {
    expect(heartbeat(0n, 0, now)).toEqual({
      amount: 0n,
      cooldown: 0,
      eligible: false,
    });
    expect(heartbeat(1n, now, now)).toEqual({
      amount: 1n,
      cooldown: 0,
      eligible: true,
    });
    expect(heartbeat(5n * 10n ** 15n, now, now)).toEqual({
      amount: 5n * 10n ** 15n,
      cooldown: 21600,
      eligible: true,
    });
    expect(heartbeat(10n ** 18n, now, now)).toEqual({
      amount: 10n ** 16n,
      cooldown: 43200,
      eligible: true,
    });
    expect(heartbeat(10n ** 16n - 1n, now, now).cooldown).toBe(43199);
    expect(heartbeat(1n, now + 1, now).eligible).toBe(false);
  });
  it("hung jury requires a nonzero deadline reached by the chain timestamp", () => {
    expect(hungJuryDue(0, now)).toBe(false);
    expect(hungJuryDue(now + 1, now)).toBe(false);
    expect(hungJuryDue(now, now)).toBe(true);
    expect(hungJuryDue(now - 1, now)).toBe(true);
  });
  it("Court link requires a closed open-status round, with no sunset or pending request", () => {
    expect(judgeDue(day, 1, now, false)).toBe(true);
    expect(judgeDue(day, 1, now - 1, false)).toBe(false);
    expect(judgeDue(0, 1, now, false)).toBe(false);
    expect(judgeDue(day, 1, now, true)).toBe(false);
    for (const status of [undefined, 0, 2, 3, 4])
      expect(judgeDue(day, status, now, false)).toBe(false);
  });
  it("sunset uses the contract boolean and suppresses the Court link until settled", () => {
    expect(pendingEligibility(state).sunset).toBe(false);
    expect(pendingEligibility({ ...state, sunsetDue: true })).toMatchObject({
      sunset: true,
      judge: false,
    });
  });
  it("counts actions, positive prize addresses and individual wallet sunset shares exactly once", () => {
    expect(
      pendingCount(
        state,
        [{ amount: 2n }, { amount: 0n }],
        [{ amount: 3n }, { amount: 4n }],
      ),
    ).toBe(7);
    expect(
      pendingCount(
        {
          ...state,
          firstVerdictAnnounced: true,
          treasuryBalance: 0n,
          hungAt: 0,
          nextDay: 0,
          nextRound: null,
        },
        [],
        [],
      ),
    ).toBe(0);
  });
});

const iface = new Interface(C.MeatbagGame.abi);
const winner = A.token,
  keeper = A.hook;
const bytes32 = "0x" + "1".repeat(64);
function event(name, args, blockNumber = START_BLOCK) {
  const log = iface.encodeEventLog(iface.getEvent(name), args);
  return { ...log, address: A.game, blockNumber, removed: false };
}
function provider(logs) {
  return {
    getBlock: vi.fn(async (number) => ({ hash: `hash-${number}` })),
    getLogs: vi.fn(async ({ fromBlock, toBlock }) =>
      logs.filter(
        (l) => l.blockNumber >= fromBlock && l.blockNumber <= toBlock,
      ),
    ),
    resolveName: vi.fn(async (name) => name),
    call: vi.fn(async (tx) => {
      const { args } = iface.parseTransaction(tx);
      return iface.encodeFunctionResult("claimable", [
        args[0].toLowerCase() === winner.toLowerCase() ? 7n : 0n,
      ]);
    }),
  };
}
describe("exhaustive prize reader", () => {
  it("derives and deduplicates winners/keepers, reads pinned balances and drops fully claimed credits", async () => {
    const p = provider([
      event("Verdict", [day, 0, winner, 7n, bytes32, 7]),
      event("Judging", [day, bytes32, keeper, 1n]),
      event("Judging", [day + 1, bytes32, winner, 1n]),
    ]);
    expect(await readUnclaimed(START_BLOCK + 20000, p)).toEqual([
      { address: winner.toLowerCase(), amount: 7n },
    ]);
    expect(p.getLogs.mock.calls[0][0].fromBlock).toBe(START_BLOCK);
    expect(p.getLogs.mock.calls.at(-1)[0].toBlock).toBe(START_BLOCK + 20000);
    expect(p.call).toHaveBeenCalledTimes(2);
    expect(
      p.call.mock.calls.every(([tx]) => tx.blockTag === START_BLOCK + 20000),
    ).toBe(true);
    await readUnclaimed(START_BLOCK + 20001, p);
    expect(p.getLogs.mock.calls.at(-1)[0].fromBlock).toBe(START_BLOCK + 20001);
    expect(p.call).toHaveBeenCalledTimes(4); // cached candidates, live balances
    p.getBlock.mockImplementation(async () => ({ hash: "reorg" }));
    await readUnclaimed(START_BLOCK + 20002, p);
    expect(p.getLogs.mock.calls.at(-3)[0].fromBlock).toBe(START_BLOCK);
  });
  it("subdivides provider-limited log ranges without truncating history", async () => {
    const p = provider([]);
    p.getLogs.mockImplementation(async ({ fromBlock, toBlock }) => {
      if (toBlock - fromBlock > 100) throw Error("Range too wide");
      return [];
    });
    expect(await readUnclaimed(START_BLOCK + 1000, p)).toEqual([]);
    expect(p.getLogs.mock.calls.length).toBeGreaterThan(10);
  });
  it("reports an unavailable range instead of an empty successful scan", async () => {
    const p = provider([]);
    p.getLogs.mockRejectedValue(Error("RPC unavailable"));
    await expect(readUnclaimed(START_BLOCK + 2, p)).rejects.toThrow(
      "RPC unavailable",
    );
  });
});
describe("exact calls and eth_call failures", () => {
  it("encodes every public action and the sunset day without sending wallet ETH", async () => {
    for (const name of [
      "announceFirstVerdict",
      "claim",
      "sunset",
      "declareHungJury",
      "judge",
    ]) {
      expect(iface.parseTransaction(gameTx(name)).name).toBe(name);
      expect(gameTx(name)).toMatchObject({ to: A.game, value: 0n });
    }
    expect(iface.parseTransaction(gameTx("claimSunset", [day])).args[0]).toBe(
      BigInt(day),
    );
    expect(
      new Interface(C.HeartbeatTreasury.abi).parseTransaction(treasuryTx())
        .name,
    ).toBe("fundNextRun");
    expect(treasuryTx()).toMatchObject({ to: A.treasury, value: 0n });
    const p = { call: vi.fn(async () => "0x") };
    await simulateCall(gameTx("claim"), winner, p, START_BLOCK);
    expect(p.call).toHaveBeenCalledWith({
      ...gameTx("claim"),
      from: winner,
      blockTag: START_BLOCK,
    });
  });
  it("decodes game and treasury custom errors, including arguments", async () => {
    const data = iface.encodeErrorResult("NothingToClaim");
    expect(simulationError({ data })).toBe("NothingToClaim()");
    const tooSoon = new Interface(C.HeartbeatTreasury.abi).encodeErrorResult(
      "TooSoon",
      [now],
    );
    expect(simulationError({ info: { error: { data: tooSoon } } })).toBe(
      `TooSoon(${now})`,
    );
    await expect(
      simulateCall(gameTx("claim"), winner, {
        call: async () => {
          throw { data };
        },
      }),
    ).rejects.toThrow("NothingToClaim()");
    expect(simulationError(Error("RPC unavailable"))).toBe("RPC unavailable");
  });
});
