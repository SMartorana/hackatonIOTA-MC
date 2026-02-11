// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// NPLEX LTC1 - Manages the creation of LTC1 contracts
/// 
/// This contract provides the logic for the LTC1 contract.
/// Investor tokens are protocol-level fungible coins (Coin<T>).
/// Each NPL package has its own coin type T, created via OTW.
/// Investors exit by burning (redeeming) their Coin<T> back to the contract.

module nplex::ltc1;

use nplex::registry::{Self, NPLEXRegistry};
use iota::balance::{Self, Balance};
use iota::coin::{Self, Coin, TreasuryCap};
use std::string::{Self, String};
use iota::display;
use iota::package;
use iota::clock::{Self, Clock};

// ==================== Errors ====================
const E_INSUFFICIENT_SUPPLY: u64 = 1001;
const E_INSUFFICIENT_PAYMENT: u64 = 1002;
const E_CONTRACT_REVOKED: u64 = 1003;
const E_WRONG_BOND: u64 = 1004;
const E_INVALID_SPLIT: u64 = 1005;
// 1006 removed (E_INVALID_TOKEN no longer needed — type system enforces)
const E_SUPPLY_TOO_LOW: u64 = 1007;
const E_SALES_CLOSED: u64 = 1008;
// 1009 removed (E_SALES_OPEN no longer needed — set_token_price removed)
const E_ZERO_REDEEM: u64 = 1010;
const E_INVALID_TREASURY: u64 = 1011;

/// Max investor share in BPS (95.0000%) - 6 decimals
const MAX_INVESTOR_BPS: u64 = 950_000;
const SPLIT_DENOMINATOR: u64 = 1_000_000;

/// Min total shares (decrease the dust due to divisions rounding)
const MIN_TOTAL_SHARES: u64 = 1_000_000_000;

// ==================== Structs ====================

/// The OTW for package initialization
public struct LTC1 has drop {}

/// The LTC1 Witness for Registry Binding
public struct LTC1Witness has drop {}

/// The Owner Bond (Admin Key)
/// Represents ownership and control over the package.
public struct OwnerBond has key {
    id: iota::object::UID,
    package_id: iota::object::ID,
}

/// The LTC1 Package (Shared Object)
/// Contains the state, pools, and metadata visible to everyone.
/// P = Payment coin type (e.g. IOTA, EURC)
/// T = Investor token type (user-deployed OTW coin, unique per package)
public struct LTC1Package<phantom P, phantom T> has key {
    id: iota::object::UID,
    name: String,
    document_hash: u256,
    
    // Supply & Pricing
    /// Immutable — total conceptual shares of the NPL security (never changes after creation)
    total_shares: u64,
    /// Maximum supply that can be sold to investors
    max_sellable_supply: u64,
    /// Currently minted tokens held by investors (increases on buy, decreases on redeem)
    tokens_sold: u64,
    token_price: u64,// in NANOS 1,000,000,000 = 1 iota

    // this is metadata, the value the originator of the security gave to this asset at creation
    nominal_value: u64,// in NANOS 1,000,000,000 = 1 iota
    
    // Coin Management
    /// TreasuryCap for minting/burning investor tokens (Coin<T>)
    treasury_cap: TreasuryCap<T>,

    // Pools
    funding_pool: Balance<P>,
    revenue_pool: Balance<P>,
    total_revenue_deposited: u64,
    /// Revenue reserved for owner (split at deposit time, reset on claim)
    owner_claimable: u64,
    
    // Sales Control
    /// Whether token sales are currently open (controlled by NPLEX admin)
    sales_open: bool,
    
    // Metadata & Admin
    owner_bond_id: iota::object::ID,
    creation_timestamp: u64,
    metadata_uri: String,
}

// ==================== Initialization ====================

fun init(otw: LTC1, ctx: &mut iota::tx_context::TxContext) {
    // 1. Claim Publisher
    let publisher = package::claim(otw, ctx);

    // 2. Setup Display (OwnerBond only — investor tokens get display from CoinMetadata)
    setup_display(&publisher, ctx);

    // 3. Cleanup & Transfer
    iota::transfer::public_transfer(publisher, iota::tx_context::sender(ctx));
}

#[allow(lint(share_owned))]
fun setup_display(publisher: &package::Publisher, ctx: &mut iota::tx_context::TxContext) {
    // Define Display for OwnerBond
    let bond_keys = vector[
        string::utf8(b"name"),
        string::utf8(b"description"),
        string::utf8(b"image_url"),
        string::utf8(b"project_url"),
    ];

    let bond_values = vector[
        string::utf8(b"NPLEX Owner Bond"),
        string::utf8(b"Administrative key for LTC1 Package {package_id}"),
        string::utf8(b"https://api.nplex.eu/icons/bond_gold.png"),
        string::utf8(b"https://nplex.eu"),
    ];

    let mut bond_display = display::new_with_fields<OwnerBond>(
        publisher, bond_keys, bond_values, ctx
    );
    display::update_version(&mut bond_display);

    // Share Display
    iota::transfer::public_share_object(bond_display);
}

// ==================== Public Functions ====================

/// Create a new LTC1 contract.
/// The caller must provide a TreasuryCap<T> from their deployed coin module.
/// This TreasuryCap is stored inside the package and used to mint/burn investor tokens.
public entry fun create_contract<P, T>(
    registry: &mut NPLEXRegistry,
    treasury_cap: TreasuryCap<T>,
    name: String,
    document_hash: u256,
    total_shares: u64,
    token_price: u64,
    nominal_value: u64,
    investor_split_bps: u64,
    metadata_uri: String,
    clock: &Clock,
    ctx: &mut iota::tx_context::TxContext
) {
    let owner = iota::tx_context::sender(ctx);

    // 0. Validate Treasury Cap has zero supply (fresh, no tokens minted yet)
    assert!(coin::total_supply(&treasury_cap) == 0, E_INVALID_TREASURY);

    // 1. Validate Split
    assert!(investor_split_bps <= MAX_INVESTOR_BPS, E_INVALID_SPLIT);

    // 2. Validate Total Shares
    assert!(total_shares >= MIN_TOTAL_SHARES, E_SUPPLY_TOO_LOW);

    // 3. Claim hash
    let claim = registry::claim_hash(registry, document_hash, ctx);

    // 4. Create UIDs first to get IDs (Resolves circular dependency)
    let package_uid = iota::object::new(ctx);
    let bond_uid = iota::object::new(ctx);
    
    let package_id = iota::object::uid_to_inner(&package_uid);
    let bond_id = iota::object::uid_to_inner(&bond_uid);

    // Calculate limits
    let max_sellable_supply = (((total_shares as u256) * (investor_split_bps as u256)) / (SPLIT_DENOMINATOR as u256)) as u64;

    // 5. Create the Package (Shared Object)
    let package = LTC1Package<P, T> {
        id: package_uid,
        name,
        document_hash,
        total_shares,
        max_sellable_supply,
        tokens_sold: 0,
        token_price,
        nominal_value,
        treasury_cap,
        funding_pool: balance::zero<P>(),
        revenue_pool: balance::zero<P>(),
        total_revenue_deposited: 0,
        owner_claimable: 0,
        sales_open: true,
        owner_bond_id: bond_id,
        creation_timestamp: clock::timestamp_ms(clock),
        metadata_uri,
    };

    // 6. Create the Bond (Owned Object - Admin Key)
    let bond = OwnerBond {
        id: bond_uid,
        package_id: package_id,
    };

    // 7. Bind hash with Witness
    registry::bind_executor(
        registry, 
        claim, 
        package_id, 
        LTC1Witness {}
    );

    // 8. Publish
    iota::transfer::share_object(package);
    iota::transfer::transfer(bond, owner);
}

/// Buy tokens from the package.
/// User specifies how many "shares" they want to buy (`amount`)
/// and provides payment in the payment coin (P).
/// Mints Coin<T> (investor token) and sends it to the buyer.
/// Note: Sales must be open (controlled by NPLEX admin).
public entry fun buy_token<P, T>(
    registry: &NPLEXRegistry,
    package: &mut LTC1Package<P, T>,
    mut payment: Coin<P>,
    amount: u64,
    ctx: &mut iota::tx_context::TxContext
) {
    // 0. Verify Contract Status (not revoked)
    assert!(registry::is_valid_hash(registry, package.document_hash), E_CONTRACT_REVOKED);

    // 0.5. Verify Sales are Open
    assert!(package.sales_open, E_SALES_CLOSED);

    // 1. Check supply
    assert!(amount <= package.max_sellable_supply - package.tokens_sold, E_INSUFFICIENT_SUPPLY);

    // 2. Calculate cost
    let cost = (((amount as u256) * (package.token_price as u256)) as u64);
    assert!(coin::value(&payment) >= cost, E_INSUFFICIENT_PAYMENT);

    // 3. Handle Payment
    let coin_value = coin::value(&payment);
    let paid_balance = if (coin_value == cost) {
        coin::into_balance(payment)
    } else {
        let split = coin::split(&mut payment, cost, ctx);
        iota::transfer::public_transfer(payment, iota::tx_context::sender(ctx)); // Return change
        coin::into_balance(split)
    };
    
    balance::join(&mut package.funding_pool, paid_balance);

    // 4. Mint Investor Tokens (protocol-level Coin<T>)
    package.tokens_sold = package.tokens_sold + amount;
    let investor_tokens = coin::mint(&mut package.treasury_cap, amount, ctx);
    iota::transfer::public_transfer(investor_tokens, iota::tx_context::sender(ctx));
}

/// Withdraw Funding from the package (Owner Only)
/// Requires the OwnerBond (Admin Capability)
public entry fun withdraw_funding<P, T>(
    registry: &NPLEXRegistry,
    package: &mut LTC1Package<P, T>,
    bond: &OwnerBond,
    amount: u64,
    ctx: &mut iota::tx_context::TxContext
) {
    // 0. Verify Contract Status (not revoked)
    assert!(registry::is_valid_hash(registry, package.document_hash), E_CONTRACT_REVOKED);

    // 1. Verify OwnerBond matches this package
    assert!(bond.package_id == iota::object::uid_to_inner(&package.id), E_WRONG_BOND);

    // 2. Withdraw
    let funding = coin::take(&mut package.funding_pool, amount, ctx);
    iota::transfer::public_transfer(funding, iota::tx_context::sender(ctx));
}

/// Deposit revenue into the package (Owner Only)
/// Requires the OwnerBond (Admin Capability)
/// Revenue is split at deposit time: owner gets proportional share of unsold tokens.
public entry fun deposit_revenue<P, T>(
    registry: &NPLEXRegistry,
    package: &mut LTC1Package<P, T>,
    bond: &OwnerBond,
    payment: Coin<P>,
    _ctx: &mut iota::tx_context::TxContext
) {
    // 0. Verify Contract Status (not revoked)
    assert!(registry::is_valid_hash(registry, package.document_hash), E_CONTRACT_REVOKED);

    // 1. Verify OwnerBond matches this package
    assert!(bond.package_id == iota::object::uid_to_inner(&package.id), E_WRONG_BOND);

    // 2. Split revenue at deposit time
    let amount = coin::value(&payment);
    let unsold = package.total_shares - package.tokens_sold;
    let owner_share = (((unsold as u256) * (amount as u256)) / (package.total_shares as u256) as u64);
    package.owner_claimable = package.owner_claimable + owner_share;

    // 3. Update cumulative counter
    package.total_revenue_deposited = package.total_revenue_deposited + amount;

    // 4. Deposit full amount to Revenue Pool
    balance::join(&mut package.revenue_pool, coin::into_balance(payment));
}

/// Claim Revenue for Owner
/// Owner claims all accumulated revenue from the owner_claimable pool.
/// Double-claim is structurally impossible: owner_claimable resets to 0 after each claim.
public entry fun claim_revenue_owner<P, T>(
    registry: &NPLEXRegistry,
    package: &mut LTC1Package<P, T>,
    bond: &OwnerBond,
    ctx: &mut iota::tx_context::TxContext
) {
    // Verify Contract Status (not revoked)
    assert!(registry::is_valid_hash(registry, package.document_hash), E_CONTRACT_REVOKED);

    // 1. Verify Bond
    assert!(bond.package_id == iota::object::uid_to_inner(&package.id), E_WRONG_BOND);

    // 2. Get the accumulated owner revenue
    let due = package.owner_claimable;
    if (due == 0) {
        return
    };

    // 3. Reset owner_claimable (prevents double-claim)
    package.owner_claimable = 0;

    // 4. Payout
    let payment = coin::take(&mut package.revenue_pool, due, ctx);
    iota::transfer::public_transfer(payment, iota::tx_context::sender(ctx));
}

/// Transfer Owner Bond to a new owner
/// Requires prior authorization from NPLEX via Registry
public entry fun transfer_bond(
    registry: &mut NPLEXRegistry,
    bond: OwnerBond,
    new_owner: address,
    _ctx: &mut iota::tx_context::TxContext
) {
    // 1. Validate and Consume Ticket from Registry
    registry::consume_transfer_ticket(registry, bond.package_id, new_owner, LTC1Witness {});

    // 2. Transfer Bond
    iota::transfer::transfer(bond, new_owner);
}

/// Redeem (burn) investor tokens to claim proportional share of the investor revenue pool.
/// The entire Coin<T> is consumed. For partial redemption, split the coin beforehand.
/// This is the ONLY way for investors to extract value from the contract.
/// Allowed even if the contract is revoked (so investors can always exit).
/// Cross-package redemption is impossible: Coin<T> only matches LTC1Package<P, T>.
public entry fun redeem<P, T>(
    package: &mut LTC1Package<P, T>,
    investor_coin: Coin<T>,
    ctx: &mut iota::tx_context::TxContext
) {
    // 1. Validate
    let amount = coin::value(&investor_coin);
    assert!(amount > 0, E_ZERO_REDEEM);

    // 2. Calculate payout from investor portion of pool
    let investor_pool = balance::value(&package.revenue_pool) - package.owner_claimable;
    let payout = (((amount as u256) * (investor_pool as u256)) / (package.tokens_sold as u256) as u64);

    // 3. Burn investor tokens (entire coin consumed)
    coin::burn(&mut package.treasury_cap, investor_coin);

    // 4. Update state
    package.tokens_sold = package.tokens_sold - amount;

    // 5. Pay out
    if (payout > 0) {
        let payment = coin::take(&mut package.revenue_pool, payout, ctx);
        iota::transfer::public_transfer(payment, iota::tx_context::sender(ctx));
    };
}

/// Close sales permanently for a package. One-way — cannot be reopened.
/// Requires prior authorization from NPLEX via Registry.
/// Only the address authorized by NPLEX can execute this.
public entry fun close_sales<P, T>(
    registry: &mut NPLEXRegistry,
    package: &mut LTC1Package<P, T>,
    ctx: &mut iota::tx_context::TxContext
) {
    assert!(package.sales_open, E_SALES_CLOSED);
    let contract_id = iota::object::uid_to_inner(&package.id);
    let toggler = iota::tx_context::sender(ctx);
    registry::consume_sales_toggle_ticket(registry, contract_id, toggler, LTC1Witness {});
    package.sales_open = false;
}

// ==================== Accessors ====================

public fun is_sales_open<P, T>(package: &LTC1Package<P, T>): bool {
    package.sales_open
}

public fun owner_claimable<P, T>(package: &LTC1Package<P, T>): u64 {
    package.owner_claimable
}

/// Verify if a proposed document hash matches the package's registered hash
public fun verify_document<P, T>(package: &LTC1Package<P, T>, document_hash: u256): bool {
    package.document_hash == document_hash
}
