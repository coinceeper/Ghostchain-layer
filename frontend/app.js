const FACTORY_ABI = [
  {
    name: 'getSwap',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'swapId', type: 'bytes32' }],
    outputs: [
      { name: 'creator', type: 'address' },
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'sourceChain', type: 'uint256' },
      { name: 'destinationChain', type: 'uint256' },
      { name: 'commitment', type: 'bytes32' },
      { name: 'recipientGhostAddress', type: 'address' },
      { name: 'solver', type: 'address' },
      { name: 'fulfilled', type: 'bool' },
      { name: 'refunded', type: 'bool' },
      { name: 'createdAt', type: 'uint256' },
      { name: 'expiry', type: 'uint256' },
    ],
  },
  {
    name: 'isSwapActive',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'swapId', type: 'bytes32' }],
    outputs: [{ name: '', type: 'bool' }],
  },
];

const chainNames = {
  421613: 'Arbitrum Sepolia',
  84531: 'Base Sepolia',
};

let provider = null;
let signer = null;
let currentAddress = null;
let currentChainId = null;

const connectButton = document.getElementById('connectButton');
const walletStatus = document.getElementById('walletStatus');
const networkStatus = document.getElementById('networkStatus');
const resultPre = document.getElementById('result');
const getSwapButton = document.getElementById('getSwapButton');
const isActiveButton = document.getElementById('isActiveButton');

connectButton.addEventListener('click', connectWallet);
getSwapButton.addEventListener('click', getSwapDetails);
isActiveButton.addEventListener('click', getSwapActiveState);

function updateStatus() {
  if (!provider) {
    walletStatus.textContent = 'Wallet not connected';
    networkStatus.textContent = '';
    return;
  }

  walletStatus.textContent = `Connected: ${currentAddress}`;
  networkStatus.textContent = `Network: ${chainNames[currentChainId] || currentChainId}`;
}

async function connectWallet() {
  if (!window.ethereum) {
    resultPre.textContent = 'MetaMask / EIP-1193 wallet is required.';
    return;
  }

  provider = new ethers.BrowserProvider(window.ethereum);

  try {
    const accounts = await provider.send('eth_requestAccounts', []);
    signer = await provider.getSigner();
    currentAddress = accounts[0];
    const network = await provider.getNetwork();
    currentChainId = network.chainId;
    updateStatus();
    resultPre.textContent = 'Wallet connected. Enter a factory address and swap ID.';
  } catch (error) {
    resultPre.textContent = `Unable to connect wallet: ${error.message || error}`;
  }
}

function formatSwapData(swap) {
  return {
    creator: swap.creator,
    token: swap.token,
    amount: swap.amount.toString(),
    sourceChain: swap.sourceChain.toString(),
    destinationChain: swap.destinationChain.toString(),
    commitment: swap.commitment,
    recipientGhostAddress: swap.recipientGhostAddress,
    solver: swap.solver,
    fulfilled: swap.fulfilled,
    refunded: swap.refunded,
    createdAt: new Date(Number(swap.createdAt) * 1000).toISOString(),
    expiry: new Date(Number(swap.expiry) * 1000).toISOString(),
  };
}

function getFactoryContract() {
  const factoryAddress = document.getElementById('factoryAddress').value.trim();
  if (!factoryAddress) {
    throw new Error('Please enter the EphemeralFactory contract address.');
  }
  if (!signer && !provider) {
    throw new Error('Wallet is not connected.');
  }
  return new ethers.Contract(factoryAddress, FACTORY_ABI, signer || provider);
}

async function getSwapDetails() {
  try {
    const swapId = document.getElementById('swapId').value.trim();
    if (!swapId) {
      throw new Error('Please enter a swap ID.');
    }
    const contract = getFactoryContract();
    const swap = await contract.getSwap(swapId);
    const details = formatSwapData(swap);
    resultPre.textContent = JSON.stringify(details, null, 2);
  } catch (error) {
    resultPre.textContent = `Error reading swap: ${error.message || error}`;
  }
}

async function getSwapActiveState() {
  try {
    const swapId = document.getElementById('swapId').value.trim();
    if (!swapId) {
      throw new Error('Please enter a swap ID.');
    }
    const contract = getFactoryContract();
    const active = await contract.isSwapActive(swapId);
    resultPre.textContent = `Swap is active: ${active}`;
  } catch (error) {
    resultPre.textContent = `Error checking swap status: ${error.message || error}`;
  }
}
