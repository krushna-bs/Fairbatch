import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const rpcUrl = process.env.BASE_SEPOLIA_RPC_URL || "";
const deployerPrivateKey = process.env.BASE_SEPOLIA_DEPLOYER_PRIVATE_KEY || "";

const config: HardhatUserConfig = {
  solidity: "0.8.24",
  networks: {
    baseSepolia: {
      type: "http",
      url: rpcUrl,
      chainId: 84532,
      accounts: deployerPrivateKey ? [deployerPrivateKey] : [],
    },
  },
};

export default config;
