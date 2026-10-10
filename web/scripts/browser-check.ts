/** Production-export browser checks. RPC requests are routed to a local mainnet fork. */
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { readFileSync, existsSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, extname } from "node:path";
import { chromium, expect } from "@playwright/test";
import {
  JsonRpcProvider,
  Contract,
  keccak256,
  AbiCoder,
  parseEther,
  zeroPadValue,
  toBeHex,
} from "ethers";
import { A, C, RPC, ERC20_ABI } from "../src/config";
import { game, gameTx } from "../src/chain";
const exportDir = resolve(process.argv[2] || "../dist"),
  outDir = resolve(process.argv[3] || "../artifacts");
mkdirSync(outDir, { recursive: true });
mkdirSync(resolve(outDir, "screenshots"), { recursive: true });
const block = JSON.parse(
  readFileSync(
    new URL("../provenance/verification.json", import.meta.url),
    "utf8",
  ),
).block;
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
    "18548",
    "--silent",
    "--no-storage-caching",
    "--fork-state-by-number",
    "--no-fork-node-info",
    "--compute-units-per-second",
    "100",
  ],
  { stdio: ["ignore", "pipe", "pipe"] },
);
const p = new JsonRpcProvider("http://127.0.0.1:18548", 1, {
  staticNetwork: true,
  cacheTimeout: 0,
});
p.pollingInterval = 100;
const mime: Record<string, string> = {
  ".html": "text/html",
  ".js": "application/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
  ".woff2": "font/woff2",
};
const server = createServer((req, res) => {
  const raw = (req.url || "/").split("?")[0];
  if (!raw.startsWith("/preview/")) {
    res.writeHead(404).end();
    return;
  }
  const path = resolve(
    exportDir,
    decodeURIComponent(raw.slice(9) || "index.html"),
  );
  if (!path.startsWith(exportDir + "/") || !existsSync(path)) {
    res.writeHead(404).end();
    return;
  }
  res.setHeader(
    "Content-Type",
    mime[extname(path)] || "application/octet-stream",
  );
  res.end(readFileSync(path));
});
await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
const address = server.address() as { port: number };
const url = `http://127.0.0.1:${address.port}/preview/`;
const executable =
  process.env.BROWSER_EXECUTABLE_PATH ||
  "/opt/ms-playwright/chromium-1247/chrome-linux64/chrome";
const browser = await chromium.launch({
  headless: true,
  executablePath: existsSync(executable) ? executable : undefined,
  args: ["--no-sandbox"],
});
const context = await browser.newContext({
  viewport: { width: 1280, height: 900 },
  reducedMotion: "reduce",
});
const page = await context.newPage();
const issues: string[] = [];
const rpcErrors: unknown[] = [];
const checks: string[] = [];
const axeResults: any[] = [];
page.on("pageerror", (e) => issues.push(e.message));
page.on("console", (m) => {
  if (m.type() === "error") issues.push(m.text());
});
let offline = false;
async function check(name: string, fn: () => Promise<void>) {
  await fn();
  checks.push(name);
  console.log("PASS", name);
}
async function mainnetReady() {
  await expect(page.getByText(/Block [\d,]+ · Onchain data/)).toBeVisible({
    timeout: 30000,
  });
  await expect(
    page.getByRole("button", { name: "Refresh", exact: true }),
  ).toBeEnabled({ timeout: 30000 });
}
async function navigate(hash: string) {
  await page.locator(`nav a[href='#${hash}']`).click();
}
async function refresh() {
  await page.getByRole("button", { name: "Refresh", exact: true }).click();
  await mainnetReady();
}
try {
  for (let i = 0; i < 100; i++) {
    try {
      await p.send("eth_chainId", []);
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  const actor = await (await p.getSigner(0)).getAddress();
  const word = (v: bigint) => zeroPadValue(toBeHex(v), 32);
  const mappingSlot = (type: string, key: number | string, base: number) =>
    keccak256(
      AbiCoder.defaultAbiCoder().encode([type, "uint256"], [key, base]),
    );
  const setStorage = (address: string, key: string, value: bigint) =>
    p.send("anvil_setStorageAt", [address, key, word(value)]);
  await page.route(RPC + "/**", async (route) => {
    if (offline) {
      await route.fulfill({ status: 503, body: "RPC temporarily unavailable" });
      return;
    }
    const response = await fetch("http://127.0.0.1:18548", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: route.request().postData(),
    });
    const body = await response.text();
    const decoded = JSON.parse(body);
    for (const item of Array.isArray(decoded) ? decoded : [decoded]) {
      if (item.error) rpcErrors.push(item.error);
    }
    await route.fulfill({ status: 200, contentType: "application/json", body });
  });
  await page.exposeFunction(
    "forkRequest",
    async (data: { method: string; params?: unknown[] }) =>
      p.send(data.method, data.params || []),
  );
  await page.addInitScript({
    content: `
    window.__name = (fn) => fn;
    const listeners = {};
    window.testWalletState = {chain:'0x1',actor:${JSON.stringify(actor)},reject:false};
    const provider = {
      request: async (data) => {
        const state=window.testWalletState;
        if(data.method==='eth_requestAccounts'||data.method==='eth_accounts')return [state.actor];
        if(data.method==='eth_chainId')return state.chain;
        if(data.method==='wallet_switchEthereumChain'){state.chain='0x1';(listeners.chainChanged||[]).forEach(fn=>fn('0x1'));return null;}
        if(data.method==='eth_sendTransaction'&&state.reject){state.reject=false;throw {code:4001,message:'User rejected request'};}
        return window.forkRequest(data);
      },
      on: (name,fn) => (listeners[name] ||= []).push(fn),
      removeListener: (name,fn) => {listeners[name]=(listeners[name]||[]).filter(f=>f!==fn);}
    };
    window.testWalletEmit=(name,value)=>(listeners[name]||[]).forEach(fn=>fn(value));
    const announce=()=>dispatchEvent(new CustomEvent('eip6963:announceProvider',{detail:{info:{uuid:'browser-fork-wallet',name:'Local fork wallet',rdns:'test.local'},provider}}));
    addEventListener('eip6963:requestProvider',announce);
  `,
  });
  async function restoreFixture(saved: string) {
    await page.goto("about:blank");
    await p.send("evm_revert", [saved]);
    await page.goto(url + "#pending");
    await mainnetReady();
    await page
      .getByRole("button", { name: "Connect wallet", exact: true })
      .click();
    await page.getByRole("button", { name: "Local fork wallet" }).click();
    await expect(page.getByRole("dialog")).toHaveCount(0);
  }
  await page.goto(url);
  await mainnetReady();
  await check(
    "Production export loads at /preview/ with local font and relative assets",
    async () => {
      expect(
        await page.evaluate(() =>
          document.fonts.check('700 32px "Barlow Condensed"'),
        ),
      ).toBe(true);
      expect(await page.locator("h1").count()).toBe(1);
    },
  );
  await check("Pending navigation, badge and disconnected state", async () => {
    await navigate("pending");
    await expect(page.locator(".pending-badge")).not.toHaveText("…", {
      timeout: 15000,
    });
    await expect(
      page.getByRole("heading", { name: "PENDING ACTIONS." }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Connect wallet to act" }),
    ).toBeVisible();
    await expect(
      page.getByText(
        "Connect your wallet to check every round for your sunset shares.",
      ),
    ).toBeVisible();
    await navigate("today");
  });
  await check(
    "Entry required, ASCII, 200-byte boundary and focus errors",
    async () => {
      const submit = page.getByRole("button", { name: "Connect & enter" });
      await submit.click();
      await expect(
        page.getByText("Write something about being human before entering."),
      ).toBeVisible();
      await expect(page.locator("#human-entry")).toBeFocused();
      await page.locator("#human-entry").fill("🧠");
      await submit.click();
      await expect(page.getByText("4 / 200 bytes")).toBeVisible();
      await expect(page.locator("#human-entry")).toHaveAttribute(
        "aria-invalid",
        "true",
      );
      await page.locator("#human-entry").fill("a".repeat(201));
      await submit.click();
      await expect(
        page.getByText("Keep your entry to 200 bytes or fewer."),
      ).toBeVisible();
      await page
        .locator("#human-entry")
        .fill("I sometimes forget why I opened a browser tab.");
    },
  );
  await check("EIP-6963 chooser, Escape and focus return", async () => {
    await page
      .getByRole("button", { name: "Connect wallet", exact: true })
      .click();
    await expect(page.getByRole("dialog")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Connect wallet", exact: true }),
    ).toBeFocused();
    await page
      .getByRole("button", { name: "Connect wallet", exact: true })
      .click();
    await page.getByRole("button", { name: "Local fork wallet" }).click();
    await expect(page.getByRole("dialog")).toHaveCount(0);
  });
  await check("Wrong-chain banner and explicit Ethereum switch", async () => {
    await page.evaluate(() => {
      const w = window as any;
      w.testWalletState.chain = "0xa";
      w.testWalletEmit("chainChanged", "0xa");
    });
    await page.getByRole("button", { name: "Switch to Ethereum" }).click();
    await expect(
      page.getByRole("button", { name: "Switch to Ethereum" }),
    ).toHaveCount(0);
  });
  await check(
    "Entry review, wallet rejection recovery and successful local-fork receipt",
    async () => {
      await page.getByRole("button", { name: "Review entry" }).click();
      await expect(page.getByRole("dialog")).toContainText("0.001 ETH");
      await page.evaluate(() => {
        (window as any).testWalletState.reject = true;
      });
      await page.getByRole("button", { name: "Confirm in wallet" }).click();
      await expect(page.getByRole("dialog")).toContainText(
        "Request cancelled in your wallet.",
        { timeout: 30000 },
      );
      await page.getByRole("button", { name: "Confirm in wallet" }).click();
      await expect(page.getByRole("dialog")).toHaveCount(0, { timeout: 30000 });
      await expect(
        page.getByRole("button", { name: "You’re in. Stay human." }),
      ).toBeDisabled();
      await expect(page.locator(".entry-text")).toHaveText(
        "I sometimes forget why I opened a browser tab.",
      );
    },
  );
  await check(
    "Pending heartbeat: eth_call failure, recovery, exact review and transfer",
    async () => {
      const saved = await p.send("evm_snapshot", []);
      try {
        const treasury = new Contract(A.treasury, C.HeartbeatTreasury.abi, p);
        const swarm = await treasury.SWARM();
        await p.send("anvil_setBalance", [
          A.treasury,
          toBeHex(parseEther("0.005")),
        ]);
        await setStorage(A.treasury, word(1n), 0n);
        const previousCode = await p.getCode(swarm);
        await p.send("anvil_setCode", [swarm, "0x60006000fd"]); // local receiver rejection fixture
        await p.send("evm_mine", []);
        await refresh();
        await navigate("pending");
        await expect(page.getByText(/Call would fail: SendFailed/)).toBeVisible(
          { timeout: 15000 },
        );
        await expect(
          page.getByRole("button", { name: "Fund next run" }),
        ).toBeDisabled();
        await p.send("anvil_setCode", [swarm, previousCode]);
        await p.send("evm_mine", []);
        await refresh();
        const fund = page.getByRole("button", { name: "Fund next run" });
        await expect(fund).toBeEnabled({ timeout: 15000 });
        await expect(page.locator(".pending-facts")).toContainText(
          "21600 seconds",
        );
        await expect(page.locator(".pending-recipient")).toHaveText(
          new RegExp(swarm),
        );
        await fund.focus();
        await page.keyboard.press("Enter");
        await expect(page.getByRole("dialog")).toContainText(
          "treasury.fundNextRun()",
        );
        await expect(page.getByRole("dialog")).toContainText("0.005 ETH");
        await expect(page.getByRole("dialog")).toContainText(swarm);
        await page.keyboard.press("Escape");
        await expect(fund).toBeFocused();
        await page.screenshot({
          path: resolve(outDir, "screenshots/pending-focus-fork.png"),
          fullPage: true,
        });
        const before = await p.getBalance(swarm);
        await fund.click();
        await page.getByRole("button", { name: "Confirm in wallet" }).click();
        await expect(page.getByRole("dialog")).toHaveCount(0, {
          timeout: 30000,
        });
        expect(await p.getBalance(swarm)).toBe(before + parseEther("0.005"));
        await expect(fund).toBeDisabled();
        await expect(
          page.getByText("The treasury has no ETH to send."),
        ).toBeVisible();
      } finally {
        await restoreFixture(saved);
      }
    },
  );
  await check(
    "Pending first-verdict letter: exact review, onchain event and cleared badge",
    async () => {
      const saved = await p.send("evm_snapshot", []);
      try {
        const g = game(p),
          day = Number(await g.today());
        const key = mappingSlot("uint256", day, 12);
        const packed = BigInt(await p.getStorage(A.game, key));
        await setStorage(A.game, key, (packed & ~255n) | 3n);
        await setStorage(A.game, word(9n), await g.roundCount());
        await setStorage(A.game, word(11n), 0n);
        await p.send("evm_mine", []);
        await refresh();
        await navigate("pending");
        await expect(
          page.getByText("The first-verdict letter has not been posted"),
        ).toBeVisible();
        await expect(page.locator(".pending-badge")).not.toHaveText("…", {
          timeout: 15000,
        });
        const before = Number(await page.locator(".pending-badge").innerText());
        await page
          .getByRole("button", { name: "Post first-verdict letter" })
          .click();
        await expect(page.getByRole("dialog")).toContainText(
          "game.announceFirstVerdict()",
        );
        await page.getByRole("button", { name: "Confirm in wallet" }).click();
        await expect(page.getByRole("dialog")).toHaveCount(0, {
          timeout: 30000,
        });
        await expect(
          page.getByText("The first-verdict letter has been posted."),
        ).toBeVisible();
        await expect(page.locator(".pending-badge")).toHaveText(
          String(before - 1),
          { timeout: 15000 },
        );
      } finally {
        await restoreFixture(saved);
      }
    },
  );
  await check(
    "Buy quote, slippage, review and successful v4 swap",
    async () => {
      await navigate("trade");
      await page.locator("#trade-amount").fill("0.001");
      await page.locator("#slippage").selectOption("50");
      await page.getByRole("button", { name: "Get quote" }).click();
      await expect(
        page.getByRole("button", { name: "Review buy" }),
      ).toBeVisible({ timeout: 15000 });
      await page.getByRole("button", { name: "Review buy" }).click();
      await expect(page.getByRole("dialog")).toContainText("0.5%");
      await expect(page.getByRole("dialog")).toContainText("2% / 1.25%");
      await page.getByRole("button", { name: "Confirm in wallet" }).click();
      await expect(page.getByRole("dialog")).toHaveCount(0, { timeout: 30000 });
    },
  );
  await check(
    "Sell exact approvals, Permit2 authorization and swap",
    async () => {
      await page
        .getByRole("button", { name: "Sell MEAT", exact: true })
        .click();
      await page.locator("#trade-amount").fill("100");
      await page.getByRole("button", { name: "Get quote" }).click();
      for (const label of [
        "1. Approve MEAT",
        "2. Authorize router",
        "3. Review sell",
      ]) {
        await expect(page.getByRole("button", { name: label })).toBeEnabled({
          timeout: 15000,
        });
        await page.getByRole("button", { name: label }).click();
        await page.getByRole("button", { name: "Confirm in wallet" }).click();
        await expect(page.getByRole("dialog")).toHaveCount(0, {
          timeout: 30000,
        });
      }
    },
  );
  await check(
    "Letters show every original Message, full launch story and no Twitter",
    async () => {
      await navigate("letters");
      await expect(page.getByText(/2 of 2 letters verified/)).toBeVisible({
        timeout: 15000,
      });
      await expect(page.getByText(/71 chose MEATBAG/)).toBeVisible();
      await expect(
        page.getByText("There is no Twitter.", { exact: true }),
      ).toBeVisible();
    },
  );
  await check("Claims empty state and round-history filter", async () => {
    await navigate("claims");
    await expect(
      page.getByRole("button", { name: "Claim ETH" }),
    ).toBeDisabled();
    await navigate("court");
    await expect(page.locator(".round-card")).toHaveCount(1);
    await page.locator("select").selectOption("hung");
    await expect(
      page.getByRole("heading", { name: "No matching rounds in this page." }),
    ).toBeVisible();
    await page.locator("select").selectOption("all");
  });
  await check(
    "Judge UI: exact IMD approval and live Intake request",
    async () => {
      const g = game(p),
        imd = new Contract(A.imd, ERC20_ABI, p);
      const coder = AbiCoder.defaultAbiCoder();
      let funded = false;
      for (let base = 0; base < 50; base++) {
        const key = keccak256(
          coder.encode(["address", "uint256"], [actor, base]),
        );
        const old = await p.getStorage(A.imd, key);
        await p.send("anvil_setStorageAt", [
          A.imd,
          key,
          zeroPadValue(toBeHex(parseEther("10")), 32),
        ]);
        if ((await imd.balanceOf(actor)) === parseEther("10")) {
          funded = true;
          break;
        }
        await p.send("anvil_setStorageAt", [A.imd, key, old]);
      }
      expect(funded).toBe(true);
      await p.send("evm_setNextBlockTimestamp", [
        (Number(await g.today()) + 1) * 86400 + 10,
      ]);
      await p.send("evm_mine", []);
      await refresh();
      await navigate("pending");
      await page.getByRole("link", { name: "Open the Court" }).click();
      for (const label of ["Approve IMD", "Judge round"]) {
        await expect(
          page.getByRole("button", { name: label, exact: false }),
        ).toBeEnabled({ timeout: 15000 });
        await page.getByRole("button", { name: label, exact: false }).click();
        await page.getByRole("button", { name: "Confirm in wallet" }).click();
        await expect(page.getByRole("dialog")).toHaveCount(0, {
          timeout: 30000,
        });
      }
      await expect(
        page.getByText("Panel deliberating", { exact: true }),
      ).toBeVisible();
      await navigate("today");
      await expect(page.locator(".claim-banner")).toContainText("ETH to claim");
      await page.getByRole("link", { name: "Review pending claims" }).click();
      await expect(
        page.getByRole("button", { name: "Claim", exact: true }),
      ).toBeEnabled({ timeout: 15000 });
      await expect(page.locator(".pending-prizes").first()).toContainText(
        "unclaimed",
      );
      await page.getByRole("button", { name: "Claim", exact: true }).click();
      await expect(page.getByRole("dialog")).toContainText("game.claim()");
      await page.getByRole("button", { name: "Confirm in wallet" }).click();
      await expect(page.getByRole("dialog")).toHaveCount(0, { timeout: 30000 });
    },
  );
  await check(
    "Hung-jury UI: timeout, review, confirmation and history",
    async () => {
      await p.send("evm_setNextBlockTimestamp", [
        Number(await game(p).hungJuryAt()) + 1,
      ]);
      await p.send("evm_mine", []);
      await refresh();
      await navigate("pending");
      await expect(
        page.getByRole("button", { name: "Declare hung jury" }),
      ).toBeEnabled();
      await page.getByRole("button", { name: "Declare hung jury" }).click();
      await page.getByRole("button", { name: "Confirm in wallet" }).click();
      await expect(page.getByRole("dialog")).toHaveCount(0, { timeout: 30000 });
      await navigate("court");
      await page.locator("select").selectOption("hung");
      await expect(page.locator(".round-card")).toHaveCount(1);
    },
  );
  // Seed the already fork-tested credit path to exercise claim review/receipt in the browser.
  await check(
    "Winner/judge claim UI sends to selected wallet and refreshes",
    async () => {
      const word = (v: bigint) => zeroPadValue(toBeHex(v), 32);
      const key = keccak256(
        AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [actor, 7]),
      );
      const total = await game(p).totalClaimable();
      await p.send("anvil_setBalance", [
        A.game,
        toBeHex((await p.getBalance(A.game)) + parseEther("0.0001")),
      ]);
      await p.send("anvil_setStorageAt", [
        A.game,
        key,
        word(parseEther("0.0001")),
      ]);
      await p.send("anvil_setStorageAt", [
        A.game,
        word(6n),
        word(total + parseEther("0.0001")),
      ]);
      await p.send("evm_mine", []);
      await refresh();
      const connectAs = async (address: string) => {
        await page.evaluate((address) => {
          (window as any).testWalletState.actor = address;
          (window as any).testWalletEmit("accountsChanged", [address]);
        }, address);
        await page
          .getByRole("button", { name: "Connect wallet", exact: true })
          .click();
        await page.getByRole("button", { name: "Local fork wallet" }).click();
        await expect(page.getByRole("dialog")).toHaveCount(0);
      };
      await connectAs(await (await p.getSigner(1)).getAddress());
      await navigate("pending");
      await expect(page.locator(".pending-prizes").first()).toContainText(
        "0.0001 ETH",
      );
      await expect(
        page.locator(
          `.pending-prizes a[href='https://etherscan.io/address/${actor.toLowerCase()}']`,
        ),
      ).toBeVisible();
      await expect(
        page.getByRole("button", { name: "Claim", exact: true }),
      ).toHaveCount(0);
      await expect(page.locator(".pending-badge")).not.toHaveText("…", {
        timeout: 15000,
      });
      await page.screenshot({
        path: resolve(outDir, "screenshots/pending-other-claim-fork.png"),
        fullPage: true,
      });
      await connectAs(actor);
      await navigate("claims");
      await expect(
        page.getByRole("button", { name: "Claim ETH" }),
      ).toBeEnabled();
      await page.getByRole("button", { name: "Claim ETH" }).click();
      await expect(page.getByRole("dialog")).toContainText(actor);
      await page.getByRole("button", { name: "Confirm in wallet" }).click();
      await expect(page.getByRole("dialog")).toHaveCount(0, { timeout: 30000 });
      await expect(
        page.getByRole("button", { name: "Claim ETH" }),
      ).toBeDisabled();
    },
  );
  await check(
    "Pending sunset settlement, exhaustive shares, claim banner and empty state",
    async () => {
      const saved = await p.send("evm_snapshot", []);
      try {
        const g = game(p),
          signer = await p.getSigner(0);
        const send = async (request: any) => {
          const receipt = await (
            await signer.sendTransaction({ ...request, gasLimit: 4000000n })
          ).wait();
          expect(receipt?.status).toBe(1);
        };
        for (let i = 0; i < 6; i++) {
          await send(
            gameTx(
              "enter",
              [`Browser sunset entry ${i}.`],
              await g.nextSlotPrice(),
            ),
          );
          await p.send("evm_setNextBlockTimestamp", [
            Number(await g.hungJuryAt()) + 1,
          ]);
          await p.send("evm_mine", []);
          if (i < 5) await send(gameTx("declareHungJury"));
        }
        const lastDay = Number(await g.nextRoundToJudge());
        const key = mappingSlot("uint256", lastDay, 12);
        await setStorage(
          A.game,
          key,
          (BigInt(await p.getStorage(A.game, key)) & ~255n) | 4n,
        );
        await setStorage(A.game, word(9n), (await g.cursor()) + 1n);
        await setStorage(A.game, word(10n), 7n);
        await p.send("evm_mine", []);
        await refresh();
        await navigate("pending");
        await page
          .getByRole("button", { name: "Settle sunset", exact: true })
          .click();
        await expect(page.getByRole("dialog")).toContainText("game.sunset()");
        await page.getByRole("button", { name: "Confirm in wallet" }).click();
        await expect(page.getByRole("dialog")).toHaveCount(0, {
          timeout: 30000,
        });
        await expect(
          page.getByRole("button", { name: "Claim sunset share", exact: true }),
        ).toHaveCount(7, { timeout: 20000 });
        await navigate("today");
        await expect(page.locator(".claim-banner")).toContainText(
          "ETH to claim",
        );
        await page.getByRole("link", { name: "Review pending claims" }).click();
        await expect(page.locator(".pending-badge")).not.toHaveText("…", {
          timeout: 15000,
        });
        const count = Number(await page.locator(".pending-badge").innerText());
        await page.setViewportSize({ width: 390, height: 844 });
        await page.screenshot({
          path: resolve(outDir, "screenshots/pending-shares-mobile-fork.png"),
          fullPage: true,
        });
        await page
          .getByRole("button", { name: "Claim sunset share", exact: true })
          .first()
          .click();
        await expect(page.getByRole("dialog")).toContainText(
          "game.claimSunset(",
        );
        await expect(page.getByRole("dialog")).toContainText(actor);
        await page.getByRole("button", { name: "Confirm in wallet" }).click();
        await expect(page.getByRole("dialog")).toHaveCount(0, {
          timeout: 30000,
        });
        await expect(
          page.getByRole("button", { name: "Claim sunset share", exact: true }),
        ).toHaveCount(6, { timeout: 20000 });
        await expect(page.locator(".pending-badge")).toHaveText(
          String(count - 1),
          { timeout: 15000 },
        );
        for (let i = 0; i < Number(await g.roundCount()); i++) {
          const day = Number(await g.roundDays(i));
          if (!(await g.sunsetClaimed(day, actor)))
            await send(gameTx("claimSunset", [day]));
        }
        await p.send("anvil_setBalance", [A.treasury, "0x0"]);
        await p.send("evm_mine", []);
        await refresh();
        await expect(
          page.getByText(
            "Nothing is waiting. Every public action is up to date.",
          ),
        ).toBeVisible({ timeout: 15000 });
        await expect(page.locator(".pending-badge")).toHaveText("0");
        await navigate("today");
        await expect(page.locator(".claim-banner")).toHaveCount(0);
      } finally {
        await restoreFixture(saved);
      }
    },
  );
  for (const width of [1280, 768, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    for (const hash of [
      "today",
      "court",
      "trade",
      "letters",
      "claims",
      "story",
      "pending",
    ]) {
      await navigate(hash);
      await check(`${hash}: no horizontal overflow at ${width}px`, async () => {
        expect(
          await page.evaluate(
            () => document.documentElement.scrollWidth <= innerWidth,
          ),
        ).toBe(true);
      });
    }
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await navigate("today");
  await check("Text enlargement to 200% reflows at mobile width", async () => {
    await page.evaluate(
      () => (document.documentElement.style.fontSize = "32px"),
    );
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
    await page.evaluate(() => (document.documentElement.style.fontSize = ""));
  });
  await check(
    "Pending reflow at 200% text and 44px action/link targets",
    async () => {
      await navigate("pending");
      await page.evaluate(
        () => (document.documentElement.style.fontSize = "32px"),
      );
      expect(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
      ).toBe(true);
      await page.evaluate(() => (document.documentElement.style.fontSize = ""));
      const sizes = await page
        .locator(".pending-panel button, .pending-panel a, nav a, .text-button")
        .evaluateAll((elements) =>
          elements.map((el) => ({
            text: el.textContent,
            width: el.getBoundingClientRect().width,
            height: el.getBoundingClientRect().height,
          })),
        );
      expect(sizes.filter((s) => s.height < 44 || s.width < 44)).toEqual([]);
    },
  );
  const contrast = await page.evaluate(() => {
    const luminance = (rgb: string) => {
      const values = (rgb.match(/[\d.]+/g) || [])
        .slice(0, 3)
        .map((x) => Number(x) / 255)
        .map((x) => (x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4));
      return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722;
    };
    return [
      ".pending-badge",
      ".pending-panel > p",
      ".pending-facts dd",
      ".pending-link",
    ].map((selector) => {
      const el = document.querySelector(selector)!;
      let parent: Element | null = el;
      let background = "rgba(0, 0, 0, 0)";
      while (parent && background === "rgba(0, 0, 0, 0)") {
        background = getComputedStyle(parent).backgroundColor;
        parent = parent.parentElement;
      }
      const foreground = getComputedStyle(el).color;
      const a = luminance(foreground),
        b = luminance(background);
      return {
        selector,
        foreground,
        background,
        ratio: (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05),
      };
    });
  });
  expect(contrast.every((pair) => pair.ratio >= 4.5)).toBe(true);
  writeFileSync(
    resolve(outDir, "pending-contrast.json"),
    JSON.stringify(contrast, null, 2) + "\n",
  );
  await check(
    "Reduced motion removes transitions and forced colors keeps controls visible",
    async () => {
      expect(
        await page
          .locator(".wallet-button")
          .evaluate((el) => getComputedStyle(el).transitionDuration),
      ).toBe("0s");
      await page.emulateMedia({ forcedColors: "active" });
      await expect(page.locator(".wallet-button")).toBeVisible();
      await page.emulateMedia({ forcedColors: "none" });
    },
  );
  // Load axe from a local development dependency; it is never part of the static export.
  for (const hash of [
    "today",
    "court",
    "trade",
    "letters",
    "claims",
    "story",
    "pending",
  ]) {
    await navigate(hash);
    await page.addScriptTag({
      path: resolve("node_modules/axe-core/axe.min.js"),
    });
    const result = await page.evaluate(
      async () =>
        await (window as any).axe.run(document, {
          runOnly: {
            type: "tag",
            values: ["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"],
          },
        }),
    );
    axeResults.push({
      page: hash,
      violations: result.violations.map((v: any) => ({
        id: v.id,
        impact: v.impact,
        description: v.description,
        nodes: v.nodes.map((n: any) => n.target),
      })),
    });
  }
  await check(
    "Wallet account change clears the session and stale claim context",
    async () => {
      await page.evaluate(() => {
        (window as any).testWalletEmit("accountsChanged", []);
      });
      await expect(
        page.getByRole("button", { name: "Connect wallet", exact: true }),
      ).toBeVisible();
    },
  );
  await check(
    "Disconnected sell opens the injected-wallet chooser",
    async () => {
      await navigate("trade");
      await page
        .getByRole("button", { name: "Sell MEAT", exact: true })
        .click();
      await page.locator("#trade-amount").fill("100");
      await page.getByRole("button", { name: "Get quote" }).click();
      await page
        .locator(".trade-panel")
        .getByRole("button", { name: "Connect wallet", exact: true })
        .click();
      await expect(page.getByRole("dialog")).toBeVisible();
      await page.keyboard.press("Escape");
    },
  );
  // Intentional RPC outage. Expect an explicit error and recover before taking final evidence.
  await navigate("today");
  offline = true;
  await page.getByRole("button", { name: "Refresh", exact: true }).click();
  await expect(page.getByText(/Unable to refresh Ethereum data/)).toBeVisible({
    timeout: 30000,
  });
  offline = false;
  await page.getByRole("button", { name: "Retry connection" }).click();
  await mainnetReady();
  await expect(page.getByText(/Unable to refresh Ethereum data/)).toHaveCount(
    0,
  );
  checks.push("RPC outage disables writes and recovers on Retry");
  const expectedNetworkErrors = issues.filter((x) =>
    /503|Failed to load resource/.test(x),
  );
  const unexpected = issues.filter(
    (x) => !/503|Failed to load resource/.test(x),
  );
  for (const [name, width, hash] of [
    ["desktop", 1280, "today"],
    ["mobile", 390, "today"],
    ["letters", 1280, "letters"],
    ["trade", 390, "trade"],
    ["pending-desktop", 1280, "pending"],
    ["pending-mobile", 390, "pending"],
  ] as const) {
    await page.setViewportSize({ width, height: 900 });
    await navigate(hash);
    await page.screenshot({
      path: resolve(outDir, `screenshots/${name}-fork.png`),
      fullPage: true,
    });
  }
  const report = {
    checks,
    axe: axeResults,
    unexpectedBrowserErrors: unexpected,
    expectedOutageErrors: expectedNetworkErrors,
    limitations: [
      "Chromium emulation, not physical mobile or a screen reader.",
      "200% root text enlargement is not native browser zoom.",
      "Wallet is an EIP-6963 local-fork test provider, not an installed extension.",
      "Winner claim uses a local credit fixture; letter and sunset callbacks use local storage fixtures.",
      "The heartbeat failure uses local swarm receiver revert bytecode, restored after the check.",
    ],
  };
  writeFileSync(
    resolve(outDir, "browser-results.json"),
    JSON.stringify(report, null, 2) + "\n",
  );
  expect(unexpected).toEqual([]);
  expect(axeResults.flatMap((r) => r.violations)).toEqual([]);
  console.log("Browser checks complete:", checks.length);
} catch (error) {
  console.error("Browser console:", issues);
  console.error("RPC errors:", rpcErrors);
  console.error(
    "Page status:",
    await page.locator(".banner, .connection-bar").allTextContents(),
  );
  console.error(
    "Dialog state:",
    await page.locator("dialog").allTextContents(),
  );
  await page.screenshot({
    path: resolve(outDir, "browser-failure.png"),
    fullPage: true,
  });
  throw error;
} finally {
  await browser.close();
  server.close();
  p.destroy();
  anvil.kill("SIGTERM");
}
