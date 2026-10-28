```ts
import { ethers, network } from "hardhat";

async function main() {
  if (network.name !== "baseSepolia") {
    throw new Error(
      `Wrong network: ${network.name}. Deployment is restricted to Base Sepolia.`
    );
  }

  const [deployer] = await ethers.getSigners();

  console.log("Deploying from:", deployer.address);
  console.log("Network:", network.name);

  const TestUSDC = await ethers.getContractFactory("TestUSDC");
  const testUSDC = await TestUSDC.deploy();
  await testUSDC.waitForDeployment();

  const testUSDCAddress = await testUSDC.getAddress();

  console.log("TestUSDC deployed to:", testUSDCAddress);
  console.log(
    "TestUSDC deployment tx:",
    testUSDC.deploymentTransaction()?.hash
  );

  const FairBatch = await ethers.getContractFactory("FairBatch");
  const fairBatch = await FairBatch.deploy(testUSDCAddress);
  await fairBatch.waitForDeployment();

  const fairBatchAddress = await fairBatch.getAddress();

  console.log("FairBatch deployed to:", fairBatchAddress);
  console.log(
    "FairBatch deployment tx:",
    fairBatch.deploymentTransaction()?.hash
  );

  console.log("\nDeployment complete.");
  console.log("Save these addresses for the frontend:");
  console.log("TESTUSDC_ADDRESS =", testUSDCAddress);
  console.log("FAIRBATCH_ADDRESS =", fairBatchAddress);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
```
