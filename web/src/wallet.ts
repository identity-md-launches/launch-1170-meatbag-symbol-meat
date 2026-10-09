import { useEffect, useState } from "react";
import {
  BrowserProvider,
  getAddress,
  type Eip1193Provider,
  type JsonRpcSigner,
  type TransactionRequest,
} from "ethers";
export type Injected = Eip1193Provider & {
  on?: (event: string, fn: (v: any) => void) => void;
  removeListener?: (event: string, fn: (v: any) => void) => void;
};
export type Wallet = {
  info: { uuid: string; name: string; rdns: string };
  provider: Injected;
};
export type Connection = {
  wallet: Wallet;
  account: string;
  chain: string;
  signer: JsonRpcSigner;
};
export function useWallet() {
  const [wallets, setWallets] = useState<Wallet[]>([]),
    [connection, setConnection] = useState<Connection | null>(null);
  useEffect(() => {
    const announce = (event: Event) => {
      const w = (event as CustomEvent<Wallet>).detail;
      if (!w?.provider?.request || !w.info?.uuid || !w.info.name) return;
      setWallets((old) =>
        old.some((x) => x.info.uuid === w.info.uuid) ? old : [...old, w],
      );
    };
    window.addEventListener("eip6963:announceProvider", announce);
    window.dispatchEvent(new Event("eip6963:requestProvider"));
    return () =>
      window.removeEventListener("eip6963:announceProvider", announce);
  }, []);
  useEffect(() => {
    if (!connection) return;
    const p = connection.wallet.provider;
    // Any account change invalidates the session, quote and account-specific claim view.
    const accounts = () => setConnection(null);
    const chain = (id: string) =>
      setConnection((old) => (old ? { ...old, chain: id } : null));
    p.on?.("accountsChanged", accounts);
    p.on?.("chainChanged", chain);
    p.on?.("disconnect", accounts);
    return () => {
      p.removeListener?.("accountsChanged", accounts);
      p.removeListener?.("chainChanged", chain);
      p.removeListener?.("disconnect", accounts);
    };
  }, [connection?.wallet]);
  async function connect(wallet: Wallet) {
    const accounts = (await wallet.provider.request({
      method: "eth_requestAccounts",
    })) as string[];
    if (!accounts[0])
      throw Error("No wallet account was selected. Try connecting again.");
    const chain = (await wallet.provider.request({
      method: "eth_chainId",
    })) as string;
    const browser = new BrowserProvider(wallet.provider, "any");
    const signer = await browser.getSigner(accounts[0]);
    setConnection({ wallet, account: getAddress(accounts[0]), chain, signer });
  }
  async function switchChain() {
    if (connection)
      await connection.wallet.provider.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: "0x1" }],
      });
  }
  return {
    wallets,
    connection,
    connect,
    switchChain,
    disconnect: () => setConnection(null),
  };
}
export async function sendWalletTransaction(
  c: Connection,
  request: TransactionRequest,
) {
  const [chain, accounts] = await Promise.all([
    c.wallet.provider.request({ method: "eth_chainId" }),
    c.wallet.provider.request({ method: "eth_accounts" }),
  ]);
  if (BigInt(chain as string) !== 1n)
    throw Error("Switch your wallet to Ethereum mainnet, then try again.");
  if ((accounts as string[])[0]?.toLowerCase() !== c.account.toLowerCase())
    throw Error(
      "Your wallet account changed. Connect again before continuing.",
    );
  // Simulate with the wallet's current state before prompting for a signature.
  const gas = await c.signer.estimateGas(request);
  return c.signer.sendTransaction({
    ...request,
    chainId: 1,
    gasLimit: (gas * 120n) / 100n,
  });
}
