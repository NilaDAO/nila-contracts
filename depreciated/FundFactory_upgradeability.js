// test/FundFactoryUpgradeable.test.js
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("FundFactoryUpgradeable (UUPS ‑ OZ v5)", () => {
  let owner, other, proxy;

  beforeEach(async () => {
    [owner, other] = await ethers.getSigners();

    // Deploy proxy – we just pass a dummy fundLogic (other.address)
    const Factory = await ethers.getContractFactory("FundFactoryUpgradeable");
    const wrapped = await upgrades.deployProxy(
      Factory,
      [ owner.address, other.address ],
      { kind: "uups", initializer: "initialize" }
    );
    await wrapped.waitForDeployment();

    // Re‑attach with full ABI (contains upgradeToAndCall)
    proxy = await ethers.getContractAt("FundFactoryUpgradeable", wrapped.target);
  });

  it("sets deployer as owner", async () => {
    expect(await proxy.owner()).to.equal(owner.address);
  });

  it("only owner can upgrade", async () => {
    // New implementation
    const NewImpl = await ethers.getContractFactory("FundFactoryUpgradeable");
    const newImpl = await NewImpl.deploy();
    await newImpl.waitForDeployment();
    const newAddr = await newImpl.getAddress()

    console.log('newAddr', newAddr)
    // Non‑owner should revert with custom error
    await expect(
      proxy.connect(other).upgradeToAndCall(newAddr, "0x")
    ).to.be.revertedWithCustomError(proxy, "OwnableUnauthorizedAccount")
     .withArgs(other.address);

    // Owner can upgrade
    await proxy.connect(owner).upgradeToAndCall(newAddr, "0x");

    // Implementation slot really updated
    const slot = await upgrades.erc1967.getImplementationAddress(proxy.target);
    console.log('slot', slot)

    expect(slot).to.equal(newAddr);
  });
});
