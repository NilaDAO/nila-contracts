// npx hardhat run scripts/TOMAINNET/remove_landtitle_whitelist.js --network polygon 
const { ethers } = require("hardhat");

/**
 * Remove a signer from the NilaLandTitle whitelist.
 *
 * Usage:
 *   npx hardhat run scripts/TOMAINNET/remove_landtitle_whitelist.js --network amoy -- --contract <proxyAddr> --signer <address>
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

  const contractAddr = '0x636060dbC695a8232992b28c1765828263f17251';
  const signerToRemove = '0x4387bf96c4da8Bd2d44981b276a8862B09BaE072';

  if (!contractAddr || !signerToRemove) {
    throw new Error(
      "Missing args. Required: --contract <addr> --signer <addr>"
    );
  }
  if (!ethers.isAddress(contractAddr)) {
    throw new Error(`Invalid --contract address: ${contractAddr}`);
  }
  if (!ethers.isAddress(signerToRemove)) {
    throw new Error(`Invalid --signer address: ${signerToRemove}`);
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

  const alreadyWhitelisted = await landTitle.isWhitelisted(signerToRemove);
  if (!alreadyWhitelisted) {
    console.log(`Address ${signerToRemove} is already not whitelisted.`);
    return;
  }

  console.log(`Removing ${signerToRemove} from whitelist on ${contractAddr}...`);
  const tx = await landTitle.removeFromWhitelist(signerToRemove);
  const receipt = await tx.wait();
  console.log(
    `✅ removeFromWhitelist mined in block ${receipt.blockNumber}: ${receipt.hash}`
  );

  const nowWhitelisted = await landTitle.isWhitelisted(signerToRemove);
  console.log(`isWhitelisted(${signerToRemove}): ${nowWhitelisted}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
