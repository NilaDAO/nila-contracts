// npx hardhat run scripts/TOMAINNET/set_nin_mintredeem_roles.js --network polygon
const { ethers } = require("hardhat");

const ninAddress  = process.env.NIN_MAIN;       // NIN token
const fxPoolProxy = process.env.FX_MAIN;     // NilaFxPool proxy

async function main() {
    const [signer] = await ethers.getSigners();

    const nin = await ethers.getContractAt("NilaNIN", ninAddress);

    // Read role IDs from contract
    const MINTER_ROLE = await nin.MINTER_ROLE();
    const BURNER_ROLE = await nin.BURNER_ROLE();

    console.log("MINTER_ROLE:", MINTER_ROLE);
    console.log("BURNER_ROLE:", BURNER_ROLE);

    // 1. Grant roles to FX pool
    await nin.grantRole(MINTER_ROLE, fxPoolProxy);
    await nin.grantRole(BURNER_ROLE, fxPoolProxy);

    // 2. Revoke from deployer/admin if they have them
    const deployer = await signer.getAddress();
    await nin.revokeRole(MINTER_ROLE, deployer);
    await nin.revokeRole(BURNER_ROLE, deployer);

    // 3. (Optional) revoke DEFAULT_ADMIN_ROLE to lock forever
    //const DEFAULT_ADMIN_ROLE = ethers.constants.HashZero;
    //await nin.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
