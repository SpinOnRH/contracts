/**
 * The guard's operators, managed by the deployer (the guard's admin): the
 * keys the senders send with, one per lane. Used by the deploy scripts.
 *
 * The set is the senders' own: SEND_LANES addresses from OPERATOR_MNEMONIC
 * (index 0, 1, …, as the worker derives them), else
 * OPERATOR_ADDRESSES (comma-separated), else OPERATOR_ADDRESS, else the
 * address of OPERATOR_PRIVATE_KEY. Each is made an operator and topped up to
 * OPERATOR_FLOAT_ETH (default 0.01): a node accepts a transaction only if its
 * sender can pay the gas limit at the max fee up front (a 20-trade
 * tradeMany at the guard's 1 gwei cap is about 0.006 ETH); the guard refunds
 * each trade's gas in the same transaction, so the float stays. Operators in
 * the last run's set but no longer in this one are removed. Run again to top
 * the floats up.
 */
import {
  formatEther,
  parseEther,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
  type Account,
  type Chain,
} from "viem";
import { mnemonicToAccount, privateKeyToAccount } from "viem/accounts";

type Setting = (name: string, fallback?: string) => string;

export const operatorAddresses = (setting: Setting): Address[] => {
  const mnemonic = setting("OPERATOR_MNEMONIC", "");
  if (mnemonic) {
    const lanes = Number(setting("SEND_LANES", "1"));
    return Array.from(
      { length: lanes },
      (_, i) => mnemonicToAccount(mnemonic, { addressIndex: i }).address,
    );
  }
  const list =
    setting("OPERATOR_ADDRESSES", "") || setting("OPERATOR_ADDRESS", "");
  if (list) return list.split(",").map((a) => a.trim() as Address);
  const key = setting("OPERATOR_PRIVATE_KEY", "");
  return key ? [privateKeyToAccount(key as Hex).address] : [];
};

export const operatorFloat = (setting: Setting) =>
  parseEther(setting("OPERATOR_FLOAT_ETH", "0.01"));

export async function manageOperators(o: {
  client: PublicClient;
  wallet: WalletClient & { account: Account; chain: Chain };
  guard: Address;
  guardAbi: Abi;
  wanted: Address[];
  previous: Address[];
  floatWei: bigint;
}): Promise<Address[]> {
  const { client, wallet, guard, guardAbi } = o;
  const send = async (request: Promise<Hex>, what: string) => {
    const r = await client.waitForTransactionReceipt({ hash: await request });
    if (r.status !== "success") throw new Error(`${what} reverted`);
  };
  const isOperator = (a: Address) =>
    client.readContract({
      address: guard,
      abi: guardAbi,
      functionName: "isOperator",
      args: [a],
    }) as Promise<boolean>;

  // Every top-up first: the deployer must be able to fund them all, or nothing is sent.
  const balances = await Promise.all(
    o.wanted.map((a) => client.getBalance({ address: a })),
  );
  const topUps = o.wanted.map((a, i) => ({
    a,
    wei: balances[i]! < o.floatWei ? o.floatWei - balances[i]! : 0n,
  }));
  const need = topUps.reduce((t, x) => t + x.wei, 0n);
  const have = await client.getBalance({ address: wallet.account.address });
  if (need > 0n && need + parseEther("0.0005") > have)
    throw new Error(
      `the deployer has ${formatEther(have)} ETH; the operators' floats need ${formatEther(need)} (OPERATOR_FLOAT_ETH ${formatEther(o.floatWei)} each)`,
    );

  for (const { a, wei } of topUps) {
    if (!(await isOperator(a)))
      await send(
        wallet.writeContract({
          address: guard,
          abi: guardAbi,
          functionName: "setOperator",
          args: [a, true],
          chain: wallet.chain,
          account: wallet.account,
        }),
        `setOperator ${a}`,
      );
    if (wei > 0n)
      await send(
        wallet.sendTransaction({
          to: a,
          value: wei,
          chain: wallet.chain,
          account: wallet.account,
        }),
        `float for ${a}`,
      );
    console.log(
      `operator ${a}: on the guard, ${formatEther(wei ? o.floatWei : balances[o.wanted.indexOf(a)]!)} ETH${wei ? ` (topped up ${formatEther(wei)})` : ""}`,
    );
  }
  const wanted = new Set(o.wanted.map((a) => a.toLowerCase()));
  for (const a of o.previous)
    if (!wanted.has(a.toLowerCase()) && (await isOperator(a))) {
      await send(
        wallet.writeContract({
          address: guard,
          abi: guardAbi,
          functionName: "setOperator",
          args: [a, false],
          chain: wallet.chain,
          account: wallet.account,
        }),
        `remove ${a}`,
      );
      console.log(`operator ${a}: removed (no longer in the set)`);
    }
  return o.wanted;
}
