const {
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
  } = require("./union_tests.js");
  
const { ethers } = require("hardhat");

  async function dateToAmoyPolygonBlocks(dateString) {
    // Connect to the Polygon network
    const provider = ethers.provider;
    const blockNumber = await ethers.provider.getBlockNumber();
    // 
    console.log('blockNumber', blockNumber)
    const currentDate = new Date();
    const targetDate = new Date(dateString);
    console.log('currentDate', currentDate)
    console.log('targetDate', targetDate)
    const diffInMilliseconds = targetDate.getTime() - currentDate.getTime();
    const diffInSeconds = Math.floor(diffInMilliseconds / 1000);
    console.log('diffInSeconds', diffInSeconds)
    const futureBlocks = Math.floor(diffInSeconds / 2.1);
    console.log(' blockNumber + futureBlocks',  blockNumber + futureBlocks)

    return blockNumber + futureBlocks;
  }

  async function main() {

    async function NewDemand() {
        const targetDate = new Date("2026-1-18");
        // ! interest rate in BASIS POINTS
        /**
         * 1 = PADDY
         * 2 = WHEAT
         * 3 = MAIZE
         * 4 = SORGHUM
         * 5 = MILLET
         * 6 = CASSAV
         * 7 = SUGARCASE
         * 8 = POTATO
         * 9 = TAPIOCA
         * 10 = SESAME
         * 11 = GROUNDNUT
         */
        
        await createProduce(7, 100, 22000, targetDate.getTime()); // _cropType, _amount, _interestRate Basis Points (bps), _deadline, _location
        const count = await getProductsLength();
        console.log("Current demands:", count.toString());
    }

    //NewDemand()

    const me = '0xA97E4afF1503135a545B275855Ed3A6263B3b74f'// '0x0e8dAbAabAB48805B97509E232470bea4f6e197f','0x56df482D569FAc185Dfc3af45Bac32dbC8d7b07e'
    const anand = '0xb13B71f3d66314c8E316b9bc749650a9EA35787C'
    async function AddSelected() {
        await addSelectedList(1,['0x8A4897174e219FeD129DCd925f2219f498305A2B'])
    }

    AddSelected()

    async function getInfo() {
        const stakes = await getTotalOwed(0)
        console.log("Current stakes:", stakes.toString());
        const info = await getProduct(0)
        console.log("Current Info:", info);

    }
    //getInfo()

    async function acceptDemand() {
        const stakes = await acceptDemand(0)
        console.log("Current stakes:", stakes.toString());
    }
    //acceptDemand()

    async function getTotaldebt(demandId) {
        const debt = await getTotalDebt(demandId)
        console.log("total debt:", debt.toString());
    }
    
    //getTotaldebt(0)

    async function isDemandsettled(demandId) {
      const stakes = await isDemandSettled(demandId)
      console.log("demand settled?", stakes.toString());
    }

    //isDemandsettled(0)
  }
  
  main().catch(console.error);
  

  // call this script AS UNION LEADER:  npx hardhat run scripts/union_call_tests.js --network polygon_amoy_union_leader  
  // // call this script AS MASTERNODE:  npx hardhat run scripts/union_call_tests.js --network polygon_amoy_masternode