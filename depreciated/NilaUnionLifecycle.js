// test/FundFactory.js
const { expect }    = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("FundFactoryUpgradeable – upgrade tests", function() {
  let factory, owner, other, NewLogic;

  beforeEach(async () => {
    [ owner, other ] = await ethers.getSigners();
    const Logic   = await ethers.getContractFactory("InputFundUpgradeable");
    const logic   = await Logic.deploy();
    const Factory = await ethers.getContractFactory("FundFactoryUpgradeable");
    const proxy   = await upgrades.deployProxy(Factory, [owner.address, logic.address], { kind: "uups" });
    factory = Factory.attach(proxy.address);
    NewLogic = await ethers.getContractFactory("InputFundUpgradeable");
  });

  it("only owner can upgrade", async () => {
    const newImpl = await NewLogic.deploy();
    await expect(
      factory.connect(other).upgradeTo(newImpl.address)
    ).to.be.revertedWith("Ownable: caller is not the owner");
    await factory.connect(owner).upgradeTo(newImpl.address);
    expect(await factory.callStatic.getAllFunds()).to.be.an("array");
  });
});
