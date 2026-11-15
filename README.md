# Cross-Chain Payment Splitter

A Foundry project that splits ETH or ERC-20 payments among up to 10 registered
recipients by percentage, with optional **cross-chain** distribution and a
multi-asset router that normalises USDC / USDT / ETH to USDC before splitting.

Deployed on **Arbitrum** (chain ID `42161`).

## Architecture

```
                          ┌────────────────────────────┐
                          │        PaymentRouter       │
                          │  accepts USDC / USDT / ETH │
                          │  normalises to USDC         │
                          └─────────────┬──────────────┘
                                        │ _distribute(USDC, amount)
                                        ▼
                          ┌────────────────────────────┐
                          │     CrossChainSplitter     │
                          │  splits by shareBips        │
                          │  ┌──────────────────────┐  │
                          │  │ same-chain recipient │─┼──► on-chain transfer (ETH / ERC-20)
                          │  └──────────────────────┘  │
                          │  ┌──────────────────────┐  │
                          │  │ cross-chain recipient│─┼──► queueCrossChainPayment()
                          │  └──────────────────────┘  │
                          └─────────────┬──────────────┘
                                        │
                    ┌───────────────────┼───────────────────┐
                    ▼                   ▼                   ▼
              Recipient A           Recipient B           Recipient C
             (60% share)           (30% share)           (10% share)
```

### Cross-chain payment flow

```
PAYER ──payInETH──► PaymentRouter ──_distribute──► CrossChainSplitter
                                                          │
                                              for each recipient:
                                              resolveChainId(account)
                                                          │
                                              ┌───────────┴───────────┐
                                              ▼                       ▼
                                     chain == Arbitrum        chain != Arbitrum
                                              │                       │
                                              ▼                       ▼
                                     on-chain transfer        CrossChainTransfer struct
                                     (call / safeTransfer)    emit CrossChainPaymentQueued
                                                              │
                                                              ▼
                                              ┌─────────────────────────┐
                                              │   REAL BRIDGE PLUG-IN   │
                                              │                         │
                                              │ Wormhole:               │
                                              │   IWormhole(bridge)     │
                                              │     .sendPayload{value} │
                                              │     (targetChainId,     │
                                              │      recipientBytes,    │
                                              │      abi.encode(transfer))│
                                              │                         │
                                              │ LayerZero:              │
                                              │   ILayerZero(bridge)    │
                                              │     .send{value}        │
                                              │     (targetChainId,     │
                                              │      recipientBytes,    │
                                              │      adapterParams)     │
                                              └─────────────────────────┘
```

## Contracts

| File | Purpose |
|------|---------|
| `src/PaymentSplitter.sol` | Core splitter: registers up to 10 recipients by basis-point share, accepts ETH or ERC-20, emits `PaymentReceived`, stores per-recipient history. |
| `src/CrossChainSplitter.sol` | Extends `PaymentSplitter`. When a recipient's resolved chain ID differs from the current chain, the share is encoded as a `CrossChainTransfer` and emitted via `CrossChainPaymentQueued`. A mock `IBridge` interface is defined; the real bridge call is commented at the plug-in point. |
| `src/PaymentRouter.sol` | Accepts USDC / USDT / ETH, normalises each to USDC using a mock price feed, then forwards to the splitter. |
| `src/MockBridge.sol` | Minimal `IBridge` implementation for local deployments. |
| `test/PaymentSplitter.t.sol` | Foundry tests covering registration, ETH / ERC-20 splits, cross-chain queuing, reverts, and fuzz tests. |
| `scripts/deploy.ts` | TypeScript (ethers.js) deploy script that deploys all contracts and registers three sample recipients. |

## Where real bridge protocols plug in

In `CrossChainSplitter._queueCrossChainPayment`, replace the commented-out
block with the actual bridge call:

- **Wormhole**: `IWormhole(bridge).sendPayload{value: fee}(targetChainId, recipientBytes, payload)`
- **LayerZero**: `ILayerZero(bridge).send{value: fee}(targetChainId, recipientBytes, adapterParams)`

The `IBridge` interface is intentionally minimal so either protocol can be
dropped in behind it.

## Real-world use cases

- **DAO treasury distributions** — split protocol revenue, grants, or
  contributor rewards across a fixed set of recipients on multiple chains.
- **Freelancer / gig payment splitting** — a client pays once and the platform
  automatically routes the correct share to each freelancer, even if they live
  on a different chain.
- **Multi-chain payroll** — pay remote teams in USDC regardless of the chain
  they receive on.
- **Streaming / recurring payouts** — the splitter can be called repeatedly to
  accumulate and distribute funds on a schedule.

## Setup

```bash
forge build
forge test
```

## Deployment

```bash
forge script scripts/deploy.ts --broadcast
```