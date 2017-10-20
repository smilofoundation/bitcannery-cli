const assert = require('chai').assert
const BigNumber = require('bignumber.js')

const Web3 = require('web3')
const web3 = new Web3(new Web3.providers.HttpProvider('http://localhost:8545'))

const encryption = require('../utils/encryption')
const {unpackEllipticParts} = require('../utils/pack')
const {trim0x, ensure0x} = require('../utils/prefix')
const {getActiveKeepers, getActiveKeeperAddresses} = require('../utils/contract-api')

const {bobPrivateKey,
  bobPublicKey,
  keeperPrivateKeys,
  keeperPublicKeys,
  numKeepersToRecover} = require('./data')


// general helpers

async function assertTxFails(txResultPromise, message) {
  const txProps = await inspectTransaction(txResultPromise)
  if (txProps.success) {
    assert(false, 'transaction was expected to fail but succeeded' +
      (message ? ': ' + message : '')
    )
  }
  return txProps
}


async function assertTxSucceeds(txResultPromise, message) {
  const txProps = await inspectTransaction(txResultPromise)
  if (!txProps.success) {
    assert(false, 'transaction was expected to succeed but failed' +
      (message ? ': ' + message : '')
    )
  }
  return txProps
}


async function inspectTransaction(txResultPromise) {
  const txResult = await txResultPromise
  const tx = await web3.eth.getTransaction(txResult.tx)
  const {receipt} = txResult
  const success = receipt.status !== undefined
    ? receipt.status === '0x1' || receipt.status === 1 // Since Byzantium fork
    : receipt.cumulativeGasUsed < tx.gas // Before Byzantium fork (current version of TestRPC)
  const txPriceWei = new BigNumber(tx.gasPrice).times(receipt.cumulativeGasUsed)
  return {result: txResult, success, txPriceWei}
}


function printEvents(txResult) {
  console.info('Events:', txResult.logs
    .map(log => {
      if (!log.event) return null
      const argsDesc = Object.keys(log.args)
        .map(argName => `${argName}: ${log.args[argName]}`)
        .join(', ')
      return `${log.event}(${argsDesc})`
    })
    .filter(x => !!x)
  )
}


async function getAccountBalance(account) {
  const bal = await web3.eth.getBalance(account)
  return new BigNumber('' + bal)
}


async function getAccountBalances(...addrs) {
  return await Promise.all(addrs.map(addr => getAccountBalance(addr)))
}


function bigSum(arr, accessor = (x => x)) {
  return arr.reduce((s, el) => s.plus('' + accessor(el)), new BigNumber(0))
}


function stringify(x) {
  return '' + x
}


// contract-specific helpers


async function getActiveKeepersBalances(...keeperAddrs) {
  const keepers = await getActiveKeepers(keeperAddrs)
  return keepers.map(keeper => keeper.balance)
}


async function getTotalKeepersBalance(contract) {
  const keeperAddresses = await getActiveKeeperAddresses(contract)
  const keepers = await getActiveKeepers(keeperAddresses)
  return bigSum(keepers, keeper => keeper.balance)
}


async function prepareLegacyData(legacyString, selectedKeeperIndices, aesCounter) {
  return await encryption.encryptData(
    ensure0x(new Buffer(legacyString).toString('hex')),
    bobPublicKey,
    keeperPublicKeys.filter((_, index) => selectedKeeperIndices.indexOf(index) != -1),
    numKeepersToRecover,
    aesCounter
  )
}


async function decryptLegacy(encryptedData, dataHash, suppliedKeyParts, aesCounter) {
  const decrypted = await encryption.decryptData(
    encryptedData,
    dataHash,
    bobPrivateKey,
    suppliedKeyParts,
    aesCounter
    )
  return Buffer.from(trim0x(decrypted), 'hex').toString('utf8')
}


async function decryptKeyPart(encryptedKeyParts, keeperSubmittedPartIndex, keeperIndex) {
  const keyParts = unpackEllipticParts(trim0x(encryptedKeyParts), 2)
  return await encryption.ecDecrypt(
      keyParts[keeperSubmittedPartIndex],
      keeperPrivateKeys[keeperIndex]
    )
}


module.exports = {
  web3,
  assertTxFails,
  assertTxSucceeds,
  inspectTransaction,
  printEvents,
  getAccountBalance,
  getAccountBalances,
  bigSum,
  stringify,
  getActiveKeepersBalances,
  getTotalKeepersBalance,
  prepareLegacyData,
  decryptKeyPart,
  decryptLegacy,
}
