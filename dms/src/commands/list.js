export const command = 'list'

export const desc = 'Display the contracts list'

// prettier-ignore
export const builder = yargs => yargs

// Implementation

import {getAccounts} from '../utils/web3'
import runCommand from '../utils/run-command'
import getContractAPIs from '../utils/get-contract-apis'
import {fetchOwnerContracts} from '../utils/contract-api'

export function handler(argv) {
  return runCommand(() => getList())
}

async function getList() {
  // TODO: ensure json rpc is running

  const accounts = await getAccounts()
  const {registry} = await getContractAPIs()
  const contracts = await fetchOwnerContracts(registry, accounts[0])
  for (let i = 0; i < contracts.length; ++i) {
    console.error(contracts[i])
  }
}
