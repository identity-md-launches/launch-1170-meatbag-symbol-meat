import { formatEther, parseEther } from "ethers";
export const short = (s: string) =>
  s.length > 18 ? `${s.slice(0, 6)}…${s.slice(-4)}` : s;
export const bytes = (s: string) => new TextEncoder().encode(s).length;
export function entryError(text: string): string {
  if (!text.length) return "Write something about being human before entering.";
  if (bytes(text) > 200) return "Keep your entry to 200 bytes or fewer.";
  if (!/^[\x20-\x7E]+$/.test(text))
    return "Use printable ASCII: English letters, numbers, spaces and basic punctuation. Remove emoji, accented letters and line breaks.";
  return "";
}
export function amountValue(value: string): bigint {
  if (
    !/^(?:\d+\.?\d*|\.\d+)$/.test(value) ||
    (value.split(".")[1]?.length || 0) > 18
  )
    throw Error("Enter a positive amount with at most 18 decimal places.");
  const n = parseEther(value);
  if (n <= 0n || n >= 2n ** 128n)
    throw Error("Enter a positive amount smaller than the pool limit.");
  return n;
}
export function fmt(n: bigint | undefined, places = 5): string {
  if (n === undefined) return "—";
  const [a, b = ""] = formatEther(n).split(".");
  if (n > 0n && n < 10n ** BigInt(18 - places))
    return `<0.${"0".repeat(places - 1)}1`;
  return (
    a.replace(/\B(?=(\d{3})+(?!\d))/g, ",") +
    (b.slice(0, places).replace(/0+$/, "")
      ? "." + b.slice(0, places).replace(/0+$/, "")
      : "")
  );
}
export const dayLabel = (day: number) =>
  new Date(day * 86400000).toLocaleDateString("en-GB", {
    timeZone: "UTC",
    day: "numeric",
    month: "short",
    year: "numeric",
  });
export function countdown(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${String(Math.floor(s / 3600)).padStart(2, "0")}:${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}
export function errorText(e: unknown): string {
  const err = e as {
    code?: string | number;
    shortMessage?: string;
    message?: string;
    reason?: string;
    info?: { error?: { code?: number } };
  };
  if (
    err.code === "ACTION_REJECTED" ||
    err.code === 4001 ||
    err.info?.error?.code === 4001
  )
    return "Request cancelled in your wallet. You can try again.";
  const message =
    err.reason ||
    err.shortMessage ||
    err.message ||
    "The request could not complete.";
  if (/WrongPayment/.test(message))
    return "Another entry changed the slot price. Refresh the round and review the new price.";
  if (/AlreadyEntered/.test(message))
    return "This wallet has already entered today. Come back next UTC day.";
  if (/insufficient funds/i.test(message))
    return "Your wallet needs more funds for the amount and Ethereum gas.";
  return message.slice(0, 240) + (message.length > 240 ? "…" : "");
}
export type Entry = { author: string; text: string };
export type Round = {
  day: number;
  status: number;
  count: number;
  winner: number;
  panelSize: number;
  agreed: number;
  requestedAt: number;
  keeper: string;
  intakeRequestId: string;
  panelJobId: string;
  prize: bigint;
  sunsetShare: bigint;
  entries: Entry[];
};
