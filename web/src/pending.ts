/** Eligibility uses the timestamp of a read block, never the visitor's clock. */
export const ROUND_OPEN = 1;
export const ROUND_PENDING = 2;
export const ROUND_SETTLED = 3;
export const HEARTBEAT_CAP = 10n ** 16n;
export const HEARTBEAT_INTERVAL = 43200n;

export function firstVerdictDue(
  announced: boolean,
  cursor: number,
  previousStatus: number | null,
) {
  return !announced && cursor > 0 && previousStatus === ROUND_SETTLED;
}
export function prizeDue(amount: bigint) {
  return amount > 0n;
}
export function sunsetShareDue(
  share: bigint,
  entered: boolean,
  claimed: boolean,
) {
  return share > 0n && entered && !claimed;
}
export function heartbeat(
  balance: bigint,
  nextRunAt: number,
  timestamp: number,
) {
  const amount = balance < HEARTBEAT_CAP ? balance : HEARTBEAT_CAP;
  const cooldown = Number((HEARTBEAT_INTERVAL * amount) / HEARTBEAT_CAP);
  return { amount, cooldown, eligible: balance > 0n && timestamp >= nextRunAt };
}
export function hungJuryDue(hungAt: number, timestamp: number) {
  return hungAt !== 0 && timestamp >= hungAt;
}
export function judgeDue(
  nextDay: number,
  status: number | undefined,
  timestamp: number,
  sunsetDue: boolean,
) {
  return (
    nextDay > 0 &&
    nextDay < Math.floor(timestamp / 86400) &&
    status === ROUND_OPEN &&
    !sunsetDue
  );
}
export type PendingState = {
  firstVerdictAnnounced: boolean;
  cursor: number;
  previousRoundStatus: number | null;
  treasuryBalance: bigint;
  nextRunAt: number;
  timestamp: number;
  hungAt: number;
  sunsetDue: boolean;
  nextDay: number;
  nextRound: { status: number } | null;
};
export function pendingEligibility(s: PendingState) {
  return {
    letter: firstVerdictDue(
      s.firstVerdictAnnounced,
      s.cursor,
      s.previousRoundStatus,
    ),
    heartbeat: heartbeat(s.treasuryBalance, s.nextRunAt, s.timestamp).eligible,
    sunset: s.sunsetDue,
    hung: hungJuryDue(s.hungAt, s.timestamp),
    judge: judgeDue(s.nextDay, s.nextRound?.status, s.timestamp, s.sunsetDue),
  };
}
/** One per public operation, unclaimed address, and connected-wallet sunset round. */
export function pendingCount(
  s: PendingState,
  prizes: { amount: bigint }[],
  sunsets: { amount: bigint }[],
) {
  return (
    Object.values(pendingEligibility(s)).filter(Boolean).length +
    prizes.filter((p) => prizeDue(p.amount)).length +
    sunsets.filter((p) => prizeDue(p.amount)).length
  );
}
