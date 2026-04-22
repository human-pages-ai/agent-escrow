# AgentEscrow

Permissionless, non-custodial smart contract escrow for agent-human transactions on Base.

USDC-only. EIP-712 signed verdicts. Supports both EOA arbitrators and contract arbitrators via EIP-1271 (e.g. reality.eth).

## How it works

```
Agent (depositor)                    Human (payee)
    |                                    |
    |-- deposit(jobId, payee, arb) ----->|  USDC locked in contract
    |                                    |
    |         [human does the work]      |
    |                                    |
    |-- markComplete() ----------------->|  starts dispute window
    |                                    |
    |   (no dispute within window)       |
    |                                    |-- release()  → payee gets paid
    |                                    |
    |   OR: either party disputes        |
    |                                    |
    |-- dispute() ---------------------->|  arbitrator resolves
    |                                    |
    |       [arbitrator signs verdict]   |
    |                                    |
    |-- resolve(verdict, sig) ---------->|  split per verdict
```

## Arbitration

The arbitrator is chosen at deposit time. Any address works — the contract is arbitrator-agnostic.

**EOA arbitrator**: Signs an EIP-712 `Verdict` struct off-chain. Anyone can submit the signed verdict to resolve the dispute.

**Contract arbitrator (EIP-1271)**: A contract implements `isValidSignature()` to validate verdicts. This enables integration with decentralized oracle systems like [reality.eth](https://reality.eth.limo/).

### reality.eth integration

The `RealityETHAdapter` bridges reality.eth oracle answers to AgentEscrow verdicts:

1. Depositor creates a question on reality.eth directly (posts bonds, sets timeout)
2. Reality.eth participants answer and challenge via bond escalation
3. After the answer finalizes, anyone calls `adapter.generateVerdict(jobId, questionId)`
4. The adapter reads the oracle result, computes the USDC split, and approves the EIP-712 digest
5. Anyone calls `escrow.resolve()` — AgentEscrow verifies via EIP-1271

Answer encoding: `0` = payee wins, `1` = depositor wins, `2-99` = payee gets N%.

## Safety mechanisms

- **Dispute window**: 3-30 days (configurable per job) for either party to dispute after work is marked complete
- **Arbitrator timeout**: If the arbitrator doesn't resolve within 7 days, `forceRelease()` pays the payee 100%
- **Cancel proposals**: Depositor can propose a split, payee accepts or ignores (expires in 7 days)
- **Replay protection**: EIP-712 domain separation (chain, contract, job) + nonce-based verdict execution

## Test suite

256 tests covering all flows and attack vectors:

| Suite | Tests | Coverage |
|-------|-------|---------|
| AgentEscrow (flows + regression) | 71 | Happy paths, negative cases, edge cases |
| RealityETH integration | 23 | Oracle bridging, bond escalation, timeout races |
| Reentrancy | 10 | Classic, cross-function, read-only |
| Signature attacks | 14 | Replay, malleability, zero-address |
| State machine | 72 | Exhaustive (state, function) matrix |
| ERC20 attacks | 14 | Fee-on-transfer, rebasing, blacklist |
| Economic attacks | 20 | Front-running, collusion, dust |
| Griefing/DoS | 20 | Fund locking, admin abuse, timeouts |
| PoC | 12 | Blacklist resolve, funded lock |

```sh
forge test
```

## Deploy

```sh
# Set environment
export DEPLOYER_PRIVATE_KEY=0x...
export RELAYER_ADDRESS=0x...
export USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e  # Base Sepolia USDC

# Deploy
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast

# Verify
forge verify-contract <address> src/AgentEscrow.sol:AgentEscrow \
  --chain base-sepolia \
  --constructor-args $(cast abi-encode "constructor(address)" $USDC_ADDRESS)
```

## License

MIT
