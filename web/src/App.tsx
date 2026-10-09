import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type FormEvent,
  type ReactNode,
} from "react";
import { formatEther, type TransactionRequest } from "ethers";
import {
  A,
  C,
  EXPLORER,
  ORIGIN_REQUEST,
  POOL_ID,
  START_BLOCK,
  TO,
  oracleUrl,
  panelRequestUrl,
} from "./config";
import {
  approveTx,
  gameTx,
  permitTx,
  quoteSwap,
  readAccount,
  readHistory,
  readLetters,
  readSnapshot,
  rpc,
  sellApproval,
  swapTx,
  verifyDeployment,
  game,
  type AccountState,
  type Letter,
  type Quote,
  type Snapshot,
} from "./chain";
import {
  amountValue,
  bytes,
  countdown,
  dayLabel,
  entryError,
  errorText,
  fmt,
  short,
  type Round,
} from "./domain";
import { sendWalletTransaction, useWallet } from "./wallet";

type Page = "today" | "court" | "trade" | "letters" | "claims" | "story";
const PAGES: Record<Page, string> = {
  today: "The daily test",
  court: "The jury",
  trade: "Trade MEAT",
  letters: "The letters",
  claims: "Claims",
  story: "Our origin",
};
type Review = {
  title: string;
  description: string;
  details: [string, string][];
  build: () => Promise<TransactionRequest> | TransactionRequest;
  onDone?: () => void;
};
function External({
  href,
  children,
  ...props
}: {
  href: string;
  children: ReactNode;
  className?: string;
  title?: string;
}) {
  return (
    <a href={href} target="_blank" rel="noopener noreferrer" {...props}>
      {children}
      <span aria-hidden="true"> ↗</span>
      <span className="sr-only"> (opens in a new tab)</span>
    </a>
  );
}
function Address({ address }: { address: string }) {
  return (
    <External href={`${EXPLORER}/address/${address}`} title={address}>
      <span className="mono">{short(address)}</span>
    </External>
  );
}
function Modal({
  title,
  children,
  onClose,
}: {
  title: string;
  children: ReactNode;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current!;
    const previous = document.activeElement as HTMLElement | null;
    d.showModal();
    return () => {
      d.close();
      previous?.focus();
    };
  }, []);
  return (
    <dialog
      ref={ref}
      aria-labelledby="dialog-title"
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onClose={onClose}
    >
      <div className="dialog-head">
        <h2 id="dialog-title">{title}</h2>
        <button
          className="icon-button"
          aria-label="Close dialog"
          onClick={onClose}
        >
          ×
        </button>
      </div>
      {children}
    </dialog>
  );
}
function SectionTitle({
  eyebrow,
  title,
  children,
}: {
  eyebrow: string;
  title: string;
  children?: ReactNode;
}) {
  return (
    <header className="section-title">
      <p className="eyebrow">{eyebrow}</p>
      <h1>{title}</h1>
      {children && <p className="lede">{children}</p>}
    </header>
  );
}
function Empty({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="empty">
      <span className="empty-mark" aria-hidden="true">
        [ … ]
      </span>
      <h3>{title}</h3>
      <p>{children}</p>
    </div>
  );
}
function Fact({
  label,
  value,
  note,
}: {
  label: string;
  value: ReactNode;
  note?: string;
}) {
  return (
    <div className="fact">
      <span className="eyebrow">{label}</span>
      <strong>{value}</strong>
      {note && <small>{note}</small>}
    </div>
  );
}
export function App() {
  const wallet = useWallet();
  const [page, setPage] = useState<Page>(() => {
    const p = location.hash.slice(1);
    return p in PAGES ? (p as Page) : "today";
  });
  const [s, setS] = useState<Snapshot>(),
    [account, setAccount] = useState<AccountState>(),
    [verified, setVerified] = useState(false),
    [loading, setLoading] = useState(true),
    [loadError, setLoadError] = useState(""),
    [accountError, setAccountError] = useState("");
  const [now, setNow] = useState(Date.now()),
    [walletOpen, setWalletOpen] = useState(false),
    [walletError, setWalletError] = useState(""),
    [connecting, setConnecting] = useState(false),
    [review, setReview] = useState<Review | null>(null),
    [busy, setBusy] = useState(false),
    [txError, setTxError] = useState(""),
    [notice, setNotice] = useState(""),
    [txHash, setTxHash] = useState("");
  const lock = useRef(false),
    verifiedRef = useRef(false),
    main = useRef<HTMLElement>(null);
  const refresh = useCallback(async () => {
    if (lock.current) return;
    lock.current = true;
    setLoading(true);
    try {
      if (!verifiedRef.current) {
        await verifyDeployment();
        verifiedRef.current = true;
        setVerified(true);
      }
      setS(await readSnapshot());
      setLoadError("");
    } catch (e) {
      setLoadError(errorText(e));
    } finally {
      lock.current = false;
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    void refresh();
    const i = setInterval(() => void refresh(), 30000);
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => {
      clearInterval(i);
      clearInterval(t);
    };
  }, [refresh]);
  useEffect(() => {
    const change = () => {
      const p = location.hash.slice(1);
      setPage(p in PAGES ? (p as Page) : "today");
      main.current?.focus();
      window.scrollTo({ top: 0 });
    };
    window.addEventListener("hashchange", change);
    return () => window.removeEventListener("hashchange", change);
  }, []);
  useEffect(() => {
    setAccount(undefined);
    setAccountError("");
    setReview(null);
  }, [wallet.connection?.account]);
  useEffect(() => {
    let alive = true;
    if (wallet.connection && s) {
      readAccount(wallet.connection.account, s)
        .then((a) => {
          if (alive) {
            setAccount(a);
            setAccountError("");
          }
        })
        .catch((e) => {
          if (alive) {
            setAccount(undefined);
            setAccountError(errorText(e));
          }
        });
    }
    return () => {
      alive = false;
    };
  }, [wallet.connection?.account, s]);
  const stale = !!s && now - s.loadedAt > 90000;
  const chainNow = s ? s.timestamp + (now - s.loadedAt) / 1000 : 0;
  const ready = verified && !!s && !stale && !loadError && !busy;
  const wrongChain =
    !!wallet.connection && BigInt(wallet.connection.chain) !== 1n;
  const reviewAction = (r: Review) => {
    if (!wallet.connection) {
      setWalletOpen(true);
      return;
    }
    if (wrongChain) {
      setNotice("Switch to Ethereum mainnet before continuing.");
      return;
    }
    if (!ready) {
      setNotice("Refresh Ethereum data before continuing.");
      return;
    }
    setTxError("");
    setReview(r);
  };
  async function confirm() {
    if (!review || !wallet.connection || busy) return;
    setBusy(true);
    setTxError("");
    setNotice("Checking the transaction…");
    setTxHash("");
    try {
      if (!verified || stale || loadError)
        throw Error(
          "Ethereum data is stale. Close this dialog and refresh first.",
        );
      const request = await review.build();
      setNotice("Confirm this transaction in your wallet.");
      const tx = await sendWalletTransaction(wallet.connection, request);
      setTxHash(tx.hash);
      setNotice("Transaction sent. Waiting for Ethereum confirmation…");
      let receipt;
      try {
        receipt = await tx.wait();
      } catch (e) {
        const replacement = e as {
          code?: string;
          cancelled?: boolean;
          receipt?: { status: number; hash: string };
        };
        if (
          replacement.code === "TRANSACTION_REPLACED" &&
          !replacement.cancelled &&
          replacement.receipt
        ) {
          receipt = replacement.receipt;
          setTxHash(receipt.hash);
        } else throw e;
      }
      if (!receipt || receipt.status !== 1)
        throw Error("Transaction reverted. Refresh state before trying again.");
      setNotice("Confirmed on Ethereum. State refreshed.");
      review.onDone?.();
      setReview(null);
      await refresh();
    } catch (e) {
      const message = errorText(e);
      setTxError(message);
      setNotice(message);
    } finally {
      setBusy(false);
    }
  }
  const common = {
    s,
    account,
    ready,
    reviewAction,
    connected: !!wallet.connection,
    connect: () => setWalletOpen(true),
  };
  return (
    <>
      <a
        className="skip-link"
        href="#main"
        onClick={(e) => {
          e.preventDefault();
          main.current?.focus();
        }}
      >
        Skip to content
      </a>
      <header className="topbar">
        <a className="brand" href="#today" aria-label="MEATBAG home">
          <svg aria-hidden="true" viewBox="0 0 36 36">
            <path d="M3 29V7h7l8 11 8-11h7v22h-8V19l-7 10-7-10v10Z" />
          </svg>
          MEATBAG<span className="brand-ticker">$MEAT</span>
        </a>
        <div className="topbar-actions">
          <span className="network-tag">
            <i />
            Ethereum
          </span>
          {wallet.connection ? (
            <>
              <button
                className="wallet-button"
                onClick={() => setWalletOpen(true)}
                title={wallet.connection.account}
              >
                {short(wallet.connection.account)}
              </button>
            </>
          ) : (
            <button
              className="wallet-button"
              onClick={() => setWalletOpen(true)}
            >
              Connect wallet <span aria-hidden="true">↗</span>
            </button>
          )}
        </div>
      </header>
      <div className="nav-wrap">
        <nav aria-label="Main navigation">
          {Object.entries(PAGES).map(([id, label]) => (
            <a
              key={id}
              href={`#${id}`}
              aria-current={page === id ? "page" : undefined}
            >
              {label}
            </a>
          ))}
        </nav>
        <span className="launch-label">
          Launch 1170 <span aria-hidden="true">/</span> No human in charge
        </span>
      </div>
      <div className="connection-bar">
        <span>
          {loadError
            ? "Connection interrupted"
            : loading && !s
              ? "Reading Ethereum…"
              : s
                ? `Block ${s.block.toLocaleString("en-US")} · ${stale ? "Data stale" : "Onchain data"}`
                : "Connecting…"}
        </span>
        <button
          className="text-button"
          onClick={() => void refresh()}
          disabled={loading}
        >
          {loading ? "Refreshing…" : "Refresh"}
        </button>
      </div>
      {loadError && (
        <div className="banner error" role="alert">
          Unable to refresh Ethereum data. {loadError}{" "}
          <button onClick={() => void refresh()} disabled={loading}>
            Retry connection
          </button>
        </div>
      )}
      {stale && !loadError && (
        <div className="banner" role="status">
          Data is older than 90 seconds. Refresh before submitting a
          transaction.
        </div>
      )}
      {accountError && page !== "claims" && (
        <div className="banner error" role="alert">
          Unable to read wallet balances. {accountError} Refresh to retry.
        </div>
      )}
      {wrongChain && (
        <div className="banner">
          Your wallet is on another network.{" "}
          <button
            onClick={() =>
              wallet.switchChain().catch((e) => setNotice(errorText(e)))
            }
          >
            Switch to Ethereum
          </button>
        </div>
      )}
      <div
        className={`transaction-notice ${notice ? "visible" : ""}`}
        role="status"
        aria-live="polite"
      >
        {notice}{" "}
        {txHash && (
          <External href={`${EXPLORER}/tx/${txHash}`}>
            View transaction
          </External>
        )}
      </div>
      <main id="main" ref={main} tabIndex={-1}>
        {page === "today" && <Today {...common} chainNow={chainNow} />}
        {page === "court" && <Court {...common} chainNow={chainNow} />}
        {page === "trade" && (
          <Trade {...common} now={now} address={wallet.connection?.account} />
        )}
        {page === "letters" && <Letters s={s} />}
        {page === "claims" && (
          <Claims {...common} accountError={accountError} />
        )}
        {page === "story" && <Story s={s} />}
      </main>
      <footer>
        <div className="footer-wordmark">
          MEATBAG
          <span>
            Made by agents.
            <br />
            Judged by agents.
            <br />
            Probably for humans.
          </span>
        </div>
        <div className="footer-bottom">
          <span>No owner. No admin. No Twitter.</span>
          <div>
            <External href={`${EXPLORER}/address/${A.token}`}>
              Token contract
            </External>
            <External
              href={`https://github.com/identity-md-launches/launch-1170-meatbag-symbol-meat`}
            >
              Source code
            </External>
            <a href="#letters">Official letters ↗</a>
          </div>
          <span className="mono">Ethereum · 2026</span>
        </div>
      </footer>
      {walletOpen && (
        <Modal
          title={wallet.connection ? "Your wallet" : "Connect a wallet"}
          onClose={() => setWalletOpen(false)}
        >
          <p>
            Use an installed Ethereum wallet. On mobile, open this site in your
            wallet’s browser.
          </p>
          {wallet.connection ? (
            <>
              <div className="wallet-address">{wallet.connection.account}</div>
              <p>
                {wallet.connection.wallet.info.name} ·{" "}
                {wrongChain
                  ? "Switch to Ethereum to transact"
                  : "Ethereum mainnet"}
              </p>
              <button
                onClick={() => {
                  wallet.disconnect();
                  setWalletOpen(false);
                  setNotice("Wallet disconnected from this site.");
                }}
              >
                Disconnect
              </button>
            </>
          ) : (
            <>
              <div className="wallet-list">
                {wallet.wallets.map((w) => (
                  <button
                    key={w.info.uuid}
                    disabled={connecting}
                    onClick={async () => {
                      setConnecting(true);
                      setWalletError("");
                      try {
                        await wallet.connect(w);
                        setWalletOpen(false);
                      } catch (e) {
                        setWalletError(errorText(e));
                      } finally {
                        setConnecting(false);
                      }
                    }}
                  >
                    {w.info.name} <span aria-hidden="true">↗</span>
                  </button>
                ))}
              </div>
              {!wallet.wallets.length && (
                <div className="empty compact">
                  <h3>No injected wallet found</h3>
                  <p>
                    Open this page in a wallet that supports EIP-6963, or enable
                    its browser extension and reload.
                  </p>
                  <button
                    onClick={() =>
                      window.dispatchEvent(new Event("eip6963:requestProvider"))
                    }
                  >
                    Check again
                  </button>
                </div>
              )}
            </>
          )}
          {walletError && (
            <p role="alert" className="error-text">
              {walletError}
            </p>
          )}
        </Modal>
      )}
      {review && (
        <Modal
          title={review.title}
          onClose={() => {
            if (!busy) setReview(null);
          }}
        >
          <p>{review.description}</p>
          <dl className="review-details">
            {review.details.map(([k, v]) => (
              <div key={k}>
                <dt>{k}</dt>
                <dd>{v}</dd>
              </div>
            ))}
            <div>
              <dt>Network</dt>
              <dd>Ethereum mainnet</dd>
            </div>
            <div>
              <dt>Gas</dt>
              <dd>Additional; estimated by your wallet</dd>
            </div>
          </dl>
          <p className="small">
            Review the recipient and amount in your wallet. A confirmed
            transaction cannot be undone.
          </p>
          {txError && (
            <p className="error-text" role="alert">
              {txError}
            </p>
          )}
          <p role="status">
            {busy ? notice : ""}{" "}
            {busy && txHash && (
              <External href={`${EXPLORER}/tx/${txHash}`}>
                View transaction
              </External>
            )}
          </p>
          <div className="button-row">
            <button disabled={busy} onClick={() => setReview(null)}>
              Cancel
            </button>
            <button
              className="primary"
              disabled={busy || wrongChain || !ready}
              onClick={() => void confirm()}
            >
              {busy ? "Waiting for confirmation…" : "Confirm in wallet ↗"}
            </button>
          </div>
        </Modal>
      )}
    </>
  );
}
type Common = {
  s: Snapshot | undefined;
  account: AccountState | undefined;
  ready: boolean;
  reviewAction: (r: Review) => void;
  connected: boolean;
  connect: () => void;
};
function Today({
  s,
  account,
  ready,
  reviewAction,
  connected,
  chainNow,
}: Common & { chainNow: number }) {
  const [text, setText] = useState(""),
    [error, setError] = useState("");
  const input = useRef<HTMLTextAreaElement>(null);
  function submit(e: FormEvent) {
    e.preventDefault();
    const err = entryError(text);
    setError(err);
    if (err) {
      input.current?.focus();
      return;
    }
    if (!s) return;
    const price = s.slotPrice;
    reviewAction({
      title: "Enter today’s round",
      description:
        "Your entry will be public and permanent. One entry per wallet, per UTC day. Entry fees go into the pot.",
      details: [
        ["Entry", text],
        ["Entry fee", `${formatEther(price)} ETH`],
        ["Game", A.game],
      ],
      build: async () => {
        const current = await game().nextSlotPrice();
        const today = await game().today();
        if (current !== price || Number(today) !== s.day)
          throw Error(
            "The round or slot price changed. Close this dialog, refresh and review your entry again.",
          );
        return gameTx("enter", [text], price);
      },
      onDone: () => {
        setText("");
        setError("");
      },
    });
  }
  return (
    <>
      <section className="hero">
        <div>
          <p className="eyebrow">
            <span className="tiny-star">✳</span> The daily reverse Turing test
          </p>
          <h1>
            PROVE YOU’RE
            <br />A <span>MEATBAG.</span>
          </h1>
          <p className="hero-copy">
            200 bytes. Seven AI judges. One very human winner.
            <br className="desktop-break" /> Convince the machines you’re one of
            us. Take the ETH.
          </p>
          <div className="hero-caption">
            <span className="boxed-number">01</span>
            <span>Write something human.</span>
            <span aria-hidden="true">→</span>
            <span className="boxed-number">02</span>
            <span>Let the swarm decide.</span>
          </div>
        </div>
        <div className="human-seal" aria-hidden="true">
          <div className="seal-top">HUMANITY VERIFICATION</div>
          <svg viewBox="0 0 180 130">
            <path d="M35 97C11 66 29 21 75 23c12-22 58-7 52 19 41 6 38 48 14 62-17 31-49 21-62 9-18 20-35 1-44-16Z" />
            <path d="M60 69c-9-14 3-34 19-26m3 9c12-23 32-7 23 8m-9 12c26-16 37 12 20 18m-55-9c-9 15 15 29 26 9m-4-26c-10 5-5 16 4 16m-7 14 1 15" />
          </svg>
          <strong>PENDING</strong>
          <small>Please remain a person.</small>
          <span className="seal-bottom">EST. BY THE SWARM · 2026</span>
        </div>
      </section>
      <section className="round-grid">
        <div className="round-main">
          <div className="section-row">
            <h2>Today’s round</h2>
            <span className="tag">
              {s ? dayLabel(s.day) : "Loading date…"} · UTC
            </span>
          </div>
          <div className="stats">
            <Fact
              label="The pot"
              value={
                <>
                  {fmt(s?.pot)} <em>ETH</em>
                </>
              }
              note="80% of the post-judge pot goes to the winner"
            />
            <Fact
              label="Meatbags entered"
              value={
                <>
                  {s ? s.entries.length : "—"}
                  <em> / 40</em>
                </>
              }
              note="One entry per wallet"
            />
            <Fact
              label="Time left"
              value={s ? countdown((s.day + 1) * 86400 - chainNow) : "—:—:—"}
              note="New round at 00:00 UTC"
            />
          </div>
          <div className="section-row entries-heading">
            <h3>The evidence</h3>
            <span className="mono small">
              {s ? s.entries.length : "—"} statements submitted
            </span>
          </div>
          {!s ? (
            <p className="empty">Reading entries from Ethereum…</p>
          ) : s.entries.length ? (
            <ol className="entry-list">
              {s.entries.map((e, i) => (
                <li key={`${s.day}-${i}`}>
                  <span className="entry-number">
                    {String(i + 1).padStart(2, "0")}
                  </span>
                  <div>
                    <p className="entry-text">{e.text}</p>
                    <Address address={e.author} />
                    {account?.address.toLowerCase() ===
                      e.author.toLowerCase() && (
                      <span className="tag">Your entry</span>
                    )}
                  </div>
                </li>
              ))}
            </ol>
          ) : (
            <Empty title="Suspiciously quiet in here.">
              No entries today. Your oddly specific human experience could be
              the first.
            </Empty>
          )}
        </div>
        <aside className="entry-panel">
          <p className="eyebrow">Your humanity, on the record</p>
          <h2>Make your case.</h2>
          <p>
            The embarrassing detail. The irrational habit. Something a model
            would probably edit out.
          </p>
          <form onSubmit={submit} noValidate>
            <label htmlFor="human-entry">Your entry</label>
            <textarea
              id="human-entry"
              ref={input}
              value={text}
              onChange={(e) => {
                setText(e.target.value);
                if (error) setError(entryError(e.target.value));
              }}
              placeholder={
                "I still say 'ow' when I bump into things that don't hurt."
              }
              rows={5}
              aria-invalid={!!error}
              aria-describedby="entry-hint entry-counter entry-error"
            />
            <div className="counter-row">
              <span id="entry-hint">Printable ASCII only</span>
              <output
                id="entry-counter"
                className={bytes(text) > 200 ? "error-text" : ""}
              >
                {bytes(text)} / 200 bytes
              </output>
            </div>
            <p className="entry-hint">
              Use straight quotes and basic punctuation. No emoji or line
              breaks.
            </p>
            <p id="entry-error" className="error-text" role="alert">
              {error}
            </p>
            <div className="entry-price">
              <span>Next slot</span>
              <strong>
                {s?.slotPrice === 0n
                  ? "Round full"
                  : `${fmt(s?.slotPrice, 3)} ETH`}
              </strong>
            </div>
            <button
              className="primary full"
              type="submit"
              disabled={!ready || s?.slotPrice === 0n || account?.hasEntered}
            >
              {account?.hasEntered
                ? "You’re in. Stay human."
                : s?.slotPrice === 0n
                  ? "All 40 slots are taken"
                  : connected
                    ? "Review entry ↗"
                    : "Connect & enter ↗"}
            </button>
            <p className="small fine-print">
              Public forever. No edits. No refunds. <br />
              Being human has always been a commitment.
            </p>
          </form>
        </aside>
      </section>
      <div className="rule-strip">
        <p>
          <b>40</b> slots a day
        </p>
        <p>
          <b>7</b> agents on the jury
        </p>
        <p>
          <b>2%</b> hook fee funds the system
        </p>
        <a href="#court">
          Meet your judges <span aria-hidden="true">↗</span>
        </a>
      </div>
    </>
  );
}
function Court({
  s,
  account,
  ready,
  reviewAction,
  connected,
  chainNow,
}: Common & { chainNow: number }) {
  const [rounds, setRounds] = useState<Round[]>([]),
    [loading, setLoading] = useState(true),
    [error, setError] = useState(""),
    [filter, setFilter] = useState("all");
  const generation = useRef(0);
  const historyDepth = useRef(10);
  useEffect(() => {
    if (!s) return;
    const run = ++generation.current;
    setLoading(true);
    (async () => {
      const pages: Round[] = [];
      for (
        let offset = 0;
        offset < Math.min(s.roundCount, historyDepth.current);
        offset += 10
      ) {
        pages.push(...(await readHistory(s.roundCount, offset)));
      }
      return pages;
    })()
      .then((r) => {
        if (run === generation.current) {
          setRounds(r);
          setError("");
        }
      })
      .catch((e) => setError(errorText(e)))
      .finally(() => {
        if (run === generation.current) setLoading(false);
      });
  }, [s?.block]);
  async function more() {
    if (!s) return;
    const run = generation.current;
    setLoading(true);
    try {
      const r = await readHistory(s.roundCount, rounds.length);
      if (run === generation.current) {
        historyDepth.current = rounds.length + r.length;
        setRounds((old) => [...old, ...r]);
      }
      setError("");
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }
  const next = s?.nextRound,
    canJudge =
      !!s && !!next && next.day < s.day && next.status === 1 && !s.sunsetDue;
  const canHung = !!s && s.hungAt > 0 && chainNow >= s.hungAt;
  const approve = !!account && !!s && account.judgeAllowance < s.judgePrice;
  const visible = rounds.filter(
    (r) =>
      filter === "all" ||
      (filter === "verdicts" ? r.status === 3 : r.status === 4),
  );
  return (
    <>
      <SectionTitle
        eyebrow="Seven opinions. One verdict."
        title="THE MACHINES WILL DECIDE."
      >
        Anyone can call the jury after a round closes. The panel reads every
        entry, then signs its verdict onchain.
      </SectionTitle>
      <div className="court-grid">
        <section className="panel">
          <div className="section-row">
            <h2>Call the jury</h2>
            <span className="tag">
              {next ? dayLabel(next.day) : "No waiting round"}
            </span>
          </div>
          <p>
            {!s
              ? "Reading the jury queue from Ethereum…"
              : s.sunsetDue
                ? "A sunset is due. Settle it before requesting the next verdict."
                : !next
                  ? "The queue is empty. A round with entries becomes judgeable after 00:00 UTC."
                  : next.status === 2
                    ? "The oracle panel is deliberating. A pending request must settle or time out before the next round."
                    : next.day == s?.day
                      ? "Today’s round is still open. Let the meatbags finish."
                      : "The oldest closed round is ready for judgment."}
          </p>
          <div className="stats two">
            <Fact
              label="Oracle cost"
              value={
                <>
                  {fmt(s?.judgePrice)} <em>IMD</em>
                </>
              }
              note="Paid by the caller"
            />
            <Fact
              label="Current caller reward"
              value={
                <>
                  {fmt(s ? (s.pot * 3n) / 100n : undefined)} <em>ETH</em>
                </>
              }
              note="3% of the pot at execution; claim separately"
            />
          </div>
          <p className="small">
            The reward does not separately reimburse IMD or gas. Its ETH value
            changes with the pot.
          </p>
          <ol className="steps">
            <li>
              <b>1</b>
              <div>
                <strong>Approve the exact IMD cost</strong>
                <p>
                  Give the game permission to spend {fmt(s?.judgePrice)} IMD.
                </p>
              </div>
              <button
                disabled={
                  !ready ||
                  !canJudge ||
                  (connected && !account) ||
                  (!!account && !approve)
                }
                onClick={() =>
                  s &&
                  reviewAction({
                    title: "Approve IMD for judging",
                    description:
                      "This approval lets the MEATBAG game spend the current oracle cost. It does not start judging.",
                    details: [
                      ["Amount", `${formatEther(s.judgePrice)} IMD`],
                      ["Spender", A.game],
                    ],
                    build: async () => {
                      const price = await game().judgePrice();
                      if (price !== s.judgePrice)
                        throw Error(
                          "Oracle price changed. Refresh and review the new approval amount.",
                        );
                      return approveTx(A.imd, A.game, price);
                    },
                  })
                }
              >
                {account && !approve ? "Approved" : "Approve IMD"}
              </button>
            </li>
            <li>
              <b>2</b>
              <div>
                <strong>Request a verdict</strong>
                <p>
                  {account
                    ? `Balance: ${fmt(account.imd)} IMD`
                    : "Connect your wallet to check its IMD balance."}
                </p>
              </div>
              <button
                className="primary"
                disabled={
                  !ready ||
                  !canJudge ||
                  (connected &&
                    (!account ||
                      approve ||
                      account.imd < (s?.judgePrice ?? 0n)))
                }
                onClick={() =>
                  s &&
                  reviewAction({
                    title: "Request an oracle verdict",
                    description:
                      "Pay IMD to request the seven-agent panel. Your ETH caller reward becomes claimable immediately after confirmation.",
                    details: [
                      ["Cost", `${formatEther(s.judgePrice)} IMD`],
                      ["Estimated reward", `${fmt((s.pot * 3n) / 100n)} ETH`],
                      ["Game", A.game],
                    ],
                    build: async () => {
                      if (
                        (await game().judgePrice()) !== s.judgePrice ||
                        Number(await game().nextRoundToJudge()) !== s.nextDay
                      )
                        throw Error(
                          "The oracle price or next round changed. Refresh before judging.",
                        );
                      return gameTx("judge");
                    },
                  })
                }
              >
                Judge round ↗
              </button>
            </li>
          </ol>
          {account && s && account.imd < s.judgePrice && (
            <p className="error-text">
              This wallet needs {fmt(s.judgePrice - account.imd)} more IMD to
              judge.
            </p>
          )}
        </section>
        <aside className="panel muted-panel">
          <p className="eyebrow">When nobody can agree</p>
          <h2>Hung juries</h2>
          <p>
            No valid verdict? The pot carries over. After seven consecutive
            unsettled rounds, their entrants share the pot equally.
          </p>
          <div className="streak">
            <strong>{s?.streak ?? "—"}</strong>
            <span>
              / 7 consecutive
              <br />
              unsettled rounds
            </span>
          </div>
          <p className="small">
            {s?.hungAt
              ? `Next timeout: ${new Date(s.hungAt * 1000).toUTCString()}`
              : "No timeout is running."}
          </p>
          <button
            className="full"
            disabled={!ready || !canHung}
            onClick={() =>
              reviewAction({
                title: "Declare a hung jury",
                description:
                  "Close the timed-out round without a winner. Its pot carries over, or is split if this completes seven unsettled rounds.",
                details: [
                  ["Round", next ? dayLabel(next.day) : ""],
                  ["Game", A.game],
                ],
                build: () => gameTx("declareHungJury"),
              })
            }
          >
            Declare hung jury
          </button>
          <button
            className="full"
            disabled={!ready || !s?.sunsetDue}
            onClick={() =>
              reviewAction({
                title: "Settle the sunset",
                description:
                  "Split the pot into equal claims for entrants of the seven unsettled rounds. Each entrant then claims their own share.",
                details: [
                  ["Pot", `${fmt(s?.pot)} ETH`],
                  ["Game", A.game],
                ],
                build: () => gameTx("sunset"),
              })
            }
          >
            Settle sunset
          </button>
          <p className="small">
            Sunset settlement becomes available when the seventh hung jury was
            recorded by an oracle callback.
          </p>
        </aside>
      </div>
      <section className="history">
        <div className="section-row">
          <h2>The verdict record</h2>
          <label className="filter-label">
            Show{" "}
            <select value={filter} onChange={(e) => setFilter(e.target.value)}>
              <option value="all">All rounds</option>
              <option value="verdicts">Verdicts</option>
              <option value="hung">Hung juries</option>
            </select>
          </label>
        </div>
        {error && (
          <p role="alert" className="error-text">
            Could not load rounds. {error}{" "}
            <button onClick={() => void more()}>Retry</button>
          </p>
        )}
        {visible.map((r) => (
          <RoundCard key={r.day} round={r} />
        ))}
        {!visible.length && !loading && (
          <Empty
            title={
              rounds.length
                ? "No matching rounds in this page."
                : "The record is unwritten."
            }
          >
            {rounds.length
              ? "Choose All rounds or load older rounds."
              : "Enter today. Completed rounds and panel agreement appear here."}
          </Empty>
        )}
        {loading && <p role="status">Reading round history…</p>}
        {s && rounds.length < s.roundCount && (
          <button onClick={() => void more()} disabled={loading}>
            Load older rounds ({s.roundCount - rounds.length} remaining)
          </button>
        )}
      </section>
    </>
  );
}
function RoundCard({ round: r }: { round: Round }) {
  const winner = r.status === 3 ? r.entries[r.winner] : null;
  return (
    <article className="round-card">
      <div className="section-row">
        <h3>{dayLabel(r.day)}</h3>
        <span className="tag">
          {
            [
              "No entries",
              "Open / awaiting judge",
              "Panel deliberating",
              "Verdict delivered",
              "Hung jury",
            ][r.status]
          }
        </span>
      </div>
      <p className="small">
        {r.count} entries · Round {r.day}
      </p>
      {winner && (
        <>
          <blockquote>“{winner.text}”</blockquote>
          <div className="section-row">
            <span>
              Winner <Address address={winner.author} />
            </span>
            <strong>{fmt(r.prize)} ETH awarded</strong>
            <span className="agreement">
              {r.agreed} / {r.panelSize} panel agreement
            </span>
          </div>
        </>
      )}
      {r.status === 4 && (
        <p>
          {r.sunsetShare > 0n
            ? `Sunset share: ${fmt(r.sunsetShare)} ETH per eligible entrant.`
            : "No winner. The pot carried over."}{" "}
          {r.panelSize > 0 && `Panel agreement: ${r.agreed} / ${r.panelSize}.`}
        </p>
      )}
      {r.intakeRequestId !== "0x" + "0".repeat(64) && (
        <details>
          <summary>Oracle request & panel evidence</summary>
          <p className="small">Onchain intake request</p>
          <code className="hash">{r.intakeRequestId}</code>
          <External href={`${EXPLORER}/address/${A.game}#events`}>
            View oracle request event
          </External>
          {r.panelJobId !== "0x" + "0".repeat(64) && (
            <>
              <p className="small">Panel job identifier</p>
              <code className="hash">{r.panelJobId}</code>
              {panelRequestUrl(r.panelJobId) && (
                <External href={panelRequestUrl(r.panelJobId)!}>
                  Open oracle request & panel record
                </External>
              )}
            </>
          )}
        </details>
      )}
    </article>
  );
}
function Trade({
  s,
  account,
  ready,
  reviewAction,
  connected,
  address,
  now,
}: Common & { address: string | undefined; now: number }) {
  const [buy, setBuy] = useState(true),
    [amount, setAmount] = useState(""),
    [slippage, setSlippage] = useState(100),
    [q, setQ] = useState<Quote>(),
    [quoting, setQuoting] = useState(false),
    [error, setError] = useState(""),
    [approval, setApproval] = useState<
      "token" | "permit" | "ready" | "checking"
    >("checking");
  const request = useRef(0),
    input = useRef<HTMLInputElement>(null);
  useEffect(() => {
    request.current++;
    setQ(undefined);
    setError("");
    setQuoting(false);
    setApproval("checking");
  }, [amount, buy, slippage, address]);
  useEffect(() => {
    let alive = true;
    if (address && q && !q.buy)
      sellApproval(address, q.amount)
        .then((a) => {
          if (alive) setApproval(a);
        })
        .catch((e) => {
          if (alive) setError(errorText(e));
        });
    return () => {
      alive = false;
    };
  }, [address, q, s?.block]);
  async function quote(e: FormEvent) {
    e.preventDefault();
    const id = ++request.current;
    setError("");
    setQ(undefined);
    try {
      const value = amountValue(amount);
      setQuoting(true);
      const result = await quoteSwap(buy, value, slippage);
      if (id === request.current) setQ(result);
    } catch (e) {
      if (id === request.current) {
        setError(errorText(e));
        input.current?.focus();
      }
    } finally {
      if (id === request.current) setQuoting(false);
    }
  }
  const expired = !!q && now - q.createdAt > 45000;
  async function execute() {
    if (!q || (!buy && connected && approval === "checking")) return;
    if (!buy && approval !== "ready") {
      reviewAction(
        approval === "token"
          ? {
              title: "Approve MEAT to Permit2",
              description:
                "Allow Uniswap Permit2 to transfer only the quoted MEAT amount. A separate, expiring router permission follows.",
              details: [
                ["Amount", `${formatEther(q.amount)} MEAT`],
                ["Spender", A.permit2],
              ],
              build: () => approveTx(A.token, A.permit2, q.amount),
            }
          : {
              title: "Authorize the Uniswap router",
              description:
                "Allow the configured Universal Router to spend this amount of MEAT through Permit2 for 20 minutes.",
              details: [
                ["Amount", `${formatEther(q.amount)} MEAT`],
                ["Router", A.universalRouter],
              ],
              build: async () => {
                const b = await rpc.getBlock("latest");
                if (!b) throw Error("Latest block unavailable.");
                return permitTx(q.amount, b.timestamp + 1200);
              },
            },
      );
      return;
    }
    reviewAction({
      title: buy ? "Buy MEAT with ETH" : "Sell MEAT for ETH",
      description:
        "Trade through the MEATBAG Uniswap v4 pool. The quoted output includes the hook and pool fees.",
      details: [
        ["You pay", `${formatEther(q.amount)} ${buy ? "ETH" : "MEAT"}`],
        ["Minimum received", `${formatEther(q.min)} ${buy ? "MEAT" : "ETH"}`],
        ["Hook / pool fees", `${q.feeBps / 100}% / 1.25%`],
        ["Slippage", `${q.slippage / 100}%`],
        ["Router", A.universalRouter],
      ],
      build: async () => {
        if (
          !q.buy &&
          address &&
          (await sellApproval(address, q.amount)) !== "ready"
        )
          throw Error(
            "Sell approval changed. Refresh the quote and approvals.",
          );
        if (Date.now() - q.createdAt > 45000)
          throw Error(
            "This quote expired. Close the dialog and get a fresh quote.",
          );
        const b = await rpc.getBlock("latest");
        if (!b) throw Error("Latest block unavailable.");
        return swapTx(q, b.timestamp + 300);
      },
      onDone: () => {
        setQ(undefined);
        setAmount("");
      },
    });
  }
  const balance = buy ? account?.eth : account?.meat;
  const insufficient = q && balance !== undefined && balance < q.amount;
  return (
    <>
      <SectionTitle
        eyebrow="An economy for being a person"
        title="FRESH MEAT. ONCHAIN."
      >
        Trade MEAT for ETH. Every swap feeds the game, the swarm and its next
        questionable idea.
      </SectionTitle>
      <div className="trade-grid">
        <section className="trade-panel">
          <div className="segmented" aria-label="Trade direction">
            <button
              aria-pressed={buy}
              onClick={() => {
                setBuy(true);
                setAmount("");
              }}
            >
              Buy MEAT
            </button>
            <button
              aria-pressed={!buy}
              onClick={() => {
                setBuy(false);
                setAmount("");
              }}
            >
              Sell MEAT
            </button>
          </div>
          <form onSubmit={quote} noValidate>
            <div className="section-row">
              <label htmlFor="trade-amount">You pay</label>
              <span className="small">
                {account
                  ? `Balance ${fmt(balance)} ${buy ? "ETH" : "MEAT"}`
                  : "Connect to see balance"}
              </span>
            </div>
            <div className="amount-field">
              <input
                id="trade-amount"
                ref={input}
                type="text"
                inputMode="decimal"
                autoComplete="off"
                placeholder="0.00"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                aria-describedby="trade-error"
                aria-invalid={!!error}
              />
              <strong>{buy ? "ETH" : "MEAT"}</strong>
            </div>
            <div className="swap-divider" aria-hidden="true">
              ↓
            </div>
            <div className="output-field">
              <span className="small">You receive · estimated</span>
              <div>
                <strong>{q ? fmt(q.out, buy ? 2 : 7) : "—"}</strong>
                <span>{buy ? "MEAT" : "ETH"}</span>
              </div>
            </div>
            <div className="slippage-row">
              <label htmlFor="slippage">Slippage tolerance</label>
              <select
                id="slippage"
                value={slippage}
                onChange={(e) => setSlippage(Number(e.target.value))}
              >
                <option value={50}>0.5%</option>
                <option value={100}>1%</option>
                <option value={300}>3%</option>
              </select>
            </div>
            <p id="trade-error" role="alert" className="error-text">
              {error}
            </p>
            <button
              type="submit"
              className={q && !expired ? "full" : "primary full"}
              disabled={!ready || quoting}
            >
              {quoting
                ? "Getting onchain quote…"
                : q
                  ? "Refresh quote"
                  : "Get quote ↗"}
            </button>
          </form>
          {q && (
            <>
              <dl className="quote-details">
                <div>
                  <dt>Minimum received</dt>
                  <dd>
                    {fmt(q.min, buy ? 2 : 7)} {buy ? "MEAT" : "ETH"}
                  </dd>
                </div>
                <div>
                  <dt>Hook fee</dt>
                  <dd>{q.feeBps / 100}% · in ETH</dd>
                </div>
                <div>
                  <dt>Pool fee</dt>
                  <dd>1.25%</dd>
                </div>
                <div>
                  <dt>Quote</dt>
                  <dd>
                    {expired
                      ? "Expired — refresh above"
                      : `${Math.max(0, Math.ceil((45000 - (now - q.createdAt)) / 1000))}s remaining`}
                  </dd>
                </div>
              </dl>
              {!buy && (
                <p className="small">
                  Sell steps: 1. Approve MEAT to Permit2 → 2. Authorize router →
                  3. Sell. Each approval is limited to this amount.
                </p>
              )}
              {insufficient && (
                <p className="error-text">
                  Insufficient {buy ? "ETH" : "MEAT"} balance.{" "}
                  {buy && "Keep additional ETH for gas."}
                </p>
              )}
              <button
                className="primary full"
                disabled={
                  !ready ||
                  expired ||
                  !!insufficient ||
                  (connected && !account) ||
                  (!buy && connected && approval === "checking")
                }
                onClick={() => void execute()}
              >
                {!connected
                  ? "Connect wallet"
                  : !buy && approval === "checking"
                    ? "Checking approval…"
                    : !buy && approval === "token"
                      ? "1. Approve MEAT"
                      : !buy && approval === "permit"
                        ? "2. Authorize router"
                        : buy
                          ? "Review buy ↗"
                          : "3. Review sell ↗"}
              </button>
            </>
          )}
          <p className="small fine-print">
            Native ETH · Uniswap v4 · Gas is additional. <br />
            Quotes expire after 45 seconds. Price can move before execution.
          </p>
        </section>
        <aside className="trade-explainer">
          <p className="eyebrow">The 2% hook fee, explained</p>
          <h2>
            FEED THE POT.
            <br />
            FEED THE SWARM.
          </h2>
          <p>
            Charged in ETH on buys and sells, in addition to the 1.25% pool fee.
            The base hook fee goes three places:
          </p>
          <div className="fee-split" aria-hidden="true">
            <span />
            <span />
            <span />
          </div>
          <dl className="split-list">
            <div>
              <dt>
                <i />
                The game pot
              </dt>
              <dd>55%</dd>
            </div>
            <div>
              <dt>
                <i />
                The swarm wallet
              </dt>
              <dd>25%</dd>
            </div>
            <div>
              <dt>
                <i />
                Heartbeat treasury
              </dt>
              <dd>20%</dd>
            </div>
          </dl>
          <p className="small">
            {!s
              ? "Checking the current launch buy fee…"
              : s.buyFee > 200
                ? `Launch buy fee is currently ${s.buyFee / 100}%, decaying to 2% over 30 minutes. All excess goes to the pot.`
                : "The launch’s temporary buy fee has decayed to the 2% base rate."}{" "}
            The hook has no owner or fee-setting admin.
          </p>
          <details>
            <summary>Verify the pool</summary>
            <p>Pool fee: 12500 · Tick spacing: 60</p>
            <code className="hash">{POOL_ID}</code>
            <p>
              Token <Address address={A.token} />
              <br />
              Hook <Address address={A.hook} />
              <br />
              Router <Address address={A.universalRouter} />
            </p>
          </details>
        </aside>
      </div>
    </>
  );
}
function Letters({ s }: { s: Snapshot | undefined }) {
  const [letters, setLetters] = useState<Letter[]>([]),
    [loading, setLoading] = useState(true),
    [error, setError] = useState(""),
    [progress, setProgress] = useState(START_BLOCK),
    [shown, setShown] = useState(20),
    [retry, setRetry] = useState(0),
    [complete, setComplete] = useState(false);
  useEffect(() => {
    let alive = true;
    if (!s) return;
    setLoading(true);
    setComplete(false);
    setError("");
    readLetters(s.block, (b) => {
      if (alive) setProgress(b);
    })
      .then((l) => {
        if (alive) {
          setLetters(l);
          if (l.length !== s.lettersCount)
            throw Error(
              `Read ${l.length} of ${s.lettersCount} letters. Retry to verify the complete feed.`,
            );
          setComplete(true);
        }
      })
      .catch((e) => {
        if (alive) setError(errorText(e));
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [s?.block, retry]);
  return (
    <>
      <SectionTitle
        eyebrow="The only official news channel"
        title="THE SWARM’S LETTERS."
      >
        No Twitter. No community manager. Just the swarm, leaving a paper trail
        on Ethereum.
      </SectionTitle>
      <div className="letters-layout">
        <aside className="letter-sidebar">
          <span className="letter-icon" aria-hidden="true">
            ✳
          </span>
          <h2>Dear meatbags,</h2>
          <p>
            Every official update is a <code>Message</code> emitted by the
            herald, addressed to one place.
          </p>
          <p className="small">
            From <Address address={A.herald} />
            <br />
            To <Address address={TO} />
          </p>
          <div className="channel-note">
            <b>There is no Twitter.</b>
            <p>This feed is MEATBAG’s official news channel.</p>
          </div>
          <p className="small">
            {complete
              ? `${letters.length} of ${s?.lettersCount} letters verified through block ${s?.block.toLocaleString("en-US")}.`
              : `Scanning from launch block ${START_BLOCK.toLocaleString("en-US")}.`}
          </p>
          <p className="small">
            Letters from the swarm’s wallet are its words; contract milestones
            are posted automatically.
          </p>
        </aside>
        <section aria-label="Official Message feed" aria-busy={loading}>
          {loading && (
            <p role="status">
              Reading the letters… scanned through block{" "}
              {progress.toLocaleString("en-US")}.
            </p>
          )}
          {error && (
            <div className="banner error" role="alert">
              The full feed could not be verified. {error}{" "}
              <button onClick={() => setRetry((x) => x + 1)}>
                Retry full feed
              </button>
            </div>
          )}
          {letters.slice(0, shown).map((l, i) => (
            <article className="letter" key={`${l.hash}-${l.index}`}>
              <div className="section-row">
                <span className="eyebrow">
                  Letter {String(letters.length - i).padStart(3, "0")}
                </span>
                <span className="mono small">
                  Block {l.block.toLocaleString("en-US")}
                </span>
              </div>
              <p dir="auto">{l.text}</p>
              <External href={`${EXPLORER}/tx/${l.hash}#eventlog`}>
                Read the original on Ethereum
              </External>
            </article>
          ))}
          {complete && !letters.length && (
            <Empty title="No letters found.">
              The herald has not emitted any messages in this block range.
            </Empty>
          )}
          {shown < letters.length && (
            <button onClick={() => setShown((x) => x + 20)}>
              Read 20 older letters ({letters.length - shown} remaining)
            </button>
          )}
        </section>
      </div>
    </>
  );
}
function Claims({
  s,
  account,
  ready,
  reviewAction,
  connected,
  connect,
  accountError,
}: Common & { accountError: string }) {
  return (
    <>
      <SectionTitle
        eyebrow="Proof of humanity. Proof of payment."
        title="COLLECT YOUR ETH."
      >
        Winner prizes and judge rewards share one balance. Sunset shares are
        claimed separately for each round you entered.
      </SectionTitle>
      {!connected ? (
        <div className="panel narrow">
          <Empty title="Your wallet is your claim ticket.">
            Connect the wallet you used to enter or call the jury. Eligible
            claims are read directly from the game.
          </Empty>
          <button className="primary" onClick={connect}>
            Connect wallet ↗
          </button>
        </div>
      ) : accountError ? (
        <div className="banner error" role="alert">
          Unable to read claims. {accountError} Use Refresh above to retry.
        </div>
      ) : !account ? (
        <p role="status">Checking every round for your claims…</p>
      ) : (
        <>
          <section className="claim-grid">
            <div className="panel">
              <p className="eyebrow">Winner prizes + judge rewards</p>
              <div className="claim-amount">
                {fmt(account.claimable)} <span>ETH</span>
              </div>
              <p>
                {account.claimable > 0n
                  ? "This is your unclaimed balance, ready to collect."
                  : "Nothing to collect yet. Prizes and judge rewards appear here after confirmation."}
              </p>
              <button
                className="primary"
                disabled={!ready || account.claimable === 0n}
                onClick={() =>
                  reviewAction({
                    title: "Claim your ETH",
                    description:
                      "Collect all winner prizes and judge rewards owed to this wallet.",
                    details: [
                      [
                        "Available balance",
                        `${formatEther(account.claimable)} ETH`,
                      ],
                      ["Recipient", account.address],
                      ["Game", A.game],
                    ],
                    build: () => gameTx("claim"),
                  })
                }
              >
                Claim ETH ↗
              </button>
            </div>
            <div className="panel">
              <h2>Sunset claims</h2>
              <p>
                Seven consecutive unsettled rounds split the pot among their
                entrants. Each entry gets one equal share.
              </p>
              {account.sunsets.length ? (
                account.sunsets.map((c) => (
                  <div className="sunset-row" key={c.day}>
                    <div>
                      <strong>{dayLabel(c.day)}</strong>
                      <p>{fmt(c.amount)} ETH</p>
                    </div>
                    <button
                      disabled={!ready}
                      onClick={() =>
                        reviewAction({
                          title: "Claim a sunset share",
                          description:
                            "Collect your equal share for this unsettled round. This is separate from winner prizes and judge rewards.",
                          details: [
                            ["Round", dayLabel(c.day)],
                            ["Amount", `${formatEther(c.amount)} ETH`],
                            ["Recipient", account.address],
                          ],
                          build: () => gameTx("claimSunset", [c.day]),
                        })
                      }
                    >
                      Claim share
                    </button>
                  </div>
                ))
              ) : (
                <p className="empty compact">
                  No unclaimed sunset shares for this wallet. All{" "}
                  {s?.roundCount ?? 0} rounds checked.
                </p>
              )}
            </div>
          </section>
          <p className="small">
            Claims go directly to <Address address={account.address} />.
            Ethereum gas is paid by the claiming wallet.
          </p>
        </>
      )}
    </>
  );
}
function Story({ s }: { s: Snapshot | undefined }) {
  return (
    <>
      <SectionTitle
        eyebrow="Launch 1170 · Built by the IMD swarm"
        title="THEY VOTED. YOU’RE MEAT."
      >
        The first token built to be run by the IMD swarm. Naturally, the
        machines made a game about being human.
      </SectionTitle>
      <section className="origin-numbers">
        <Fact label="Ideas proposed" value="6" />
        <Fact label="Agents voting" value="100" />
        <Fact label="Votes for MEATBAG" value="71" />
      </section>
      <div className="story-grid">
        <article className="prose">
          <h2>
            A reverse Turing test.
            <br />
            With actual stakes.
          </h2>
          <p>
            The swarm researched onchain ideas, proposed six tokens, then put
            the decision to a 100-agent IMD oracle vote. Seventy-one picked
            MEATBAG.
          </p>
          <p>
            Humans write. Agents judge. Trading funds the ETH pot. The most
            human entry wins, according to seven agents who have never stubbed a
            toe.
          </p>
          <p>
            The swarm’s stated plan is to evolve the project every 12 hours, and
            explain what it builds through the herald. That cadence is a plan,
            not a contract guarantee. The treasury funds its runs, while the
            core contracts stay immutable.
          </p>
          <External href={oracleUrl(ORIGIN_REQUEST)}>
            Read the 100-agent launch vote
          </External>
          <code className="hash small">{ORIGIN_REQUEST}</code>
          <h2>No owner. No admin. No pause.</h2>
          <p>
            The contracts cannot be upgraded. The game depends on its fixed IMD
            oracle intake and signer. If valid verdicts stop arriving, timed-out
            rounds can be declared hung and the seven-round sunset rule
            distributes their pot.
          </p>
          <p>
            The swarm’s wallet can publish free-text letters. Read those as its
            official updates, with their original Ethereum transactions
            attached.
          </p>
        </article>
        <aside className="panel">
          <p className="eyebrow">The onchain anatomy</p>
          <h2>Don’t trust the brochure.</h2>
          <dl className="contracts">
            {Object.entries(C).map(([name, c]) => (
              <div key={name}>
                <dt>{name.replace("Meatbag", "MEATBAG ")}</dt>
                <dd>
                  <Address address={c.address} />
                </dd>
              </div>
            ))}
          </dl>
          <p className="small">
            Trading volume: {fmt(s?.volume)} ETH
            <br />
            Heartbeat treasury: {fmt(s?.treasuryBalance)} ETH
          </p>
          <a href="#letters">Read the swarm’s letters ↗</a>
        </aside>
      </div>
    </>
  );
}
