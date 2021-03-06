/* eslint no-use-before-define: "warn" */
const fs = require("fs");
const chalk = require("chalk");
const { config, ethers, tenderly, run } = require("hardhat");
const { utils } = require("ethers");
const SuperfluidSDK = require("@superfluid-finance/js-sdk");

const R = require("ramda");

const addresses = {
  polygon: {
    erc20Tokens: {
      DAI: "0x8f3cf7ad23cd3cadbd9735aff958023239c6a063",
    },
    aave: {
      lendingPool: "0x8dff5e27ea6b7ac08ebfdf9eb090f32ee9a30fcf",
      dataProvider: "0x7551b5D2763519d4e37e8B81929D336De671d46d",
      debtToken: "0x75c4d1Fb84429023170086f06E682DcbBF537b7d",
    },
    superfluid: {
      resolver: "0xE0cc76334405EE8b39213E620587d815967af39C",
    },
  },
  mumbai: {
    erc20Tokens: {
      DAI: "0x001B3B4d0F3714Ca98ba10F6042DaEbF0B1B7b6F",
    },
    aave: {
      lendingPool: "0x9198F13B08E299d85E096929fA9781A1E3d5d827",
      dataProvider: "0xFA3bD19110d986c5e5E9DD5F69362d05035D045B",
      debtToken: "0x6D29322ba6549B95e98E9B08033F5ffb857f19c5",
    },
    superfluid: {
      resolver: "0x8C54C83FbDe3C59e59dd6E324531FB93d4F504d3",
    },
  },
  ethereum: {
    erc20Tokens: {
      DAI: "0x6b175474e89094c44da98b954eedeac495271d0f",
    },
    aave: {
      lendingPool: "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9",
      dataProvider: "0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d",
      debtToken: "0x6C3c78838c761c6Ac7bE9F59fe808ea2A6E4379d",
    },
  },
};

const chain = "polygon";

const main = async () => {
  console.log("\n\n 📡 Deploying...\n");

  const sf = new SuperfluidSDK.Framework({
    ethers: ethers.provider,
    resolverAddress: addresses[chain]["superfluid"]["resolver"],
    tokens: ["DAI"],
  });
  await sf.initialize();

  const dividendRightsToken = await deploy("DividendRightsToken", [
    "Dividend Rights Token",
    "DRT",
    sf.tokens.DAIx.address,
    sf.host.address,
    sf.agreements.ida.address,
  ]);

  const delegateFund = await deploy("DelegateFund");

  const delegateCreditManager = await deploy("DelegateCreditManager", [
    addresses[chain].aave.lendingPool,
    addresses[chain].aave.dataProvider,
  ]);

  const strategySimplify = await deploy(
    "StrategySimplify",
    [
      [
        delegateFund.address,
        addresses[chain].erc20Tokens.DAI,
        delegateCreditManager.address,
        dividendRightsToken.address,
      ],
      ethers.utils.parseEther("500000"),
      0,
    ],
    {
      //   gasLimit: 20000000,
    }
  );

  const ratingOracle = await deploy("RatingOracle");

  /*const debtDerivative = await deploy("DebtDerivative", [
    "www.delegafi.com/derivativedata/{debtDerivativeID}.json",
    ratingOracle.address,
  ]);
  */

  console.log(
    " 💾  Artifacts (address, abi, and args) saved to: ",
    chalk.blue("packages/hardhat/artifacts/"),
    "\n\n"
  );
};

const deploy = async (
  contractName,
  _args = [],
  overrides = {},
  libraries = {}
) => {
  console.log(` 🛰  Deploying: ${contractName}`);

  const contractArgs = _args || [];
  let contractArtifacts = await ethers.getContractFactory(contractName, {
    libraries: libraries,
  });
  const deployed = await contractArtifacts.deploy(...contractArgs, overrides);
  const encoded = abiEncodeArgs(deployed, contractArgs);
  fs.writeFileSync(`artifacts/${contractName}.address`, deployed.address);

  let extraGasInfo = "";
  if (deployed && deployed.deployTransaction) {
    const gasUsed = deployed.deployTransaction.gasLimit.mul(
      deployed.deployTransaction.gasPrice
    );
    extraGasInfo = `${utils.formatEther(gasUsed)} ETH, tx hash ${
      deployed.deployTransaction.hash
    }`;
  }

  console.log(
    " 📄",
    chalk.cyan(contractName),
    "deployed to:",
    chalk.magenta(deployed.address)
  );
  console.log(" ⛽", chalk.grey(extraGasInfo));

  await tenderlyVerify({
    contractName,
    contractAddress: deployed.address,
  });

  if (!encoded || encoded.length <= 2) return deployed;
  fs.writeFileSync(`artifacts/${contractName}.args`, encoded.slice(2));

  return deployed;
};

// ------ utils -------

// abi encodes contract arguments
// useful when you want to manually verify the contracts
// for example, on Etherscan
const abiEncodeArgs = (deployed, contractArgs) => {
  // not writing abi encoded args if this does not pass
  if (
    !contractArgs ||
    !deployed ||
    !R.hasPath(["interface", "deploy"], deployed)
  ) {
    return "";
  }
  const encoded = utils.defaultAbiCoder.encode(
    deployed.interface.deploy.inputs,
    contractArgs
  );
  return encoded;
};

// checks if it is a Solidity file
const isSolidity = (fileName) =>
  fileName.indexOf(".sol") >= 0 &&
  fileName.indexOf(".swp") < 0 &&
  fileName.indexOf(".swap") < 0;

const readArgsFile = (contractName) => {
  let args = [];
  try {
    const argsFile = `./contracts/${contractName}.args`;
    if (!fs.existsSync(argsFile)) return args;
    args = JSON.parse(fs.readFileSync(argsFile));
  } catch (e) {
    console.log(e);
  }
  return args;
};

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// If you want to verify on https://tenderly.co/
const tenderlyVerify = async ({ contractName, contractAddress }) => {
  let tenderlyNetworks = [
    "kovan",
    "goerli",
    "mainnet",
    "rinkeby",
    "ropsten",
    "matic",
    "mumbai",
    "xDai",
    "POA",
  ];
  let targetNetwork = process.env.HARDHAT_NETWORK || config.defaultNetwork;
  //let targetNetwork = "matic";

  if (tenderlyNetworks.includes(targetNetwork)) {
    console.log(
      chalk.blue(
        ` 📁 Attempting tenderly verification of ${contractName} on ${targetNetwork}`
      )
    );

    await tenderly.persistArtifacts({
      name: contractName,
      address: contractAddress,
    });

    let verification = await tenderly.verify({
      name: contractName,
      address: contractAddress,
      network: targetNetwork,
    });

    return verification;
  } else {
    console.log(
      chalk.grey(` 🧐 Contract verification not supported on ${targetNetwork}`)
    );
  }
};

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
