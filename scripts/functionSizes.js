/* eslint-disable no-console */
const fs = require("fs");
const path = require("path");

function findBuildInfoFor(fqName) {
  const dir = path.join("artifacts", "build-info");
  const files = fs.readdirSync(dir).filter(f => f.endsWith(".json"));
  for (const f of files) {
    const j = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
    const out = j.output || {};
    const contracts = out.contracts || {};
    for (const filePath of Object.keys(contracts)) {
      for (const name of Object.keys(contracts[filePath])) {
        if (`${filePath}:${name}` === fqName) return { build: j, filePath, name };
      }
    }
  }
  throw new Error(`Not found: ${fqName}`);
}

function parseSrc(s) {
  const [start, length, fileIndex] = s.split(":").map(x => parseInt(x || "0", 10));
  return { start, length, fileIndex };
}

function collectFunctionsFromAllSources(sources) {
  const byFile = new Map(); // fileIndex -> [{name, contract, start,end}]
  for (const [filePath, { ast }] of Object.entries(sources)) {
    if (!ast || !ast.src) continue;
    const fileIndex = parseSrc(ast.src).fileIndex;
    const fns = [];
    const stack = [];
    const walk = node => {
      if (!node || typeof node !== "object") return;
      if (node.nodeType === "ContractDefinition") stack.push(node.name);
      if (node.nodeType === "FunctionDefinition" && node.src) {
        const { start, length } = parseSrc(node.src);
        const name = node.name || (node.kind || "function");
        const contract = stack[stack.length - 1] || "";
        fns.push({ name, contract, start, end: start + length });
      }
      for (const k in node) {
        const v = node[k];
        if (Array.isArray(v)) v.forEach(walk);
        else if (v && typeof v === "object") walk(v);
      }
      if (node.nodeType === "ContractDefinition") stack.pop();
    };
    walk(ast);
    byFile.set(fileIndex, fns);
  }
  return byFile;
}

function decodeInstructionLengths(hex) {
  const b = Buffer.from(hex.replace(/^0x/, ""), "hex");
  const lens = [];
  for (let pc = 0; pc < b.length; ) {
    const op = b[pc];
    let size = 1;
    if (op >= 0x60 && op <= 0x7f) size += (op - 0x5f); // PUSH1..PUSH32
    lens.push(size);
    pc += size;
  }
  return lens;
}

function parseSourceMap(sm) {
  const out = [];
  let s = 0, l = 0, f = 0;
  for (const e of sm.split(";")) {
    if (e.length === 0) continue;
    const p = e.split(":");
    if (p[0] !== "") s = parseInt(p[0], 10) || 0;
    if (p[1] !== "") l = parseInt(p[1], 10) || 0;
    if (p[2] !== "") f = parseInt(p[2], 10) || 0;
    out.push({ s, l, f });
  }
  return out;
}

function findFnName(entry, byFile) {
  const list = byFile.get(entry.f);
  if (!list) return null;
  // attribute to the first function that contains the start
  for (const fn of list) {
    if (entry.s >= fn.start && entry.s < fn.end) return `${fn.contract}.${fn.name}`;
  }
  return null;
}

function run(fqName) {
  const { build, filePath, name } = findBuildInfoFor(fqName);
  const c = build.output.contracts[filePath][name];
  const bytecode = c.evm.deployedBytecode.object;
  const srcmap   = c.evm.deployedBytecode.sourceMap;
  if (!bytecode || !srcmap) throw new Error("Missing deployed bytecode/sourceMap");

  const byFile = collectFunctionsFromAllSources(build.output.sources);
  const lens = decodeInstructionLengths(bytecode);
  const sm   = parseSourceMap(srcmap);
  const n = Math.min(lens.length, sm.length);

  const sizes = new Map();
  const MISC = "<dispatcher/misc>";
  for (let i = 0; i < n; ++i) {
    const name = findFnName(sm[i], byFile) || MISC;
    sizes.set(name, (sizes.get(name) || 0) + lens[i]);
  }

  const items = Array.from(sizes.entries()).sort((a,b) => b[1]-a[1]);
  const total = items.reduce((a,[,v]) => a+v, 0);
  console.log(`Function sizes for ${fqName}`);
  console.log(`Total mapped bytes: ${total}`);
  for (const [nme, sz] of items) {
    console.log(`${nme.padEnd(50)} ${String(sz).padStart(6)} bytes`);
  }
}

const fq = process.argv[2] || "contracts/GenericFundCore.sol:GenericFundCore";
run(fq);
