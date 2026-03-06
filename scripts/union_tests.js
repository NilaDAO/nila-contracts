const hre = require("hardhat");

// Replace with your deployed address
const NILA_UNION_ADDRESS = "0xCF4AEdE5075B63e68AC588fc537bcbca49990B5f";

// Helper to get the contract instance
async function getNilaUnion() {
  return hre.ethers.getContractAt("NilaUnion", NILA_UNION_ADDRESS);
}

// ------------------- WRITE methods -------------------

// 1) createDemand
async function createProduce(_cropType, _amount, _interestRate, _deadline) {
  const nilaUnion = await getNilaUnion();
  console.log("inputs", _cropType, _amount, _interestRate, _deadline);
  try {
    const tx = await nilaUnion.createProduce(_cropType, _amount, _interestRate, _deadline);
    await tx.wait();
  } catch (error) {
    console.error(error);
  }
}

// 2) addSelectedList
async function addSelectedList(produceId, selectedAddresses) {
  const nilaUnion = await getNilaUnion();
  const tx = await nilaUnion.addSelectedList(produceId, selectedAddresses);
  await tx.wait();
  console.log("Selected list added.");
}

// 3) stakeToDemand
async function stakeToProduce(produceId, address, amount) {
  const nilaUnion = await getNilaUnion();
  const tx = await nilaUnion.stakeToDemand(produceId, address, amount);
  await tx.wait();
  console.log("Stake(s) added to demand.");
}

// 4) confirmDemand
async function acceptProduce(produceId) {
  const nilaUnion = await getNilaUnion();
  const tx = await nilaUnion.acceptProduce(produceId);
  await tx.wait();
  console.log("Produce confirmed.");
}

// 6) repayDebt
async function repayDebt(produceId, paymentAmount, debtor) {
  const nilaUnion = await getNilaUnion();
  const tx = await nilaUnion.repayDebt(produceId, paymentAmount, debtor);
  await tx.wait();
  console.log("Debt repaid.");
}

// 7) claimInterest
async function claimInterest(produceId,selected) {
  const nilaUnion = await getNilaUnion();
  const tx = await nilaUnion.claimInterest(produceId,selected);
  await tx.wait();
  console.log("Interest claimed.");
}

// 8) noActivitySignal
async function noActivitySignal(produceId) {
  const nilaUnion = await getNilaUnion();
  const tx = await nilaUnion.noActivitySignal(produceId);
  await tx.wait();
  console.log("No-activity signal sent.");
}

// 9) remove product (by union leader)
async function removeProduce(produceId) {
  const nilaUnion = await getNilaUnion();
  const tx = await nilaUnion.removeProduce(produceId);
  await tx.wait();
  console.log("Product removed");
}

// ------------------- READ methods -------------------

// 10) getDemandsCount
async function getProductsLength() {
  const nilaUnion = await getNilaUnion();
  return nilaUnion.getProductsLength();
}

// 11) getDemandInfo
async function getProduct(produceId) {
  const nilaUnion = await getNilaUnion();
  return nilaUnion.getProduct(produceId);
}

// 12) getUserStake
async function getSelectedAddresses(produceId) {
  const nilaUnion = await getNilaUnion();
  return nilaUnion.getSelectedAddresses(produceId);
}

// 13) getAllStakesForDemand
async function getInvestorstakes(investor) {
  const nilaUnion = await getNilaUnion();
  return nilaUnion.getInvestorStakes(investor);
}

// 14) getAccruedInterest
async function getTotalOwed(produceId) {
  const nilaUnion = await getNilaUnion();
  return nilaUnion.getTotalOwedByFarmer(produceId);
}

// 15) getTotalDebt
async function getRemainingDebt(produceId) {
  const nilaUnion = await getNilaUnion();
  return nilaUnion.getRemainingDebt(produceId);
}

// 16) isDemandSettled
async function getPendingInterest(investor) {
  const nilaUnion = await getNilaUnion();
  return nilaUnion.getPendingInterest(produceId);
}

// 17) timeToHarvestDeadline
async function getTimeToDeadline(produceId) {
  const nilaUnion = await getNilaUnion();
  return nilaUnion.getTimeToDeadline(produceId);
}

// 18) isDemandFrozen
async function isProduceFrozen(produceId) {
  const nilaUnion = await getNilaUnion();
  return nilaUnion.isProduceFrozen(produceId);
}

// Export them so you can import in another script
module.exports = {
  createProduce,
  addSelectedList,
  stakeToProduce,
  acceptProduce,
  repayDebt,
  claimInterest,
  noActivitySignal,
  removeProduce,

  getProductsLength,
  getProduct,
  getSelectedAddresses,
  getInvestorstakes,
  getTotalOwed,
  getRemainingDebt,
  getPendingInterest,
  getTimeToDeadline,
  isProduceFrozen
};
