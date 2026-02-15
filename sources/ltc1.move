// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// NPLEX LTC1 - Manages the creation of LTC1 contracts
/// 
/// This contract provides the logic for the LTC1 contract.

module nplex::ltc1;

use nplex::registry::{Self, NPLEXRegistry};
use nplex::events;
use nplex::display_utils;

use iota::balance::{Self, Balance};
use iota::coin::{Coin};
use std::string::String;
use iota::package;
use iota::clock::{Self, Clock};
use iota_notarization::notarization::{Self, Notarization};

// ==================== Errors ====================
const E_INSUFFICIENT_SUPPLY: u64 = 1001;
const E_INSUFFICIENT_PAYMENT: u64 = 1002;
const E_CONTRACT_REVOKED: u64 = 1003;
const E_WRONG_BOND: u64 = 1004;
const E_INVALID_SPLIT: u64 = 1005;
const E_INVALID_TOKEN: u64 = 1006;
const E_SUPPLY_TOO_LOW: u64 = 1007;
const E_SALES_CLOSED: u64 = 1008;
const E_ZERO_AMOUNT: u64 = 1009;
const E_INSUFFICIENT_BALANCE: u64 = 1010;
const E_INVALID_AMOUNT: u64 = 1011;

/// Max investor share in BPS (95.0000%) - 6 decimals
const MAX_INVESTOR_BPS: u64 = 950_000;
const SPLIT_DENOMINATOR: u64 = 1_000_000;

/// Min total supply (decrease the dust due to divisions rounding)
const MIN_SUPPLY: u64 = 1_000_000_000;

// ==================== Display Constants ====================

const BOND_DISPLAY_NAME: vector<u8> = b"NPLEX Owner Bond";
const BOND_DISPLAY_DESCRIPTION: vector<u8> = b"Administrative key for LTC1 Package {package_id}";
const BOND_DISPLAY_IMAGE_URL: vector<u8> = b"https://api.nplex.eu/icons/bond_gold.png";
const BOND_DISPLAY_PROJECT_URL: vector<u8> = b"https://nplex.eu";

const TOKEN_DISPLAY_NAME: vector<u8> = b"NPLEX Investor Token";
const TOKEN_DISPLAY_DESCRIPTION: vector<u8> = b"Investor share for LTC1 Package {package_id}";
const TOKEN_DISPLAY_IMAGE_URL: vector<u8> = b"https://api.nplex.eu/icons/token_blue.png";
const TOKEN_DISPLAY_PROJECT_URL: vector<u8> = b"https://nplex.eu";

const DISPLAY_KEY_NAME: vector<u8> = b"name";
const DISPLAY_KEY_DESCRIPTION: vector<u8> = b"description";
const DISPLAY_KEY_IMAGE_URL: vector<u8> = b"image_url";
const DISPLAY_KEY_PROJECT_URL: vector<u8> = b"project_url";

// ==================== Structs ====================

/// The OTW for package initialization
public struct LTC1 has drop {}

/// The LTC1 Witness for Registry Binding
public struct LTC1Witness has drop {}

/// The Investor Token
/// Represents a share of the NPL package and revenue rights.
public struct LTC1Token has key, store {
    id: UID,
    /// Number of "shares" this token represents
    balance: u64,
    /// Reference to parent LTC1Package
    package_id: ID,
    /// Total IOTA this token has already claimed
    claimed_revenue: u64,
}

/// The Owner Bond (Admin Key)
/// Represents ownership and control over the package.
public struct OwnerBond has key {
    id: iota::object::UID,
    package_id: iota::object::ID,
    /// Total revenue claimed by the owner so far
    claimed_revenue: u64,
}

/// The LTC1 Package (Shared Object)
/// Contains the state, pools, and metadata visible to everyone.
/// TODO Immutable fields like name hash and total supply should be made immutable by embedding them in a different obj and using transfer::freeze_object
public struct LTC1Package<phantom T> has key {
    id: iota::object::UID,
    name: String,
    document_hash: u256,
    /// ID of the external Notarization Object (created via IOTA SDK)
    notary_object_id: ID,
    
    // Supply & Pricing
    total_supply: u64,
    /// Maximum supply that can be sold to investors
    max_sellable_supply: u64,
    tokens_sold: u64,
    token_price: u64,// in NANOS 1,000,000,000 = 1 iota

    // this is metadata, the value the originator of the security gave to this asset at creation
    nominal_value: u64,// in NANOS 1,000,000,000 = 1 iota
    
    // Pools
    funding_pool: Balance<T>,
    revenue_pool: Balance<T>,
    total_revenue_deposited: u64,
    /// Revenue earned by unsold tokens (belongs to owner)
    owner_legacy_revenue: u64,
    
    // Metadata & Admin
    owner_bond_id: iota::object::ID,
    creation_timestamp: u64,
    metadata_uri: String,
    /// Whether primary sales are open (controlled by NPLEX admin)
    sales_open: bool,
}

// ==================== Initialization ====================

#[allow(lint(share_owned))]
fun init(otw: LTC1, ctx: &mut iota::tx_context::TxContext) {
    // 1. Claim Publisher
    let publisher = package::claim(otw, ctx);

    // 2. Setup Display
    // OwnerBond
    display_utils::setup_display! <OwnerBond> (
        &publisher,
        vector[
            std::string::utf8(DISPLAY_KEY_NAME),
            std::string::utf8(DISPLAY_KEY_DESCRIPTION),
            std::string::utf8(DISPLAY_KEY_IMAGE_URL),
            std::string::utf8(DISPLAY_KEY_PROJECT_URL),
        ],
        vector[
            std::string::utf8(BOND_DISPLAY_NAME),
            std::string::utf8(BOND_DISPLAY_DESCRIPTION),
            std::string::utf8(BOND_DISPLAY_IMAGE_URL),
            std::string::utf8(BOND_DISPLAY_PROJECT_URL),
        ],
        ctx
    );

    // LTC1Token
    display_utils::setup_display! <LTC1Token> (
        &publisher,
        vector[
            std::string::utf8(DISPLAY_KEY_NAME),
            std::string::utf8(DISPLAY_KEY_DESCRIPTION),
            std::string::utf8(DISPLAY_KEY_IMAGE_URL),
            std::string::utf8(DISPLAY_KEY_PROJECT_URL),
        ],
        vector[
            std::string::utf8(TOKEN_DISPLAY_NAME),
            std::string::utf8(TOKEN_DISPLAY_DESCRIPTION),
            std::string::utf8(TOKEN_DISPLAY_IMAGE_URL),
            std::string::utf8(TOKEN_DISPLAY_PROJECT_URL),
        ],
        ctx
    );

    // 3. Cleanup & Transfer
    iota::transfer::public_transfer(publisher, iota::tx_context::sender(ctx));
}

// ==================== Public Functions ====================

public entry fun create_contract<T>(
    registry: &mut NPLEXRegistry,
    name: String,
    notarization: &Notarization<u256>,
    total_supply: u64,
    token_price: u64,
    nominal_value: u64,
    investor_split_bps: u64,
    metadata_uri: String,
    clock: &Clock,
    ctx: &mut iota::tx_context::TxContext
) {
    let owner = iota::tx_context::sender(ctx); // Owner is the creator

    // 0. Extract hash and ID from Notarization
    let state = notarization::state(notarization);
    let document_hash = *notarization::data(state);
    let notary_object_id = iota::object::id(notarization);

    // 0. Validate Split
    assert!(investor_split_bps <= MAX_INVESTOR_BPS, E_INVALID_SPLIT);

    // 1. Validate Total Supply
    assert!(total_supply >= MIN_SUPPLY, E_SUPPLY_TOO_LOW);

    // 2. Claim notarization
    let claim = registry::claim_notarization(registry, notary_object_id, ctx);

    // 3. Create UIDs first to get IDs (Resolves circular dependency)
    let package_uid = iota::object::new(ctx);
    let bond_uid = iota::object::new(ctx);
    
    let package_id = iota::object::uid_to_inner(&package_uid);
    let bond_id = iota::object::uid_to_inner(&bond_uid);

    // Calculate limits
    let max_sellable_supply = (((total_supply as u256) * (investor_split_bps as u256)) / (SPLIT_DENOMINATOR as u256)) as u64;

    // 4. Create the Package (Shared Object)
    let package = LTC1Package<T> {
        id: package_uid,
        name,
        document_hash,
        notary_object_id,
        
        // Supply & Pricing
        total_supply,
        max_sellable_supply,
        tokens_sold: 0,
        token_price,
        nominal_value,
        
        // Pools
        funding_pool: balance::zero<T>(),
        revenue_pool: balance::zero<T>(),
        total_revenue_deposited: 0,
        owner_legacy_revenue: 0,
        
        // Metadata & Admin
        owner_bond_id: bond_id,
        creation_timestamp: clock::timestamp_ms(clock),
        metadata_uri,
        sales_open: false,
    };

    // 5. Create the Bond (Owned Object - Admin Key)
    let bond = OwnerBond {
        id: bond_uid,
        package_id: package_id,
        claimed_revenue: 0,
    };

    // 6. Bind hash with Witness
    registry::bind_executor(
        registry, 
        claim, 
        package_id, 
        LTC1Witness {}
    );

    // 7. Publish
    // Share the package so ANYONE can find it and interact (buy tokens, view status)
    iota::transfer::share_object(package);
    
    // Send the bond ONLY to the owner (they need this to act as admin)
    iota::transfer::transfer(bond, owner);

    // 8. Emit Event
    events::emit_contract_created(
        package_id,
        owner,
        nominal_value,
    );
}

/// Buy tokens from the package
/// User specifies how many "shares" they want to buy (`amount`)
/// and provides the Payment in IOTA.
public entry fun buy_token<T>(
    registry: &NPLEXRegistry,
    package: &mut LTC1Package<T>,
    mut payment: Coin<T>,
    amount: u64,
    ctx: &mut iota::tx_context::TxContext
) {
    // 0. Verify Contract Status (not revoked)
    assert!(registry::is_valid_notarization(registry, package.notary_object_id), E_CONTRACT_REVOKED);

    // 0.1. amount must be greater than 0
    assert!(amount > 0, E_INVALID_AMOUNT);

    // 0.5. Verify Sales are Open
    assert!(package.sales_open, E_SALES_CLOSED);

    // 1. Check supply
    assert!(amount <= package.max_sellable_supply - package.tokens_sold, E_INSUFFICIENT_SUPPLY);

    // 2. Calculate cost
    let cost = (((amount as u256) * (package.token_price as u256)) as u64);
    assert!(iota::coin::value(&payment) >= cost, E_INSUFFICIENT_PAYMENT);

    // 3. Handle Payment
    let coin_value = iota::coin::value(&payment);
    let paid_balance = if (coin_value == cost) {
        iota::coin::into_balance(payment)
    } else {
        let split = iota::coin::split(&mut payment, cost, ctx);
        iota::transfer::public_transfer(payment, iota::tx_context::sender(ctx)); // Return change
        iota::coin::into_balance(split)
    };
    
    balance::join(&mut package.funding_pool, paid_balance);

    // 4. Calculate Claims
    // When buying new tokens, we must prevent "buying into" past revenue.
    // The revenue attached to these tokens *up to this point* belongs to the Owner (old owner).
    // "Dividend Stripping" protection turned into "Back Pay" for Owner.
    let initial_claimed = (((amount as u256) * (package.total_revenue_deposited as u256)) / (package.total_supply as u256) as u64);

    // 5. Mint Token
    package.tokens_sold = package.tokens_sold + amount;
    
    let token = LTC1Token {
        id: iota::object::new(ctx),
        balance: amount,
        package_id: iota::object::uid_to_inner(&package.id),
        claimed_revenue: initial_claimed,
    };

    // 6. Credit Owner Legacy Revenue
    // The `initial_claimed` amount is money the new buyer IS NOT entitled to.
    // Therefore, it is money the Owner WAS entitled to (as previous owner of unsold stock).
    package.owner_legacy_revenue = package.owner_legacy_revenue + initial_claimed;

    iota::transfer::public_transfer(token, iota::tx_context::sender(ctx));

    // 7. Emit Event
    events::emit_token_purchased(
        iota::object::uid_to_inner(&package.id),
        iota::tx_context::sender(ctx),
        amount,
        cost,
    );
}

/// Withdraw Funding from the package (Owner Only)
/// Requires the OwnerBond (Admin Capability)
public entry fun withdraw_funding<T>(
    registry: &NPLEXRegistry,
    package: &mut LTC1Package<T>,
    bond: &OwnerBond,
    amount: u64,
    ctx: &mut iota::tx_context::TxContext
) {
    // 0. Verify Contract Status (not revoked)
    assert!(registry::is_valid_notarization(registry, package.notary_object_id), E_CONTRACT_REVOKED);

    // 1. Verify OwnerBond matches this package
    assert!(bond.package_id == iota::object::uid_to_inner(&package.id), E_WRONG_BOND);

    // 2. Withdraw
    let funding = iota::coin::take(&mut package.funding_pool, amount, ctx); // Aborts if amount > funding_pool.value
    iota::transfer::public_transfer(funding, iota::tx_context::sender(ctx));
}

/// Deposit revenue into the package (Owner Only)
/// Requires the OwnerBond (Admin Capability)
public entry fun deposit_revenue<T>(
    registry: &NPLEXRegistry,
    package: &mut LTC1Package<T>,
    bond: &OwnerBond,
    payment: Coin<T>,
    _ctx: &mut iota::tx_context::TxContext
) {
    // 0. Verify Contract Status (not revoked)
    assert!(registry::is_valid_notarization(registry, package.notary_object_id), E_CONTRACT_REVOKED);

    // 1. Verify OwnerBond matches this package
    assert!(bond.package_id == iota::object::uid_to_inner(&package.id), E_WRONG_BOND);

    // 2. Update Metadata
    let amount = iota::coin::value(&payment);
    package.total_revenue_deposited = package.total_revenue_deposited + amount;

    // 3. Deposit to Revenue Pool
    balance::join(&mut package.revenue_pool, iota::coin::into_balance(payment));

    // 4. Emit Event
    events::emit_revenue_deposited(
        iota::object::uid_to_inner(&package.id),
        amount,
    );
}

/// Claim Revenue for Owner
/// Owner is entitled to:
/// 1. The revenue share of the currently UNSOLD tokens.
/// 2. The "Legacy Revenue" accumulated from tokens they owned in the past but then sold.
public entry fun claim_revenue_owner<T>(
    registry: &NPLEXRegistry,
    package: &mut LTC1Package<T>,
    bond: &mut OwnerBond,
    ctx: &mut iota::tx_context::TxContext
) {
    // Verify Contract Status (not revoked)
    assert!(registry::is_valid_notarization(registry, package.notary_object_id), E_CONTRACT_REVOKED);

    // 1. Verify Bond
    assert!(bond.package_id == iota::object::uid_to_inner(&package.id), E_WRONG_BOND);

    // 2. Calculate Current Entitlement (Unsold Tokens)
    let unsold_supply = package.total_supply - package.tokens_sold;
    let current_share = (((unsold_supply as u256) * (package.total_revenue_deposited as u256)) / (package.total_supply as u256) as u64);

    // 3. Calculate Total Entitlement (Current + Legacy)
    let total_entitled = current_share + package.owner_legacy_revenue;

    // 4. Calculate Due
    let due = total_entitled - bond.claimed_revenue;
    // In the rare case due is 0 (double claim), we just return.
    if (due == 0) {
        return
    };

    // 5. Update Bond State
    bond.claimed_revenue = bond.claimed_revenue + due;

    // 6. Payout
    let payment = iota::coin::take(&mut package.revenue_pool, due, ctx);
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
    // This will abort if:
    // - LTC1 is not an allowed executor (Unlikely if code is published)
    // - Transfer is not authorized
    // - New owner does not match
    registry::consume_transfer_ticket(registry, bond.package_id, new_owner, LTC1Witness {});

    // 2. Transfer Bond
    iota::transfer::transfer(bond, new_owner);
}

/// Toggle sales state for the package
/// Requires prior authorization from NPLEX via Registry
public entry fun toggle_sales<T>(
    registry: &mut NPLEXRegistry,
    package: &mut LTC1Package<T>,
    _ctx: &mut iota::tx_context::TxContext
) {
    // 1. Consume Ticket from Registry (validates executor + authorization)
    let new_state = registry::consume_sales_toggle_ticket(
        registry,
        iota::object::uid_to_inner(&package.id),
        LTC1Witness {}
    );

    // 2. Update Sales State
    package.sales_open = new_state;
}

/// Claim Revenue for Investors
/// Investors can claim their share of the revenue based on their token balance.
/// Allowed even if the contract is revoked (so investors can exit).
public entry fun claim_revenue<T>(
    registry: &NPLEXRegistry,
    package: &mut LTC1Package<T>,
    token: &mut LTC1Token,
    ctx: &mut iota::tx_context::TxContext
) {
    // Verify Contract Status (not revoked)
    // TODO this has to be checked in the future when we have a more granular control over permissions
    assert!(registry::is_valid_notarization(registry, package.notary_object_id), E_CONTRACT_REVOKED);

    // 1. Verify Token belongs to this package
    assert!(token.package_id == iota::object::uid_to_inner(&package.id), E_INVALID_TOKEN);

    // 2. Calculate Entitlement
    // Formula: (balance * total_revenue_deposited) / total_supply
    let total_entitled = (((token.balance as u256) * (package.total_revenue_deposited as u256)) / (package.total_supply as u256) as u64);

    // 3. Calculate Due
    let due = total_entitled - token.claimed_revenue;
    if (due == 0) {
        return
    };

    // 4. Update Token
    token.claimed_revenue = token.claimed_revenue + due;

    // 5. Payout
    let payment = iota::coin::take(&mut package.revenue_pool, due, ctx);
    iota::transfer::public_transfer(payment, iota::tx_context::sender(ctx));
}

// ==================== Accessors ====================

public fun balance(token: &LTC1Token): u64 {
    token.balance
}

public fun claimed_revenue(token: &LTC1Token): u64 {
    token.claimed_revenue
}

public fun package_id(token: &LTC1Token): ID {
    token.package_id
}

/// Verify if a proposed document hash matches the package's registered hash
public fun verify_document<T>(package: &LTC1Package<T>, document_hash: u256): bool {
    package.document_hash == document_hash
}

// ==================== Package-Private Helpers (for fractional.move) ====================

/// Subtract `amount` from a token's balance, splitting claimed_revenue proportionally.
/// Returns (balance_removed, claimed_revenue_removed).
/// Asserts amount > 0 and amount < token.balance (cannot fractionalize entire token).
public(package) fun subtract_balance(token: &mut LTC1Token, amount: u64): (u64, u64) {
    assert!(amount > 0, E_ZERO_AMOUNT);
    assert!(amount < token.balance, E_INSUFFICIENT_BALANCE);

    // Split claimed_revenue proportionally
    let claimed_split = (((token.claimed_revenue as u256) * (amount as u256)) / (token.balance as u256) as u64);

    token.balance = token.balance - amount;
    token.claimed_revenue = token.claimed_revenue - claimed_split;

    (amount, claimed_split)
}

/// Create a new LTC1Token with exact values. Used during fraction redemption.
public(package) fun create_token_from_fraction(
    package_id: ID,
    balance: u64,
    claimed_revenue: u64,
    ctx: &mut iota::tx_context::TxContext
): LTC1Token {
    LTC1Token {
        id: iota::object::new(ctx),
        balance,
        package_id,
        claimed_revenue,
    }
}

/// Add balance and claimed_revenue from a fraction back to an existing token.
/// Used by fractional::merge().
public(package) fun add_fraction_balance(
    token: &mut LTC1Token,
    balance: u64,
    claimed_revenue: u64,
) {
    token.balance = token.balance + balance;
    token.claimed_revenue = token.claimed_revenue + claimed_revenue;
}
