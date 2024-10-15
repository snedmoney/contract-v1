import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const defaultAddress = "0x582de465be2e91eb8ec5939fdb94ac770a5a0920";

const SnedPaymentModule = buildModule("SnedPaymentModule", (m) => {
  const owner = m.getParameter("owner", defaultAddress);
  const swapRouter = m.getParameter("swapRouter", defaultAddress);
  const wormholeBridge = m.getParameter("wormholeBridge", defaultAddress);

  const snedPayment = m.contract("SnedPayment", [
    owner,
    swapRouter,
    wormholeBridge,
  ]);

  return { snedPayment };
});

export default SnedPaymentModule;
