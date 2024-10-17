import hre from "hardhat";

import SnedPayment from "./modules/SnedPayment";

async function main() {
  try {
    const parameters: any = {
      networkId: 42161,
    };

    const result = await hre.ignition.deploy(SnedPayment, { parameters });

    if (result.snedPayment?.address) {
      console.log("MyContract deployed at:", result.snedPayment.address);
    } else {
      console.error("Deployment failed or contract address not available");
    }
  } catch (error) {
    console.error("Deployment error:", error);
    process.exitCode = 1;
  }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
