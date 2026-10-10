import {
  AbiCoder,
  Contract,
  Interface,
  JsonRpcProvider,
  keccak256,
  ZeroAddress,
  type Provider,
  type TransactionRequest,
} from "ethers";
import {
  A,
  C,
  RPC,
  START_BLOCK,
  TO,
  POOL,
  POOL_TYPE,
  POOL_ID,
  ERC20_ABI,
  PERMIT_ABI,
  QUOTER_ABI,
  ROUTER_ABI,
} from "./config";
import type { Entry, Round } from "./domain";
import { errorText } from "./domain";
import { sunsetShareDue } from "./pending";
export const rpc = new JsonRpcProvider(RPC, 1, {
  staticNetwork: true,
  batchMaxCount: 20,
  cacheTimeout: 0,
});
rpc.pollingInterval = 12000;
export const game = (p: Provider = rpc) =>
  new Contract(A.game, C.MeatbagGame.abi, p);
export const hook = (p: Provider = rpc) =>
  new Contract(A.hook, C.MeatbagHook.abi, p);
export const treasury = (p: Provider = rpc) =>
  new Contract(A.treasury, C.HeartbeatTreasury.abi, p);
export async function verifyDeployment(p: Provider = rpc) {
  if (BigInt(await (p as JsonRpcProvider).send("eth_chainId", [])) !== 1n)
    throw Error("RPC is not Ethereum mainnet. Transactions are disabled.");
  await Promise.all(
    Object.values(C).map(async (c) => {
      const code = await p.getCode(c.address);
      if (code === "0x" || keccak256(code) !== c.runtimeHash)
        throw Error(
          "Deployed contract verification failed. Transactions are disabled.",
        );
    }),
  );
  const h = hook(p);
  const g = game(p);
  const herald = new Contract(A.herald, C.MeatbagHerald.abi, p);
  const fields = await Promise.all([
    h.token(),
    h.game(),
    h.herald(),
    h.treasury(),
    h.poolManager(),
    h.poolId(),
    g.IMD(),
    herald.TO(),
  ]);
  [
    A.token,
    A.game,
    A.herald,
    A.treasury,
    A.poolManager,
    POOL_ID,
    A.imd,
    TO,
  ].forEach((expected, i) => {
    if (fields[i].toLowerCase() !== expected.toLowerCase())
      throw Error(
        "Contract wiring differs from this launch. Transactions are disabled.",
      );
  });
  return true;
}
export type Snapshot = {
  block: number;
  timestamp: number;
  loadedAt: number;
  day: number;
  pot: bigint;
  slotPrice: bigint;
  entries: Entry[];
  judgePrice: bigint;
  nextDay: number;
  nextRound: Round | null;
  hungAt: number;
  streak: number;
  sunsetDue: boolean;
  roundCount: number;
  buyFee: number;
  volume: bigint;
  lettersCount: number;
  treasuryBalance: bigint;
  lastRunAt: number;
  nextRunAt: number;
  swarm: string;
  firstVerdictAnnounced: boolean;
  cursor: number;
  previousRoundStatus: number | null;
};
function toEntries(values: any[]): Entry[] {
  return values.map((e) => ({ author: e.author, text: e.text }));
}
export async function readRound(
  day: number,
  p: Provider = rpc,
  blockTag?: number,
): Promise<Round> {
  const g = game(p),
    opts = blockTag === undefined ? {} : { blockTag };
  const [r, e] = await Promise.all([g.round(day, opts), g.entries(day, opts)]);
  return {
    day,
    status: Number(r.status),
    count: Number(r.count),
    winner: Number(r.winner),
    panelSize: Number(r.panelSize),
    agreed: Number(r.agreed),
    requestedAt: Number(r.requestedAt),
    keeper: r.keeper,
    intakeRequestId: r.intakeRequestId,
    panelJobId: r.panelJobId,
    prize: r.prize,
    sunsetShare: r.sunsetShare,
    entries: toEntries(e),
  };
}
export async function readSnapshot(p: Provider = rpc): Promise<Snapshot> {
  const b = await p.getBlock("latest");
  if (!b) throw Error("Latest block unavailable. Retry the connection.");
  const g = game(p),
    h = hook(p),
    o = { blockTag: b.number },
    day = Math.floor(b.timestamp / 86400);
  const [
    pot,
    slotPrice,
    entries,
    judgePrice,
    nextDay,
    hungAt,
    streak,
    sunsetDue,
    roundCount,
    buyFee,
    volume,
    lettersCount,
    treasuryBalance,
    lastRunAt,
    nextRunAt,
    swarm,
    firstVerdictAnnounced,
    cursor,
  ] = await Promise.all([
    g.pot(o),
    g.nextSlotPrice(o),
    g.entries(day, o),
    g.judgePrice(o),
    g.nextRoundToJudge(o),
    g.hungJuryAt(o),
    g.unsettledStreak(o),
    g.sunsetDue(o),
    g.roundCount(o),
    h.buyFeeBps(o),
    h.volume(o),
    new Contract(A.herald, C.MeatbagHerald.abi, p).count(o),
    p.getBalance(A.treasury, b.number),
    treasury(p).lastRunAt(o),
    treasury(p).nextRunAt(o),
    treasury(p).SWARM(o),
    g.firstVerdictAnnounced(o),
    g.cursor(o),
  ]);
  return {
    block: b.number,
    timestamp: b.timestamp,
    loadedAt: Date.now(),
    day,
    pot,
    slotPrice,
    entries: toEntries(entries),
    judgePrice,
    nextDay: Number(nextDay),
    nextRound:
      nextDay === 0n ? null : await readRound(Number(nextDay), p, b.number),
    hungAt: Number(hungAt),
    streak: Number(streak),
    sunsetDue,
    roundCount: Number(roundCount),
    buyFee: Number(buyFee),
    volume,
    lettersCount: Number(lettersCount),
    treasuryBalance,
    lastRunAt: Number(lastRunAt),
    nextRunAt: Number(nextRunAt),
    swarm,
    firstVerdictAnnounced,
    cursor: Number(cursor),
    previousRoundStatus:
      cursor > 0n
        ? Number((await g.round(await g.roundDays(cursor - 1n, o), o)).status)
        : null,
  };
}
export async function readHistory(
  count: number,
  offset: number,
  p: Provider = rpc,
): Promise<Round[]> {
  const g = game(p);
  const indices = Array.from(
    { length: Math.max(0, Math.min(10, count - offset)) },
    (_, i) => count - offset - i - 1,
  );
  return Promise.all(
    indices.map(async (i) => readRound(Number(await g.roundDays(i)), p)),
  );
}
export type Letter = {
  text: string;
  block: number;
  hash: string;
  index: number;
};
const heraldInterface = new Interface(C.MeatbagHerald.abi);
export async function readLetters(
  toBlock: number,
  progress: (block: number) => void = () => {},
  p: Provider = rpc,
): Promise<Letter[]> {
  const topics = heraldInterface.encodeFilterTopics("Message", [TO]);
  const result: Letter[] = [];
  async function range(fromBlock: number, end: number): Promise<void> {
    try {
      const logs = await p.getLogs({
        address: A.herald,
        topics,
        fromBlock,
        toBlock: end,
      });
      for (const l of logs) {
        const decoded = heraldInterface.parseLog(l);
        if (decoded)
          result.push({
            text: decoded.args.text,
            block: l.blockNumber,
            hash: l.transactionHash,
            index: l.index,
          });
      }
      progress(end);
    } catch (e) {
      if (end - fromBlock < 100) throw e;
      const mid = Math.floor((fromBlock + end) / 2);
      await range(fromBlock, mid);
      await range(mid + 1, end);
    }
  }
  for (let start = START_BLOCK; start <= toBlock; start += 10000)
    await range(start, Math.min(start + 9999, toBlock));
  return result.sort((a, b) => b.block - a.block || b.index - a.index);
}
export type AccountState = {
  block: number;
  address: string;
  eth: bigint;
  meat: bigint;
  imd: bigint;
  judgeAllowance: bigint;
  claimable: bigint;
  hasEntered: boolean;
  sunsets: { day: number; amount: bigint }[];
};
export async function readAccount(
  address: string,
  s: Snapshot,
  p: Provider = rpc,
): Promise<AccountState> {
  const g = game(p),
    imd = new Contract(A.imd, ERC20_ABI, p),
    token = new Contract(A.token, ERC20_ABI, p),
    o = { blockTag: s.block };
  const [eth, meat, imdBalance, judgeAllowance, claimable, hasEntered] =
    await Promise.all([
      p.getBalance(address, s.block),
      token.balanceOf(address, o),
      imd.balanceOf(address, o),
      imd.allowance(address, A.game, o),
      g.claimable(address, o),
      g.hasEntered(s.day, address, o),
    ]);
  const sunsets: { day: number; amount: bigint }[] = [];
  // Exhaustive, bounded batches: old sunset claims never fall off a recent-history window.
  for (let i = 0; i < s.roundCount; i += 10) {
    await Promise.all(
      Array.from({ length: Math.min(10, s.roundCount - i) }, async (_, j) => {
        const day = Number(await g.roundDays(i + j, o));
        const r = await g.round(day, o);
        if (r.sunsetShare > 0n) {
          const [entered, claimed] = await Promise.all([
            g.hasEntered(day, address, o),
            g.sunsetClaimed(day, address, o),
          ]);
          if (sunsetShareDue(r.sunsetShare, entered, claimed))
            sunsets.push({ day, amount: r.sunsetShare });
        }
      }),
    );
  }
  return {
    block: s.block,
    address,
    eth,
    meat,
    imd: imdBalance,
    judgeAllowance,
    claimable,
    hasEntered,
    sunsets: sunsets.sort((a, b) => b.day - a.day),
  };
}
export const gameTx = (
  name: string,
  args: unknown[] = [],
  value = 0n,
): TransactionRequest => ({
  to: A.game,
  data: new Interface(C.MeatbagGame.abi).encodeFunctionData(name, args),
  value,
});
export const treasuryTx = (): TransactionRequest => ({
  to: A.treasury,
  data: new Interface(C.HeartbeatTreasury.abi).encodeFunctionData(
    "fundNextRun",
  ),
  value: 0n,
});

export type UnclaimedPrize = { address: string; amount: bigint };
const gameInterface = new Interface(C.MeatbagGame.abi);
const prizeCache = new WeakMap<
  Provider,
  { block: number; hash: string; addresses: string[] }
>();

/** Scan both credit-producing events from launch; no recent-history cutoff. */
export async function readUnclaimed(
  toBlock: number,
  p: Provider = rpc,
): Promise<UnclaimedPrize[]> {
  let cached = prizeCache.get(p);
  if (
    cached &&
    (cached.block > toBlock ||
      (await p.getBlock(cached.block))?.hash !== cached.hash)
  )
    cached = undefined;
  const candidates = new Set(cached?.addresses ?? []);
  const topics = [
    [
      gameInterface.getEvent("Verdict")!.topicHash,
      gameInterface.getEvent("Judging")!.topicHash,
    ],
  ];
  async function range(fromBlock: number, end: number): Promise<void> {
    let logs;
    try {
      logs = await p.getLogs({
        address: A.game,
        topics,
        fromBlock,
        toBlock: end,
      });
    } catch (e) {
      if (end - fromBlock < 100) throw e;
      const mid = Math.floor((fromBlock + end) / 2);
      await range(fromBlock, mid);
      await range(mid + 1, end);
      return;
    }
    for (const log of logs) {
      if (log.removed) continue;
      const event = gameInterface.parseLog(log);
      if (event)
        candidates.add(
          String(
            event.name === "Verdict" ? event.args.winner : event.args.keeper,
          ).toLowerCase(),
        );
    }
  }
  for (
    let start = cached ? cached.block + 1 : START_BLOCK;
    start <= toBlock;
    start += 10000
  )
    await range(start, Math.min(start + 9999, toBlock));
  const block = await p.getBlock(toBlock);
  if (!block?.hash)
    throw Error("Prize scan block unavailable. Refresh to retry.");
  prizeCache.set(p, {
    block: toBlock,
    hash: block.hash,
    addresses: [...candidates],
  });
  const result: UnclaimedPrize[] = [],
    addresses = [...candidates],
    g = game(p);
  for (let i = 0; i < addresses.length; i += 10) {
    const batch = await Promise.all(
      addresses.slice(i, i + 10).map(async (address) => ({
        address,
        amount: BigInt(await g.claimable(address, { blockTag: toBlock })),
      })),
    );
    result.push(...batch.filter((prize) => prize.amount > 0n));
  }
  return result.sort((a, b) => a.address.localeCompare(b.address));
}

/** eth_call often supplies raw custom-error data rather than a readable reason. */
export function simulationError(e: unknown): string {
  const err = e as {
    data?: unknown;
    error?: { data?: unknown };
    info?: { error?: { data?: unknown } };
  };
  const values = [err?.data, err?.error?.data, err?.info?.error?.data];
  for (const value of values) {
    const data =
      typeof value === "string"
        ? value
        : ((value as { data?: string; result?: string })?.data ??
          (value as { result?: string })?.result);
    if (!data || !/^0x[0-9a-f]+$/i.test(data)) continue;
    for (const abi of [
      C.MeatbagGame.abi,
      C.HeartbeatTreasury.abi,
      C.MeatbagHerald.abi,
    ]) {
      try {
        const decoded = new Interface(abi).parseError(data);
        if (decoded)
          return `${decoded.name}(${decoded.args.map(String).join(", ")})`;
      } catch {
        /* Try the next deployed ABI. */
      }
    }
  }
  return errorText(e);
}
export async function simulateCall(
  request: TransactionRequest,
  from: string,
  p: Provider = rpc,
  blockTag?: number,
): Promise<void> {
  try {
    await p.call({
      ...request,
      from,
      ...(blockTag === undefined ? {} : { blockTag }),
    });
  } catch (e) {
    throw Error(simulationError(e));
  }
}
export const approveTx = (
  asset: string,
  spender: string,
  amount: bigint,
): TransactionRequest => ({
  to: asset,
  data: new Interface(ERC20_ABI).encodeFunctionData("approve", [
    spender,
    amount,
  ]),
});
export function permitTx(amount: bigint, deadline: number): TransactionRequest {
  return {
    to: A.permit2,
    data: new Interface(PERMIT_ABI).encodeFunctionData("approve", [
      A.token,
      A.universalRouter,
      amount,
      deadline,
    ]),
  };
}
export type Quote = {
  buy: boolean;
  amount: bigint;
  out: bigint;
  min: bigint;
  slippage: number;
  createdAt: number;
  block: number;
  feeBps: number;
};
export async function quoteSwap(
  buy: boolean,
  amount: bigint,
  slippage: number,
  p: Provider = rpc,
): Promise<Quote> {
  if (![50, 100, 300].includes(slippage))
    throw Error("Select a supported slippage tolerance.");
  const block = await p.getBlockNumber();
  const [result, fee] = await Promise.all([
    new Contract(A.quoter, QUOTER_ABI, p).quoteExactInputSingle.staticCall(
      [POOL, buy, amount, "0x"],
      { blockTag: block },
    ),
    hook(p).buyFeeBps({ blockTag: block }),
  ]);
  const out: bigint = result[0];
  if (out <= 0n)
    throw Error("This amount has no output. Try a different amount.");
  const min = (out * BigInt(10000 - slippage)) / 10000n;
  if (min <= 0n)
    throw Error("The amount is too small to protect with slippage.");
  return {
    buy,
    amount,
    out,
    min,
    slippage,
    createdAt: Date.now(),
    block,
    feeBps: buy ? Number(fee) : 200,
  };
}
export function swapTx(q: Quote, deadline: number): TransactionRequest {
  const coder = AbiCoder.defaultAbiCoder();
  const params = [
    coder.encode(
      [
        `tuple(${POOL_TYPE} poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,bytes hookData)`,
      ],
      [[POOL, q.buy, q.amount, q.min, "0x"]],
    ),
    coder.encode(
      ["address", "uint256"],
      [q.buy ? ZeroAddress : A.token, q.amount],
    ),
    coder.encode(
      ["address", "uint256"],
      [q.buy ? A.token : ZeroAddress, q.min],
    ),
  ];
  const input = coder.encode(["bytes", "bytes[]"], ["0x060c0f", params]);
  return {
    to: A.universalRouter,
    data: new Interface(ROUTER_ABI).encodeFunctionData("execute", [
      "0x10",
      [input],
      deadline,
    ]),
    value: q.buy ? q.amount : 0n,
  };
}
export async function sellApproval(
  address: string,
  amount: bigint,
  p: Provider = rpc,
): Promise<"token" | "permit" | "ready"> {
  const [tokenAllowance, permit] = await Promise.all([
    new Contract(A.token, ERC20_ABI, p).allowance(address, A.permit2),
    new Contract(A.permit2, PERMIT_ABI, p).allowance(
      address,
      A.token,
      A.universalRouter,
    ),
  ]);
  if (tokenAllowance < amount) return "token";
  const block = await p.getBlock("latest");
  if (!block) throw Error("Latest block unavailable.");
  return permit.amount < amount ||
    Number(permit.expiration) < block.timestamp + 300
    ? "permit"
    : "ready";
}
