// Hardhat console (ethers v6)
// npx hardhat run scripts/typehashchecksforVouchers.js --network amoy
const { ethers } = require("hardhat");
const {
  getAddress, AbiCoder, keccak256, toUtf8Bytes, concat, parseUnits, recoverAddress
} = ethers;

const chainId = 80002n;

// Canonicalize all addresses
const core     = getAddress("0xBea16D53399d5b6627D6c30aFDfB3f6482D5932B");   // core proxy
const borrower = getAddress("0xaf7030023cf86611ffc5a71798a0f7022210f2b3");   // normalize!
const union    = getAddress("0xC7FdEf69986317c1770d46C850560D9e469849Cf");   // normalize anyway

console.log("borrower:", borrower);
// Constants (must match your contract)
const DOMAIN_TYPE = "EIP712Domain(string name,uint256 chainId,address verifyingContract)";
const NAME        = "GenericFund";
const VOUCHER_TYPE = "Voucher(address borrower,address union,uint256 maxAmount,uint16 minRateBP,bytes32 loanType,bytes32 paramsHash,bool fastDraw)";

const EIP712_DOMAIN_TYPEHASH = keccak256(toUtf8Bytes(DOMAIN_TYPE));
const NAME_HASH              = keccak256(toUtf8Bytes(NAME));
const VOUCHER_TYPEHASH       = keccak256(toUtf8Bytes(VOUCHER_TYPE));

// Your exact message values (use the same units you signed in Python)
const maxAmount  = ethers.parseUnits("100", 18); // or paste your raw_maxAmount bigint
const minRateBP  = 1924;
const loanType   = "0x47726f756e6455702046756e6400000000000000000000000000000000000000";
const paramsHash = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
const fastDraw   = true;

// struct hash
const coder = AbiCoder.defaultAbiCoder();
const structHash = keccak256(coder.encode(
  ["bytes32","address","address","uint256","uint16","bytes32","bytes32","bool"],
  [VOUCHER_TYPEHASH, borrower, union, maxAmount, minRateBP, loanType, paramsHash, fastDraw]
));

// domain separator (matches your contract helper)
const domainSep = keccak256(coder.encode(
  ["bytes32","bytes32","uint256","address"],
  [EIP712_DOMAIN_TYPEHASH, NAME_HASH, chainId, core]
));

// final digest
const digest = keccak256(concat(["0x1901", domainSep, structHash]));
console.log("digest:", digest);

// If you have the Python-produced signature:
const sig = "0xa2295b9f1e039962b20c9852fcedcdde61c73f00fdefce1205097fd6eed0af847f133d6c6d6f6981bbc5c376b309306318ce9848d8a8279dec1df058fc560e101b"; 
console.log("recovered:", recoverAddress(digest, sig));
