// Interactive dashboard for GenericFundCore/GenericFundViewer admin settings.
// Run:
//   npx hardhat run scripts/genericfund_dashboard.js --network <network>

const hre = require("hardhat");
const { ethers } = hre;
const { encodeBytes32String, isHexString } = require("ethers");
const readline = require("node:readline/promises");
const { stdin: input, stdout: output } = require("node:process");

function toAddressOrThrow(value, label) {
  try {
    return ethers.getAddress(String(value).trim());
  } catch {
    throw new Error(`${label} is not a valid address`);
  }
}

function toUintOrThrow(value, label) {
  const v = String(value).trim();
  if (!/^\d+$/.test(v)) throw new Error(`${label} must be an unsigned integer`);
  return BigInt(v);
}

function toBoolOrThrow(value, label) {
  const v = String(value).trim().toLowerCase();
  if (v === "true" || v === "t" || v === "1" || v === "yes" || v === "y") return true;
  if (v === "false" || v === "f" || v === "0" || v === "no" || v === "n") return false;
  throw new Error(`${label} must be true/false`);
}

function toBytes32OrThrow(value, label) {
  const v = String(value).trim();
  if (isHexString(v, 32)) return v;
  if (v.length === 0) throw new Error(`${label} cannot be empty`);
  return encodeBytes32String(v);
}

function menuText(coreAddr, viewerAddr, rolesAddr, landTitleAddr) {
  return `
=== GenericFund Settings Dashboard ===
Core   : ${coreAddr ?? "(unset)"}
Viewer : ${viewerAddr ?? "(unset)"}
Roles  : ${rolesAddr ?? "(unset)"}
Land   : ${landTitleAddr ?? "(unset)"}

[1] Set Core address
[2] Show current key settings
[3] Core.setViewer
[4] Core.setRoles
[5] Core.setLandTitle
[6] Core.setReserveConfigForUnion
[7] Core.setBucketThresholds
[8] Core.setRateParams
[9] Core.setFeeBps
[10] Viewer.setCore
[11] Viewer.setRoles
[12] Viewer.CreateUnion
[13] Viewer.ActivateUnion
[14] Viewer.DeactivateUnion
[15] Viewer.AddFundType
[16] Viewer.RemoveFundType
[17] Roles.setOracle
[18] LandTitle.addToWhitelist
[19] LandTitle.removeFromWhitelist
[0] Exit
`;
}

async function prompt(rl, message) {
  return (await rl.question(message)).trim();
}

async function runTx(txPromise, label) {
  const tx = await txPromise;
  console.log(`${label} submitted: ${tx.hash}`);
  const receipt = await tx.wait();
  console.log(`${label} confirmed in block ${receipt.blockNumber}`);
}

async function printCurrentSettings(core, viewer, unionAddr, loanType) {
  const [owner, roles, landNFT, viewerAddr, treasuryFeeBP, rainyFeeBP] = await Promise.all([
    core.owner(),
    core.roles(),
    core.landNFT(),
    core.viewer(),
    core.treasuryFeeBP(),
    core.rainyFeeBP(),
  ]);

  console.log("\nCore settings:");
  console.log(`- owner:         ${owner}`);
  console.log(`- roles:         ${roles}`);
  console.log(`- landNFT:       ${landNFT}`);
  console.log(`- viewer:        ${viewerAddr}`);
  console.log(`- treasuryFeeBP: ${treasuryFeeBP}`);
  console.log(`- rainyFeeBP:    ${rainyFeeBP}`);

  if (viewer) {
    const [viewerOwner, viewerCore, viewerRoles] = await Promise.all([
      viewer.owner(),
      viewer.core(),
      viewer.roles(),
    ]);
    console.log("\nViewer settings:");
    console.log(`- owner: ${viewerOwner}`);
    console.log(`- core:  ${viewerCore}`);
    console.log(`- roles: ${viewerRoles}`);
  } else {
    console.log("\nViewer settings: (viewer not connected)");
  }

  if (unionAddr) {
    const [reserveCfg, rateParams, claimable, treasury, rainy] = await Promise.all([
      core.reserveCfgByUnion(unionAddr),
      core.rateParamsByUnion(unionAddr),
      core.unionClaimable(unionAddr),
      core.unionTreasury(unionAddr),
      core.unionRainyDay(unionAddr),
    ]);

    console.log(`\nUnion settings (${unionAddr}):`);
    console.log(
      `- reserveCfg: safetyBP=${reserveCfg.safetyBP}, safetyFloor=${reserveCfg.safetyFloor}, hardStop=${reserveCfg.hardStop}, exists=${reserveCfg.exists}`
    );
    console.log(
      `- rateParams: base=${rateParams.baseRateBP}, kink=${rateParams.kinkUtilBP}, slope1=${rateParams.slope1BP}, slope2=${rateParams.slope2BP}, max=${rateParams.maxRateBP}`
    );
    console.log(`- unionClaimable: ${claimable}`);
    console.log(`- unionTreasury:  ${treasury}`);
    console.log(`- unionRainyDay:  ${rainy}`);

    if (loanType) {
      const [thresholdWad, maxLoanAmount] = await Promise.all([
        core.bucketTresholds(unionAddr, loanType),
        core.bucketMaxAmount(unionAddr, loanType),
      ]);
      console.log(`\nLoanType settings (${loanType}):`);
      console.log(`- bucketThresholdWad: ${thresholdWad}`);
      console.log(`- bucketMaxAmount:    ${maxLoanAmount}`);
    }
  }
}

async function main() {
  const provider = ethers.provider;
  const signer = (await ethers.getSigners())[0];
  const network = await provider.getNetwork();

  console.log(`Network: ${network.name} (${network.chainId})`);
  console.log(`Signer : ${await signer.getAddress()}`);

  const rl = readline.createInterface({ input, output });
  let coreAddress = "";
  let viewerAddress = "";
  let rolesAddress = "";
  let landTitleAddress = "";
  let core = null;
  let viewer = null;
  let roles = null;
  let landTitle = null;

  try {
    while (true) {
      if (!core) {
        const first = await prompt(rl, "Enter GenericFundCore address: ");
        coreAddress = toAddressOrThrow(first, "Core address");
        core = await ethers.getContractAt("GenericFundCore", coreAddress, signer);
        console.log(`Core connected: ${coreAddress}`);

        try {
          const v = await core.viewer();
          if (v !== ethers.ZeroAddress) {
            viewerAddress = v;
            viewer = await ethers.getContractAt("GenericFundViewer", viewerAddress, signer);
            console.log(`Viewer auto-detected: ${viewerAddress}`);
          }
        } catch {
          // Keep running even if viewer() call fails.
        }

        try {
          const r = await core.roles();
          if (r !== ethers.ZeroAddress) {
            rolesAddress = r;
            roles = await ethers.getContractAt("RolesRegistry", rolesAddress, signer);
            console.log(`Roles auto-detected: ${rolesAddress}`);
          }
        } catch {
          // Keep running even if roles() call fails.
        }

        try {
          const l = await core.landNFT();
          if (l !== ethers.ZeroAddress) {
            landTitleAddress = l;
            landTitle = await ethers.getContractAt("NilaLandTitle", landTitleAddress, signer);
            console.log(`LandTitle auto-detected: ${landTitleAddress}`);
          }
        } catch {
          // Keep running even if landNFT() call fails.
        }
      }

      console.log(menuText(coreAddress, viewerAddress, rolesAddress, landTitleAddress));
      const choice = await prompt(rl, "Select option: ");

      try {
        if (choice === "0") break;

        if (choice === "1") {
          const addr = await prompt(rl, "New Core address: ");
          coreAddress = toAddressOrThrow(addr, "Core address");
          core = await ethers.getContractAt("GenericFundCore", coreAddress, signer);
          viewer = null;
          viewerAddress = "";
          roles = null;
          rolesAddress = "";
          landTitle = null;
          landTitleAddress = "";
          console.log(`Core switched to: ${coreAddress}`);
          continue;
        }

        if (choice === "2") {
          if (!viewer) {
            try {
              const v = await core.viewer();
              if (v !== ethers.ZeroAddress) {
                viewerAddress = v;
                viewer = await ethers.getContractAt("GenericFundViewer", viewerAddress, signer);
              }
            } catch {
              // ignore
            }
          }
          if (!roles) {
            try {
              const r = await core.roles();
              if (r !== ethers.ZeroAddress) {
                rolesAddress = r;
                roles = await ethers.getContractAt("RolesRegistry", rolesAddress, signer);
              }
            } catch {
              // ignore
            }
          }
          if (!landTitle) {
            try {
              const l = await core.landNFT();
              if (l !== ethers.ZeroAddress) {
                landTitleAddress = l;
                landTitle = await ethers.getContractAt("NilaLandTitle", landTitleAddress, signer);
              }
            } catch {
              // ignore
            }
          }

          let unionAddr = "";
          let loanType = "";
          const unionInput = await prompt(rl, "Union address (optional, Enter to skip): ");
          if (unionInput) {
            unionAddr = toAddressOrThrow(unionInput, "Union address");
            const loanTypeInput = await prompt(rl, "loanType (optional bytes32 hex OR text, Enter to skip): ");
            if (loanTypeInput) {
              loanType = toBytes32OrThrow(loanTypeInput, "loanType");
            }
          }

          await printCurrentSettings(core, viewer, unionAddr, loanType);
          continue;
        }

        if (choice === "3") {
          const addr = toAddressOrThrow(await prompt(rl, "Viewer address: "), "Viewer address");
          await runTx(core.setViewer(addr), "core.setViewer");
          viewerAddress = addr;
          viewer = await ethers.getContractAt("GenericFundViewer", viewerAddress, signer);
          continue;
        }

        if (choice === "4") {
          const addr = toAddressOrThrow(await prompt(rl, "Roles address: "), "Roles address");
          await runTx(core.setRoles(addr), "core.setRoles");
          rolesAddress = addr;
          roles = await ethers.getContractAt("RolesRegistry", rolesAddress, signer);
          continue;
        }

        if (choice === "5") {
          const addr = toAddressOrThrow(await prompt(rl, "LandTitle/NFT address: "), "LandTitle address");
          await runTx(core.setLandTitle(addr), "core.setLandTitle");
          landTitleAddress = addr;
          landTitle = await ethers.getContractAt("NilaLandTitle", landTitleAddress, signer);
          continue;
        }

        if (choice === "6") {
          const unionAddr = toAddressOrThrow(await prompt(rl, "Union address: "), "Union address");
          const safetyBP = toUintOrThrow(await prompt(rl, "safetyBP (uint32): "), "safetyBP");
          const safetyFloor = toUintOrThrow(await prompt(rl, "safetyFloor (uint224): "), "safetyFloor");
          const hardStop = toBoolOrThrow(await prompt(rl, "hardStop (true/false): "), "hardStop");
          await runTx(
            core.setReserveConfigForUnion(unionAddr, safetyBP, safetyFloor, hardStop),
            "core.setReserveConfigForUnion"
          );
          continue;
        }

        if (choice === "7") {
          const unionAddr = toAddressOrThrow(await prompt(rl, "Union address: "), "Union address");
          const loanType = toBytes32OrThrow(await prompt(rl, "loanType (bytes32 hex OR text): "), "loanType");
          const thresholdWad = toUintOrThrow(await prompt(rl, "thresholdWad (uint256): "), "thresholdWad");
          const maxLoanAmount = toUintOrThrow(await prompt(rl, "maxLoanAmount (uint256): "), "maxLoanAmount");
          await runTx(
            core.setBucketThresholds(unionAddr, loanType, thresholdWad, maxLoanAmount),
            "core.setBucketThresholds"
          );
          continue;
        }

        if (choice === "8") {
          const unionAddr = toAddressOrThrow(await prompt(rl, "Union address: "), "Union address");
          const baseRateBP = toUintOrThrow(await prompt(rl, "baseRateBP (uint16): "), "baseRateBP");
          const kinkUtilBP = toUintOrThrow(await prompt(rl, "kinkUtilBP (uint16): "), "kinkUtilBP");
          const slope1BP = toUintOrThrow(await prompt(rl, "slope1BP (uint16): "), "slope1BP");
          const slope2BP = toUintOrThrow(await prompt(rl, "slope2BP (uint16): "), "slope2BP");
          const maxRateBP = toUintOrThrow(await prompt(rl, "maxRateBP (uint16): "), "maxRateBP");
          await runTx(
            core.setRateParams(unionAddr, baseRateBP, kinkUtilBP, slope1BP, slope2BP, maxRateBP),
            "core.setRateParams"
          );
          continue;
        }

        if (choice === "9") {
          const treasuryBP = toUintOrThrow(await prompt(rl, "treasuryBP (uint16): "), "treasuryBP");
          const rainyBP = toUintOrThrow(await prompt(rl, "rainyBP (uint16): "), "rainyBP");
          await runTx(core.setFeeBps(treasuryBP, rainyBP), "core.setFeeBps");
          continue;
        }

        if (choice === "10") {
          if (!viewer) throw new Error("Viewer not connected. Use option [3] or ensure core.viewer is set.");
          const addr = toAddressOrThrow(await prompt(rl, "Core address: "), "Core address");
          await runTx(viewer.setCore(addr), "viewer.setCore");
          continue;
        }

        if (choice === "11") {
          if (!viewer) throw new Error("Viewer not connected. Use option [3] or ensure core.viewer is set.");
          const addr = toAddressOrThrow(await prompt(rl, "Roles address: "), "Roles address");
          await runTx(viewer.setRoles(addr), "viewer.setRoles");
          continue;
        }

        if (choice === "12") {
          if (!viewer) throw new Error("Viewer not connected. Use option [3] or ensure core.viewer is set.");
          const unionAddr = toAddressOrThrow(await prompt(rl, "Union address: "), "Union address");
          const name = await prompt(rl, "Union name: ");
          const location = await prompt(rl, "Union location: ");
          await runTx(viewer.CreateUnion(unionAddr, name, location), "viewer.CreateUnion");
          continue;
        }

        if (choice === "13") {
          if (!viewer) throw new Error("Viewer not connected. Use option [3] or ensure core.viewer is set.");
          const unionAddr = toAddressOrThrow(await prompt(rl, "Union address: "), "Union address");
          await runTx(viewer.ActivateUnion(unionAddr), "viewer.ActivateUnion");
          continue;
        }

        if (choice === "14") {
          if (!viewer) throw new Error("Viewer not connected. Use option [3] or ensure core.viewer is set.");
          const unionAddr = toAddressOrThrow(await prompt(rl, "Union address: "), "Union address");
          await runTx(viewer.DeactivateUnion(unionAddr), "viewer.DeactivateUnion");
          continue;
        }

        if (choice === "15") {
          if (!viewer) throw new Error("Viewer not connected. Use option [3] or ensure core.viewer is set.");
          const unionAddr = toAddressOrThrow(await prompt(rl, "Union address: "), "Union address");
          const encodedName = toBytes32OrThrow(await prompt(rl, "Fund type name (bytes32 hex OR text): "), "encodedName");
          const fundId = await prompt(rl, "fundId (string): ");
          await runTx(viewer.AddFundType(unionAddr, encodedName, fundId), "viewer.AddFundType");
          continue;
        }

        if (choice === "16") {
          if (!viewer) throw new Error("Viewer not connected. Use option [3] or ensure core.viewer is set.");
          const unionAddr = toAddressOrThrow(await prompt(rl, "Union address: "), "Union address");
          const i = toUintOrThrow(await prompt(rl, "Index to remove (uint256): "), "index");
          await runTx(viewer.RemoveFundType(unionAddr, i), "viewer.RemoveFundType");
          continue;
        }

        if (choice === "17") {
          if (!roles) throw new Error("Roles not connected. Use option [4] or ensure core.roles is set.");
          const oracle = toAddressOrThrow(await prompt(rl, "Oracle address: "), "Oracle address");
          const allowed = toBoolOrThrow(await prompt(rl, "allowed (true/false): "), "allowed");
          await runTx(roles.setOracle(oracle, allowed), "roles.setOracle");
          continue;
        }

        if (choice === "18") {
          if (!landTitle) throw new Error("LandTitle not connected. Use option [5] or ensure core.landNFT is set.");
          const signerAddr = toAddressOrThrow(await prompt(rl, "Signer address to whitelist: "), "Signer address");
          await runTx(landTitle.addToWhitelist(signerAddr), "landTitle.addToWhitelist");
          continue;
        }

        if (choice === "19") {
          if (!landTitle) throw new Error("LandTitle not connected. Use option [5] or ensure core.landNFT is set.");
          const signerAddr = toAddressOrThrow(await prompt(rl, "Signer address to remove: "), "Signer address");
          await runTx(landTitle.removeFromWhitelist(signerAddr), "landTitle.removeFromWhitelist");
          continue;
        }

        console.log("Unknown option.");
      } catch (err) {
        console.error(`Error: ${err.shortMessage || err.message || String(err)}`);
      }
    }
  } finally {
    rl.close();
  }

  console.log("Bye.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
