// npx hardhat run scripts/TOMAINNET/upgrade_viewer.ts --network amoy
const { ethers, upgrades, run  } = require("hardhat");
const { erc1967  } = require("@openzeppelin/upgrades-core");;

function addr(x?: string, name?: string) {
  if (!x) throw new Error(`Missing ${name}`);
  return ethers.getAddress(x.startsWith("0x") ? x : `0x${x}`);
}

async function main() {
  const CORE_PROXY = addr(process.env.COREPROXY, "CORE (proxy)");
  const MATHLIB    = addr(process.env.MATHLIB_MAIN, "MATHLIB");
  const VIEWER_PROXY = process.env.VIEWERPROXY as string | undefined; // optional (if already proxied)
  const OWNER_PK = process.env.OWNER_PRIVATE_KEY;                       
  const shouldVerify = false // !!process.env.POLYGONSCAN_API_KEY;  

  const [owner] = await ethers.getSigners();
  console.log("Signer:", await owner.getAddress());
  
  // 0) add core for viewer update
  const core = await ethers.getContractAt("GenericFundCore", CORE_PROXY, owner);

  /*
  // 1) (Once per project/network) register the live proxy in the OZ manifest
  await upgrades.forceImport(
    CORE_PROXY,
    CoreF,
    {
      kind: "uups",
      // Use ONE of the two lines below depending on your plugin version:
      // unsafeAllowLinkedLibraries: true,
      unsafeAllow: ["external-library-linking"],
      signer: owner,
    }
  );

  // 2) Sanity: owner check through proxy ABI
  const CoreAtProxy = await ethers.getContractAt("GenericFundCore", CORE_PROXY, owner);
  const proxyOwner  = await CoreAtProxy.owner();
  if (proxyOwner.toLowerCase() !== (await owner.getAddress()).toLowerCase()) {
    throw new Error(`Signer is NOT the core owner. Owner: ${proxyOwner}`);
  }

  await upgrades.validateUpgrade(CORE_PROXY, CoreF, { kind: "uups", unsafeAllow: ["external-library-linking"]});

  // 3) Show impl BEFORE
  const implBefore = await upgrades.erc1967.getImplementationAddress(CORE_PROXY);
  console.log("Impl BEFORE:", implBefore);

  // 4) (Optional) see what would be used if not forced
  const prepared = await upgrades.prepareUpgrade(CORE_PROXY, CoreF, {
    kind: "uups",
    // unsafeAllowLinkedLibraries: true,
    unsafeAllow: ["external-library-linking"],
  });
  console.log("Prepared impl:", prepared);

  // 5) Upgrade, forcing a fresh impl deployment (even if bytecode is identical)
  const upgraded = await upgrades.upgradeProxy(
    CORE_PROXY,
    CoreF,
    {
      kind: "uups",
      // unsafeAllowLinkedLibraries: true,
      unsafeAllow: ["external-library-linking"],
      redeployImplementation: "always",
      signer: owner,
    }
  );
  await upgraded.waitForDeployment();

  // 6) AFTER + code comparison
  const implAfter = await upgrades.erc1967.getImplementationAddress(upgraded.target as string);
  console.log("Impl AFTER :", implAfter);

  const oldCode = await ethers.provider.getCode(implBefore);
  const newCode = await ethers.provider.getCode(implAfter);
  console.log("BYTECODE CHANGED? ", oldCode !== newCode);

  const tx = upgraded.deploymentTransaction?.();
  console.log("Upgrade tx:", tx ? tx.hash : "(none)");

  */
  // ---------- 2) Deploy or Upgrade Viewer (UUPS) ----------
  const ViewerF = await ethers.getContractFactory("GenericFundViewer", {
    signer: owner,
    libraries: { GenericFundMathLib: MATHLIB },
  });

  let viewerProxyAddress: string;

  if (VIEWER_PROXY) {
    console.log("Upgrading existing Viewer proxy…");
    const viewerUpgraded = await upgrades.upgradeProxy(VIEWER_PROXY, ViewerF, { kind: "uups", unsafeAllowLinkedLibraries: true });
    await viewerUpgraded.waitForDeployment();
    viewerProxyAddress = await viewerUpgraded.getAddress();
    console.log(`Viewer upgraded. Proxy: ${viewerProxyAddress}`);

    // Optional: ensure Viewer points to current Core (should be same proxy address)
    //const viewer = await ethers.getContractAt("GenericFundViewer", viewerProxyAddress, owner);
    // if you ever rotated the core proxy (unlikely), setCore here:
    // await (await viewer.setCore(CORE_PROXY)).wait();
  } else {
    console.log("Deploying new Viewer proxy…");
    const viewer = await upgrades.deployProxy(ViewerF, [CORE_PROXY], {
      kind: "uups",
      unsafeAllowLinkedLibraries: true,
      initializer: "initialize",
    });
    await viewer.waitForDeployment();
    viewerProxyAddress = await viewer.getAddress();
    console.log(`Viewer proxy deployed at: ${viewerProxyAddress}`);

    if (shouldVerify) {
      const viewerImpl = await erc1967.getImplementationAddress(ethers.provider, viewerProxyAddress);
      try {
        console.log(`Verifying Viewer impl: ${viewerImpl}`);
        await run("verify:verify", {
          address: viewerImpl,
          contract: "contracts/GenericFundViewer.sol:GenericFundViewer",
        });
        console.log("Viewer impl verified.");
      } catch (e: any) {
        console.log(`Viewer verify skipped/failed: ${e?.message ?? e}`);
      }
    }
  }
  // ---------- 3) Point Core → Viewer ----------
  const currentViewer = await core.viewer();
  if (currentViewer.toLowerCase() !== viewerProxyAddress.toLowerCase()) {
    console.log(`Setting Core.viewer = ${viewerProxyAddress}…`);
    const tx = await core.setViewer(viewerProxyAddress);
    await tx.wait();
    console.log(`Core.viewer now: ${await core.viewer()}`);
  } else {
    console.log("Core.viewer already points to the viewer proxy.");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
