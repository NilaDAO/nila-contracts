require("dotenv").config();
require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-ledger");
require("@openzeppelin/hardhat-upgrades");
require("hardhat-contract-sizer");

console.log('process.env.POLYGONSCAN_API_KEY,', process.env.POLYGONSCAN_API_KEY)
/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.25",
    settings: {
      viaIR: true,
      optimizer: { enabled: true, runs: 1 }, // <— for smallest bytecode
      metadata: { bytecodeHash: "none" },
      evmVersion: "paris",
    },
  },
  contractSizer: {
    runOnCompile: false,
    strict: false,
  },
  mocha: { timeout: 120000 },
  networks: {
    polygon: {
      // e.g. Alchemy / Infura / other RPC
      url: "https://polygon-mainnet.g.alchemy.com/v2/rJNzyTUoG75bsNITFKIw4d6uIHIuGWS2",
      accounts: [
        process.env.OWNER_PRIVATE_KEY,        // 0
        process.env.MASTER_PRIVATE_KEY,        // 0
        process.env.UNIONLEADER_PRIVATE_KEY,   // 1
        process.env.INVESTOR_PRIVATE_KEY       // 2
      ],
      chainId: 137,
      //gasPrice: 1000_000_000_000, // 600 gwei
    },
    // Polygon mainnet — signer is the Ledger at FX_OWNER_ADDRESS.
    // Ledger must be unlocked with the Ethereum app open before running.
    "polygon-ledger": {
      url: "https://polygon-mainnet.g.alchemy.com/v2/rJNzyTUoG75bsNITFKIw4d6uIHIuGWS2",
      chainId: 137,
      ledgerAccounts: [
        "0x7687dd5c8ce4e42ebdd4a94ccd4fc9c4a7f18528", // FX_OWNER_ADDRESS — holds ONLY_OWNER on FxPool
      ],
    },
    amoy: {
      chainId: 80002,
      url: "https://polygon-amoy.g.alchemy.com/v2/rJNzyTUoG75bsNITFKIw4d6uIHIuGWS2",
      accounts: [
        process.env.OWNER_PRIVATE_KEY,        // 0
        process.env.MASTER_PRIVATE_KEY,        // 0
        process.env.UNIONLEADER_PRIVATE_KEY,   // 1
        process.env.INVESTOR_PRIVATE_KEY       // 2
      ],
    }
  },
      etherscan: {
        apiKey: {
          amoy: process.env.POLYGONSCAN_API_KEY,
          polygon: process.env.ETHERSCAN_API_KEY
        }
  }
    }