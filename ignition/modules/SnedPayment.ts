import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const ownerAddress = "0x582de465be2e91eb8ec5939fdb94ac770a5a0920";

type NetworkMap = {
  [key: number]: string;
};

type NetworkWormMap = {
  [key: number]: number;
};

const swapRouterNetworkMap: NetworkMap = {
  42161: "0xe592427a0aece92de3edee1f18e0157c05861564",
};

const wormholeBridgeNetworkMap: NetworkMap = {
  42161: "0x0b2402144bb366a632d14b83f244d2e0e21bd39c",
};

const currentWormChainIdMap: NetworkWormMap = {
  42161: 23,
};

const SnedPaymentModule = buildModule("SnedPaymentModule", (m) => {
  const owner = m.getParameter("owner", ownerAddress);

  const networkId = m.getParameter("networkId") as unknown as number;

  if (!networkId || !swapRouterNetworkMap[networkId]) {
    throw Error("Network id is not available");
  }

  const swapRouter = swapRouterNetworkMap[networkId];

  const wormholeBridge = wormholeBridgeNetworkMap[networkId];

  const currentWormChainId = currentWormChainIdMap[networkId];

  const snedPayment = m.contract("SnedPayment", [
    owner,
    swapRouter,
    wormholeBridge,
    currentWormChainId,
  ]);

  return { snedPayment };
});

export default SnedPaymentModule;
