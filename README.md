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

Each NPL Package is a separate smart contract that issues two distinct types of assets and maintains one shared state.

### Layer 1: NPLEX Registry (Validation Layer)
- Managed by NPLEX
- Audits and approves NPL package document hashes
- Prevents duplicate LTC1 contracts for same hash
- Can invalidate contracts (e.g., when all debts recovered)
- Only NPLEX admin can register hashes after kyc of financial institutions and the creation of the NPL package

### Layer 2: LTC1 Contracts (Token Layer)
Each LTC1 contract represents **one NPL package** and issues two types of assets:

#### 1. LTC1 Tokens (For Investors)
- **Role:** Capital contribution & Revenue rights.
- **Properties:** Transferable (`store`), Tradeable.
- **Acquisition:** Bought by investors funds to finance the package.

#### 2. Owner Bond (For Owner)
- **Role:** Represents **legal ownership** of the NPL package & "Skin in the Game".
- **Properties:** **LOCKED** (NO `store`), Non-transferable without NPLEX approval.
- **Acquisition:** Minted to whoever creates the LTC1 (must prove NPL ownership to NPLEX). Can be transferred with NPLEX approval.

### NPL Package Contract

Each package contains:
- **Document Hash**: SHA-256 of ZIP file (immutable, the actual hash of the NPL package documents)
- **Token Supply**: Fixed supply minted at creation (non-burnable)
- **OwnerBond**: Represents ownership — whoever holds it has executive power over the package
- **Revenue Pool**: IOTA deposited by the Bond holder when debts are recovered
- **Metadata**: Nominal value, creation date, etc.

## Data Structures

### NPLEX Registry Contract

```move
// Admin capability for NPLEX
struct NPLEXAdminCap has key, store {
    id: UID,
}

// Registry of approved hashes (shared object)
struct NPLEXRegistry has key {
    id: UID,
    approved_hashes: Table<vector<u8>, HashInfo>,  // hash -> info
}

// Information about approved hash
struct HashInfo has store {
    approved_timestamp: u64,
    auditor: address,
    is_revoked: bool,
    contract_id: Option<ID>,  // ID of LTC1 contract if created, None otherwise
}
```

### LTC1 Contract

```move
// 1. Investor Token (Transferable)
struct LTC1Token has key, store {
    id: UID,
    balance: u64,              // Number of "shares" this token represents
    package_id: ID,            // Reference to parent LTC1Package
    claimed_revenue: u64,      // Total IOTA this token has already claimed
}

// 2. Servicer Bond (Locked - NO STORE capability)
// Servicer must hold this to claim their share. Cannot sell.
struct ServicerBond has key {
    id: UID,
    balance: u64,             // e.g. 50% of supply
    servicer: address,        // Owner
    package_id: ID,           // Reference to parent
    claimed_revenue: u64,     // Track claims
}

// 3. Main LTC1 Package (shared object)
struct LTC1Package has key {
    id: UID,
    document_hash: vector<u8>,        // SHA-256 of ZIP (validated)
    total_supply: u64,                // Total token shares (immutable)
    tokens_sold: u64,                 // Track how many tokens sold
    token_price: u64,                 // Price per token in NANOS
    nominal_value: u64,               // Face value of NPL package
    
    funding_pool: Balance<IOTA>,      // IOTA from token sales (Bond holder withdrawable)
    revenue_pool: Balance<IOTA>,      // Debt recovery proceeds (token/bond holder claimable)
    total_revenue_deposited: u64,     // Total IOTA ever deposited to revenue_pool
    
    servicer: address,                // Current Bond holder (updated on transfer)
    creation_timestamp: u64,
    metadata_uri: String,             // IPFS/HTTP link
}
```

## API Reference

### NPLEX Registry Module

| Function | Description |
|----------|-------------|
| `init()` | Initialize registry with NPLEX admin capability |
| `register_hash()` | NPLEX registers approved package hash |
| `is_valid_hash()` | Check if hash is approved and not revoked |
| `mark_hash_used()` | Mark hash as used (prevent duplicates) |
| `is_hash_used()` | Check if hash already has a contract |
| `revoke_hash()` | Emergency revoke (if fraud detected) |
| `unrevoke_hash()` | Un-revoke a hash (if revocation was in error) |

### LTC1 Module

| Function | Description |
|----------|-------------|
| `create_ltc1()` | Initialize new LTC1 with hash validation and token minting |
| `buy_tokens()` | Investors purchase tokens (IOTA → funding pool) |
| `withdraw_funding()` | Bond holder withdraws funding pool (requires ServicerBond) |
| `deposit_revenue()` | Bond holder deposits recovered funds (requires ServicerBond) |
| `claim_revenue_investor()` | Token holders claim proportional revenue |
| `claim_revenue_owner()` | Owner claims revenue via locked Bond |
| `transfer_owner_bond()` | Restricted transfer (requires NPLEX approval) |
| `verify_document()` | Verify document hash matches |
| `get_package_info()` | View package metadata |

## Workflow

1. **NPLEX Audits**: NPLEX audits NPL package documents and approves hash
2. **Hash Registration**: NPLEX registers approved hash in the Registry
3. **LTC1 Creation**: Creator creates LTC1 contract (validates hash against Registry)
4. **Token Sale**: Investors buy tokens directly from LTC1 using `buy_tokens()`, IOTA goes to funding pool
5. **Funding Withdrawal**: Bond holder withdraws IOTA from funding pool to finance NPL acquisition
6. **Recovery**: Bond holder recovers debt → deposits IOTA into revenue pool (requires ServicerBond)
7. **Claim**: Token holders claim proportional share from revenue pool
8. **Termination**: NPLEX revokes hash in Registry (when all credits resolved) → blocks operations except claims

## Revenue Distribution Mechanism

### How it works

1. **Servicer deposits** X IOTA into revenue_pool (from recovered debts)
2. **Package tracks** `total_revenue_deposited` (cumulative)
3. **Token holder claims** with their token
4. **Contract calculates** claimable amount:
   ```
   total_entitled = (token.balance / total_supply) * total_revenue_deposited
   claimable = total_entitled - token.claimed_revenue
   ```
5. **Token updated**: `token.claimed_revenue += claimable`
6. **Prevents double-claiming**: Each token remembers what it claimed

### Example

- Total Supply: 1,000 token shares
- Alice's token: 250 shares (25%)
- Servicer deposits: 100 IOTA (total_revenue_deposited = 100)
- Alice claims: 
  - Entitled: 250/1000 * 100 = 25 IOTA
  - Already claimed: 0
  - Receives: 25 IOTA
  - Token updated: claimed_revenue = 25
- Servicer deposits another 200 IOTA (total_revenue_deposited = 300)
- Alice claims again:
  - Entitled: 250/1000 * 300 = 75 IOTA
  - Already claimed: 25
  - Receives: 50 IOTA
  - Token updated: claimed_revenue = 75
- **Alice transfers token to Bob**
- Bob can claim:
  - Entitled: 250/1000 * 300 = 75 IOTA
  - Already claimed (by token): 75
  - Receives: 0 IOTA No double-claim!

## Key Design Decisions

### 1. ServicerBond = Ownership
The **ServicerBond** represents **legal ownership and executive power** over the NPL package.

**Why?** To prevent owners from dumping "bad" packages on investors and walking away.
- To create an LTC1, you must prove to NPLEX that you legally own the NPL.
- The contract mints a **ServicerBond** (e.g., 50% of supply) directly to the creator.
- This Bond has **NO `store` capability** — it **cannot be freely transferred or sold**.
- The owner is forced to hold the asset until maturity to realize any value.
- **Whoever holds the Bond can**: withdraw funding, deposit revenue, and claim their share.

**Restricted Transfer (with NPLEX Approval):**
If the Bond holder wants to sell their ownership/servicing rights:
1. Seller and buyer create a sale contract (off-chain legal agreement)
2. NPLEX reviews and notarizes the sale contract → hash is registered on-chain
3. NPLEX authorizes the bond transfer via `transfer_servicer_bond()` (requires `NPLEXAdminCap`)
4. Bond is transferred to the new owner, and `LTC1Package.servicer` is updated

This ensures all ownership transfers are legally documented and auditable.

### 2. Token Lifecycle
```
Creation (Bank) → Mints LTC1 Tokens (for sale) + ServicerBond (to Bank) →
Bank sells LTC1 Tokens to Investors → IOTA funding goes to Bank →
Bank sells ServicerBond to Servicer (requires NPLEX approval) →
Servicer works to recover debt → Deposits IOTA to Revenue Pool →
Investors claim via LTC1 Tokens (Tradeable) →
Servicer claims via ServicerBond (Locked until transferred with NPLEX approval)
```

**Token Purchase (Primary Sale):**
- Creator (Bank) creates the package and receives both LTC1 Tokens and ServicerBond.
- Creator sells LTC1 Tokens to investors (Primary Market) to raise liquidity.
- Creator may sell ServicerBond to a Servicer (requires NPLEX approval).

**Dual Pool & Revenue:**
- **Revenue Pool**: Single pool for ALL recovered funds.
- **Distribution**: Proportional to supply (e.g., if Servicer holds 50% Bond, they get 50% of revenue).

### 3. Cumulative Claims
Both Investors and Bond holder claim **all accumulated unclaimed revenue** when calling their claim functions.

**Example:**
- Total Supply: 1000 (500 Tokens + 500 Bond)
- Alice: 10 Tokens (1%)
- Bond holder: 500 Bond (50%)
- Deposit: 1000 IOTA
- **Alice claims**: 10 IOTA (1%)
- **Bond holder claims**: 500 IOTA (50%)
- **Token/Bond tracks**: `claimed_revenue` to prevent double-claiming.

**Note:** Unclaimed revenue stays in the contract forever. Holders can claim at any time.

### 4. Default Scenario
If the Bond holder never recovers any debts:
- Revenue pool remains empty
- Tokens and Bond remain valid but worthless
- Bond holder loses their time/effort (Skin in the Game penalty)
- NPLEX may initiate legal action

### 5. Metadata & Documentation
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
- Servicer failed obligations

**Post-termination**: Tokens remain as proof of investment.

## Security Considerations

> [!IMPORTANT]
> Critical security features

- **Hash Validation**: LTC1 creation requires approved hash from NPLEX Registry
- **Uniqueness Enforcement**: Only one LTC1 contract can be created per hash
- **Hash Immutability**: Document hash cannot be changed after registration
- **Dual Pools**: Funding and revenue pools are separate
- **No Token Minting**: Tokens only minted once at creation
- **No Token Burning**: Tokens cannot be destroyed
- **Bond-Based Authorization**: Deposit and withdrawal require passing the ServicerBond object (not just address check)
- **Anti-Double-Claim**: Token-level `claimed_revenue` tracking prevents double-claims even after transfer
- **Transfer-Safe**: Tokens carry claim history with them when transferred
- **Revocation Control**: NPLEX can halt all operations except claims via Registry
- **Price Immutability**: Token price is set at creation and cannot change
- **Locked Bond**: Bond cannot be transferred without NPLEX approval (Critical Security Feature)
- **Emergency Revoke**: NPLEX can invalidate fraudulent contracts
- **Permanent Claims**: Unclaimed revenue stays in contract forever — holders can claim at any time

## Business Model (Future)

- **No fees** for hash registration or LTC1 creation in MVP
- Revenue streams (planned):
  - Platform consultation services
  - LTC1 management services
  - Possible transaction fees (TBD)

## Compliance & Scope (MVP)

- **No jurisdiction/country fields** - compliance deferred to post-MVP
- Focus: Technical proof-of-concept for tokenization

## Future Implementations

### Granular Revocation Control
Currently, revocation is a binary state. Future versions will support granular permissions:
- **Block Deposits Only**: Stop new investments/deposits but allow withdrawals.
- **Block Trading**: Stop token transfers while allowing claims.
- **Full Freeze**: Stop all operations for investigation.

