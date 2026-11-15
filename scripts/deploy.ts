// SPDX-License-Identifier: MIT
import { ethers } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const hre: HardhatRuntimeEnvironment = (globalThis as any).hre;

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);

  // 1. Deploy PaymentSplitter
  const PaymentSplitter = await hre.ethers.getContractFactory("PaymentSplitter");
  const splitter = await PaymentSplitter.deploy();
  await splitter.waitForDeployment();
  console.log("PaymentSplitter deployed to:", await splitter.getAddress());

  // 2. Deploy MockBridge (replace with real bridge address in production)
  const MockBridge = await hre.ethers.getContractFactory("MockBridge");
  const bridge = await MockBridge.deploy();
  await bridge.waitForDeployment();
  console.log("MockBridge deployed to:", await bridge.getAddress());

  // 3. Deploy CrossChainSplitter
  const CrossChainSplitter = await hre.ethers.getContractFactory("CrossChainSplitter");
  const ccSplitter = await CrossChainSplitter.deploy(await bridge.getAddress());
  await ccSplitter.waitForDeployment();
  console.log("CrossChainSplitter deployed to:", await ccSplitter.getAddress());

  // 4. Deploy PaymentRouter
  const PaymentRouter = await hre.ethers.getContractFactory("PaymentRouter");
  const router = await PaymentRouter.deploy(await bridge.getAddress());
  await router.waitForDeployment();
  console.log("PaymentRouter deployed to:", await router.getAddress());

  // 5. Register three sample recipients (60 / 30 / 10 split)
  const recipient1 = "0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496";
  const recipient2 = "0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2";
  const recipient3 = "0xBaA29De16d41f9297d71fF5983bD73A6a6D39Bd9";

  const recips = [
    { account: recipient1, shareBips: 6000 },
    { account: recipient2, shareBips: 3000 },
    { account: recipient3, shareBips: 1000 },
  ];

  const abi = hre.ethers.AbiCoder.defaultAbiCoder();
  const encoded = abi.encode(
    ["tuple(address account,uint256 shareBips)[]"],
    [recips]
  );

  const tx = await splitter.registerRecipients(encoded);
  await tx.wait();
  console.log("Registered 3 recipients on PaymentSplitter");

  console.log("\nDeployment complete.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});