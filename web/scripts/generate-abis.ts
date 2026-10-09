import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { keccak256, toUtf8Bytes, JsonRpcProvider } from "ethers";
const root = resolve(process.argv[2] || "..");
const target = resolve(process.argv[3] || ".");
const deployment = JSON.parse(
  readFileSync(resolve(target, "provenance/deployment.json"), "utf8"),
);
function canonical(v: any): string {
  return v === null || typeof v !== "object"
    ? JSON.stringify(v)
    : Array.isArray(v)
      ? "[" + v.map(canonical).join(",") + "]"
      : "{" +
        Object.keys(v)
          .sort()
          .map((k) => JSON.stringify(k) + ":" + canonical(v[k]))
          .join(",") +
        "}";
}
const addresses: Record<string, string> = {
  MeatbagToken: deployment.contracts[0].address,
  MeatbagHook: deployment.contracts[1].address,
  MeatbagGame: "0x70C1b03ccc02905B2ad5683156592418424c787b",
  MeatbagHerald: "0xe5Da3eE7b1B925E66EeAE138962464687c135575",
  HeartbeatTreasury: "0xe24f78c9C1a0BEC4Ec3966d4Bd701d46AC1ac787",
};
const provider = new JsonRpcProvider("https://ethereum-rpc.publicnode.com", 1, {
  staticNetwork: true,
});
if (BigInt(await provider.send("eth_chainId", [])) !== 1n)
  throw Error("Wrong chain");
const block = await provider.getBlockNumber();
const output: Record<string, any> = {};
for (const [name, address] of Object.entries(addresses)) {
  const artifact = JSON.parse(
    readFileSync(resolve(root, `out/${name}.sol/${name}.json`), "utf8"),
  );
  const hash = keccak256(toUtf8Bytes(canonical(artifact.abi))).slice(2);
  const pinned = deployment.contracts.find((c: any) => c.name === name);
  if (pinned && hash !== pinned.abiHash)
    throw Error(`${name} ABI mismatch ${hash} != ${pinned.abiHash}`);
  const code = await provider.getCode(address, block);
  const refs = Object.values(
    artifact.deployedBytecode.immutableReferences || {},
  ).flat() as { start: number; length: number }[];
  let masked = code.slice(2);
  for (const { start, length } of refs)
    masked =
      masked.slice(0, start * 2) +
      "0".repeat(length * 2) +
      masked.slice((start + length) * 2);
  if ("0x" + masked !== artifact.deployedBytecode.object)
    throw Error(`${name}: runtime source mismatch`);
  output[name] = {
    address: address.toLowerCase(),
    abi: artifact.abi,
    abiHash: hash,
    runtimeHash: keccak256(code),
  };
  console.log(
    `${name}: ABI ${hash}, deployed runtime matches accepted source at ${block}`,
  );
}
mkdirSync(resolve(target, "src/generated"), { recursive: true });
writeFileSync(
  resolve(target, "src/generated/contracts.json"),
  JSON.stringify(output, null, 2) + "\n",
);
writeFileSync(
  resolve(target, "provenance/verification.json"),
  JSON.stringify(
    {
      sourceCommit: deployment.sourceCommit,
      block,
      chainId: 1,
      contracts: Object.fromEntries(
        Object.entries(output).map(([n, c]) => [
          n,
          {
            address: c.address,
            abiHash: c.abiHash,
            runtimeHash: c.runtimeHash,
          },
        ]),
      ),
    },
    null,
    2,
  ) + "\n",
);
provider.destroy();
