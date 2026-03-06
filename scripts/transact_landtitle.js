const { ethers } = require("hardhat");

/**
 * Usage:
 *   npx hardhat run scripts/transact_landtitle.js --network amoy --contract 0x663DC13009D004aF3654a45f22A215De71633918 --from 0x4387bf96c4da8Bd2d44981b276a8862B09BaE072 --to 0x56df482D569FAc185Dfc3af45Bac32dbC8d7b07e --tokenid 33
 *
 * NOTE: The signer that runs this script must be the token owner or an approved operator.
 */

async function main() {
  // Read CLI args (very lightweight)
  const args = process.argv.slice(2);
  const getArg = (name) => {
    const i = args.indexOf(`--${name}`);
    return i !== -1 ? args[i + 1] : undefined;
  };

  const contractAddr = '0x663DC13009D004aF3654a45f22A215De71633918';
  const from = '0x4387bf96c4da8Bd2d44981b276a8862B09BaE072';
  const to = '0x56df482D569FAc185Dfc3af45Bac32dbC8d7b07e';
  const tokenIdStr = 33
  console.log(contractAddr, from, to, tokenIdStr);

  if (!contractAddr || !from || !to || !tokenIdStr) {
    throw new Error(
      "Missing args. Required: --contract <addr> --from <addr> --to <addr> --tokenId <number>"
    );
  }

  const tokenId = BigInt(tokenIdStr);

  // Use the first configured account as the signer (must be owner or approved)
  const [signer, owner] = await ethers.getSigners();
  console.log(`Using owner: ${await owner.getAddress()}`);

  // Attach to your compiled contract by name
  const nft = await ethers.getContractAt("NilaLandTitle", contractAddr, owner);

  // Optional: sanity checks
  const ownerBefore = await nft.ownerOf(tokenId);
  console.log(`Current owner of #${tokenId}: ${ownerBefore}`);

  if (ownerBefore.toLowerCase() !== from.toLowerCase()) {
    console.warn(
      `⚠️  Provided --from (${from}) does not match on-chain owner (${ownerBefore}).` +
      ` If you're an approved operator, this can still work.`
    );
  }

  console.log(`Transferring token #${tokenId} from ${from} to ${to}...`);

  // Call the ERC721 safeTransferFrom overload (explicit signature for ethers v6)
  const tx = await nft["safeTransferFrom(address,address,uint256)"](from, to, tokenId);
  const receipt = await tx.wait();

  console.log(`✅ Transfer tx mined in block ${receipt.blockNumber}: ${receipt.hash}`);

  const ownerAfter = await nft.ownerOf(tokenId);
  console.log(`New owner of #${tokenId}: ${ownerAfter}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
