// npx hardhat run scripts/TOMAINNET/add_landtitle_whitelist.js --network polygon 
const { ethers } = require("hardhat");

/**
 * Add a signer to the NilaLandTitle whitelist.
 *
 * Usage:
 *   npx hardhat run scripts/add_landtitle_whitelist.js --network amoy -- --contract <proxyAddr> --signer <address>
 *
 * Notes:
 *   - The caller must be the contract owner.
 *   - Contract name is assumed to be "NilaLandTitle".
 */
async function main() {
  const args = process.argv.slice(2);
  const getArg = (flag) => {
    const i = args.indexOf(`--${flag}`);
    return i !== -1 ? args[i + 1] : undefined;
  };

  const contractAddr = '0x636060dbC695a8232992b28c1765828263f17251'
  const signerToAdd = '0x681b63c9320ada076133beacc75efb1e4752dc2f'

  if (!contractAddr || !signerToAdd) {
    throw new Error(
      "Missing args. Required: --contract <addr> --signer <addr>"
    );
  }
  if (!ethers.isAddress(contractAddr)) {
    throw new Error(`Invalid --contract address: ${contractAddr}`);
  }
  if (!ethers.isAddress(signerToAdd)) {
    throw new Error(`Invalid --signer address: ${signerToAdd}`);
  }

  const [owner] = await ethers.getSigners();
  console.log(`Using signer: ${owner.address}`);

  const landTitle = await ethers.getContractAt(
    "NilaLandTitle",
    contractAddr,
    owner
  );

  const contractOwner = await landTitle.owner();
  if (contractOwner.toLowerCase() !== owner.address.toLowerCase()) {
    console.warn(
      `⚠️ Caller ${owner.address} is not the on-chain owner (${contractOwner}).`
    );
  }

  const alreadyWhitelisted = await landTitle.isWhitelisted(signerToAdd);
  if (alreadyWhitelisted) {
    console.log(`Address ${signerToAdd} is already whitelisted.`);
    return;
  }

  console.log(`Adding ${signerToAdd} to whitelist on ${contractAddr}...`);
  const tx = await landTitle.addToWhitelist(signerToAdd);
  const receipt = await tx.wait();
  console.log(
    `✅ addToWhitelist mined in block ${receipt.blockNumber}: ${receipt.hash}`
  );

  const nowWhitelisted = await landTitle.isWhitelisted(signerToAdd);
  console.log(`isWhitelisted(${signerToAdd}): ${nowWhitelisted}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
