# NPLEX - NPL Tokenization Platform

## Project Overview

NPLEX is a blockchain-based platform for tokenizing Non-Performing Loan (NPL) packages using the IOTA network. The platform enables retail investors to participate in NPL investments through fractional ownership via the LTC1 (Loan Token Contract) standard.

**Core Philosophy:** Align incentives between Investors (Capital) and Servicers (Labor) through "Skin in the Game".

## Core Concepts

### Business Flow

1. **NPL Acquisition**: A bank creates an NPL package
2. **Tokenization**: The package is tokenized via LTC1 contract
3. **Retail Funding**: Retail investors buy tokens to finance the bank
4. **Revenue Distribution**: As debts are recovered or package is resold, revenue flows back to token holders
5. **Contract Closure**: When package is fully liquidated or resold, contract closes.

### Revenue Sources

The LTC1 contract receives IOTA through **2 channels**:
1. **Debt Recovery**: Servicer recovers debts and deposits recovered amounts
2. **Package Resale**: If the package is sold to another party, sale proceeds are deposited

## Architecture: The 3-Asset Model

The architecture is named after the **three distinct Move Objects** that define each NPL Package. This separation ensures security and clear separation of concerns:

1.  **LTC1Package (Shared Object)**: The "State". Holds the pools (funds/revenue), metadata, and business logic. It is shared so everyone can access it.
2.  **LTC1Token (Owned Object - Many)**: The "Investment". Tradeable NFTs representing a share of the revenue. Held by investors.
3.  **OwnerBond (Owned Object - One)**: The "Control". A simplified non-tradeable NFT representing legal ownership and admin rights. Held by the package owner.

### Layer 1: NPLEX Registry (Validation Layer)
- Managed by NPLEX
- Audits and approves NPL package document hashes
- Prevents duplicate LTC1 contracts for same hash
- Can invalidate contracts (e.g., when all debts recovered)
- Only NPLEX admin can register hashes after kyc of financial institutions and the creation of the NPL package

### Layer 2: LTC1 Contracts (Token Layer)
Each LTC1 contract operates using these assets:

#### 1. LTC1 Tokens (For Investors)
- **Role:** Capital contribution & Revenue rights.
- **Properties:** Transferable (`store`), Tradeable.
- **Acquisition:** Investors mint these by paying into the funding pool.

#### 2. Owner Bond (For Owner)
- **Role:** Represents **legal ownership** of the NPL package & "Skin in the Game".
- **Properties:** **LOCKED** (NO `store`), Non-transferable without NPLEX approval.
- **Acquisition:** Minted to whoever creates the LTC1. Can be transferred with NPLEX approval.


## API Reference

### NPLEX Registry Module

| Function | Description |
|----------|-------------|
| `register_hash` | NPLEX registers approved package hash (Admin Only) |
| `revoke_hash` | Emergency revoke if fraud detected (Admin Only) |
| `unrevoke_hash` | Un-revoke a hash (Admin Only) |
| `add_executor` | Authorize a module (LTC1) to bind to hashes (Admin Only) |
| `remove_executor` | De-authorize a module (Admin Only) |
| `authorize_transfer` | Authorize the transfer of an OwnerBond (Admin Only) |
| `claim_hash` | Start the contract creation process by claiming a hash |
| `bind_executor` | Bind a claimed hash to a new contract ID |
| `consume_transfer_ticket` | Consume authorization to execute a Bond transfer |
| `is_valid_hash` | Check if hash is approved and not revoked |
| `get_hash_info` | Get full status of a registered hash |

### LTC1 Module

| Function | Description |
|----------|-------------|
| `create_contract` | Initialize new LTC1 with hash validation and token minting |
| `buy_token` | Investors purchase tokens (IOTA → funding pool) |
| `withdraw_funding` | Owner withdraws raised capital (requires OwnerBond) |
| `deposit_revenue` | Owner deposits recovered funds (requires OwnerBond) |
| `claim_revenue` | Token holders claim proportional revenue |
| `claim_revenue_owner` | Owner claims revenue via locked Bond |
| `transfer_bond` | Restricted transfer (requires NPLEX approval) |
| `verify_document` | Verify document hash matches (Public) |
| `balance` | View token balance (Public) |
| `claimed_revenue` | View total revenue claimed by a token (Public) |

## Workflow

1. **NPLEX Audits**: NPLEX audits NPL package documents and approves hash
2. **Hash Registration**: NPLEX registers approved hash in the Registry
3. **LTC1 Creation**: Creator creates LTC1 contract (validates hash against Registry)
4. **Token Sale**: Investors buy tokens directly from LTC1 using `buy_tokens()`, IOTA goes to funding pool
5. **Funding Withdrawal**: Bond holder withdraws IOTA from funding pool to finance NPL acquisition
6. **Recovery**: Bond holder recovers debt → deposits IOTA into revenue pool (requires OwnerBond)
7. **Claim**: Token holders claim proportional share from revenue pool
8. **Termination**: NPLEX revokes hash in Registry (when all credits resolved) → blocks operations except claims

## Revenue Distribution Mechanism (Proportional / Pari-Passu)

Unlike complex **Waterfall Distribution** (or Tranche-based) models where Senior bonds get paid before Junior bonds, LTC1 uses a simple **Proportional Distribution** model. Every token holder is entitled to a share of the revenue exactly equal to their percentage of ownership in the total supply.

## Key Design Decisions

### 1. OwnerBond = Ownership
The **OwnerBond** represents **legal ownership and executive power** over the NPL package.

**Why?** To enforce **Risk Retention** (or "Skin in the Game").
In securitization markets, regulations often require the originator of a security to retain a certain percentage of the risk (e.g. 5%) to ensure their incentives are aligned with investors. If the asset performs poorly, the originator suffers losses alongside the investors.

The **OwnerBond** enforces this by locking a portion of the supply with the creator/owner. This bond cannot be sold on the open market, ensuring the owner remains committed to the asset's performance.

  **Token Purchase (Primary Sale):**
- Creator (Bank) creates the package and receives **only the OwnerBond**.
- Investors call `buy_tokens()` to purchase shares. The contract **mints new LTC1 Tokens (NFTs)** directly to the investor.
- Creator may sell OwnerBond to a Servicer (requires NPLEX approval).
- The OwnerBond represents the **legal ownership** of the NPL package and the **executive power** to manage it, and, in the context of this contract, it also represents all unsold shares of the NPL package and the right to: claim the revenue from tokens sold, withdraw the funding pool, deposit the revenue, and transfer the bond with NPLEX approval.

### 2. Cumulative Claims
Both Investors and Bond holder claim **all accumulated unclaimed revenue** when calling their claim functions.

### 3. Default Scenario
If the Bond holder never recovers any debts:
- Revenue pool remains empty
- Tokens and Bond remain valid but worthless
- Bond holder loses their time/effort (Skin in the Game penalty)
- NPLEX may initiate legal action

### 4. Metadata & Documentation
- **Document Hash**: SHA-256 of NPL package ZIP (immutable)
- **Metadata URI**: IPFS/HTTPS link to documents
- **On-chain**: Minimal metadata to save gas

## Contract Termination

**Trigger**: NPLEX sets `is_revoked = true` in Registry for the package hash

**When revoked:**
- **buy_tokens()**: Blocked - No new token purchases
- **withdraw_funding()**: Blocked - Bond holder cannot withdraw
- **deposit_revenue()**: Blocked - Bond holder cannot deposit
- **claim_revenue()**: Allowed - Holders can claim existing revenue forever
- **transfer_token()**: Allowed - Tokens remain tradeable

**Revocation reasons:**
- All debts fully recovered (package liquidated)
- Fraud detected (legal action initiated)

**Post-termination**: Tokens remain as proof of investment as well as the OwnerBond as proof of ownership.

## Business Model (Future)

- **No fees** for hash registration or LTC1 creation in MVP
- Revenue streams (planned):
  - Platform consultation services
  - LTC1 management services
  - Possible transaction fees (TBD when NPLEX must be involved, free otherwise)

## Compliance & Scope (MVP)

- **No jurisdiction/country fields** - compliance deferred to post-MVP
- Focus: Technical proof-of-concept for tokenization

## Future Implementations

### Granular Revocation Control
Currently, revocation is a binary state. Future versions will support granular permissions:
- **Block Deposits Only**: Stop new investments/deposits but allow withdrawals.
- **Block Trading**: Stop token transfers while allowing claims.
- **Full Freeze**: Stop all operations for investigation.

