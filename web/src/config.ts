import contracts from "./generated/contracts.json";
import network from "../provenance/network.json";
import { AbiCoder, keccak256, ZeroAddress } from "ethers";
export const RPC = "https://ethereum-rpc.publicnode.com";
export const CHAIN_ID = 1;
export const START_BLOCK = 26155857;
export const SOURCE_COMMIT = "daa8dcc2fe3dfdf83aba9b16d7d9a8214d259364";
export const C = contracts;
export const A = {
  token: C.MeatbagToken.address,
  hook: C.MeatbagHook.address,
  game: C.MeatbagGame.address,
  herald: C.MeatbagHerald.address,
  treasury: C.HeartbeatTreasury.address,
  imd: network.network.pairToken.address,
  ...network.network.uniswapV4,
};
export const TO = "0x200e710acaa6a93bbc77146026328c40f1d60fb1";
export const POOL = [ZeroAddress, A.token, 12500, 60, A.hook] as const;
export const POOL_TYPE =
  "tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
export const POOL_ID = keccak256(
  AbiCoder.defaultAbiCoder().encode([POOL_TYPE], [POOL]),
);
export const EXPLORER = "https://etherscan.io";
export const ORIGIN_REQUEST = "ad6116f0-4e28-463c-853a-54508514c0a8";
export const oracleUrl = (id: string) =>
  `https://api.imd.fun/oracle/requests/${id}`;
export const ERC20_ABI = [
  "function balanceOf(address) view returns(uint256)",
  "function allowance(address,address) view returns(uint256)",
  "function approve(address,uint256) returns(bool)",
];
export const PERMIT_ABI = [
  "function allowance(address,address,address) view returns(uint160 amount,uint48 expiration,uint48 nonce)",
  "function approve(address token,address spender,uint160 amount,uint48 expiration)",
];
export const ROUTER_ABI = [
  "function execute(bytes commands,bytes[] inputs,uint256 deadline) payable",
];
export const QUOTER_ABI = [
  `function quoteExactInputSingle(tuple(${POOL_TYPE} poolKey,bool zeroForOne,uint128 exactAmount,bytes hookData) params) returns(uint256 amountOut,uint256 gasEstimate)`,
];

// IMD encodes UUID bytes in the leading 16 bytes, right-padded to bytes32.
export function panelRequestUrl(bytes32: string): string | null {
  if (!/^0x[0-9a-fA-F]{32}0{32}$/.test(bytes32)) return null;
  const h = bytes32.slice(2, 34);
  if (/^0+$/.test(h)) return null;
  const uuid = `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  return `https://api.imd.fun/oracle/requests?jobId=${uuid}`;
}
