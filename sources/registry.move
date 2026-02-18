// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// NPLEX Registry - Manages approval and validation of NPL package hashes
/// 
/// This contract provides the validation layer for the NPLEX platform.
/// Only NPLEX admin can register and revoke package hashes.
/// LTC1 contracts must validate against this registry before creation.

module nplex::registry;

use nplex::display_utils;
use nplex::events;

use iota::table::{Self, Table};
use iota::dynamic_field as df;
use iota::package;
use iota::clock::{Self, Clock};

// ==================== Error Codes ====================

/// Notarization is not registered in the registry or has been revoked
const E_NOTARIZATION_NOT_APPROVED: u64 = 1;

/// Notarization has already been used to create an LTC1 contract
const E_NOTARIZATION_ALREADY_USED: u64 = 2;

/// Notarization has been revoked by NPLEX
const E_NOTARIZATION_REVOKED: u64 = 3;

/// Executor module is not authorized to bind hashes
const E_UNAUTHORIZED_EXECUTOR: u64 = 4;

/// Bond transfer not authorized by NPLEX
const E_TRANSFER_NOT_AUTHORIZED: u64 = 5;

/// Creator is not authorized for this hash
const E_UNAUTHORIZED_CREATOR: u64 = 6;

/// Sales toggle not authorized by NPLEX
const E_SALES_TOGGLE_NOT_AUTHORIZED: u64 = 7;

/// Notarization not revoked
const E_NOTARIZATION_NOT_REVOKED: u64 = 8;

/// Notarization already revoked
const E_NOTARIZATION_ALREADY_REVOKED: u64 = 9;

// ==================== Display Constants ====================

const DISPLAY_KEY_NAME: vector<u8> = b"name";
const DISPLAY_KEY_DESCRIPTION: vector<u8> = b"description";
const DISPLAY_KEY_IMAGE_URL: vector<u8> = b"image_url";
const DISPLAY_KEY_PROJECT_URL: vector<u8> = b"project_url";

const ADMIN_DISPLAY_NAME: vector<u8> = b"NPLEX Administrator Capability";
const ADMIN_DISPLAY_DESCRIPTION: vector<u8> = b"Grants administrative control over the NPLEX Registry.";
const ADMIN_DISPLAY_IMAGE_URL: vector<u8> = b"https://api.nplex.eu/icons/admin_crown.png";
const ADMIN_DISPLAY_PROJECT_URL: vector<u8> = b"https://nplex.eu";

// ==================== Structs ====================
/// One-Time Witness for the module
public struct REGISTRY has drop {}

/// Hot potato struct to ensure hash usage flow
public struct NotarizationClaim {
    notarization_id: ID,
    document_hash: u256
}

/// Admin capability - only NPLEX holds this
/// This is a "hot potato" pattern - whoever owns this can admin the registry
public struct NPLEXAdminCap has key, store {
    id: UID,
}

/// Key for Authorized Executors (Dynamic Field)
public struct ExecutorKey<phantom T> has copy, drop, store {}

/// Central registry of approved NPL package notarizations
/// Shared object - anyone can read, only admin can mutate
public struct NPLEXRegistry has key {
    id: UID,
    /// Maps Notarization ID -> package information
    approved_notarizations: Table<ID, NotarizationInfo>,
    /// Maps Bond ID -> Notarized transfer authorization
    authorized_transfers: Table<ID, NotarizedTransfer>,
    /// Maps LTC1Package ID -> Notarized sales toggle authorization
    authorized_sales_toggles: Table<ID, NotarizedSaleToggle>
}

/// Information about an approved notarization
public struct NotarizationInfo has store, copy, drop {
    /// The document hash associated with this notarization
    document_hash: u256,
    /// When this hash was approved
    approved_timestamp: u64,
    /// Address that approved this hash (NPLEX auditor)
    auditor: address,
    /// Whether this hash has been revoked
    is_revoked: bool,
    /// ID of LTC1 contract created with this notarization (None if not yet used)
    contract_id: option::Option<ID>,
    /// Only this address is authorized to create a contract with this notarization
    /// This is potentially useless if the notarization we use is not transferable
    /// Ideally the user creates it and it cannot be transfered, I am leaving this like this for now
    authorized_creator: address,
}

/// Notarized transfer authorization — ties a bond transfer to a specific notarization
public struct NotarizedTransfer has store, copy, drop {
    /// The notarization backing this transfer authorization
    notarization_id: ID,
    /// The authorized recipient of the bond
    new_owner: address,
}

/// Notarized sales toggle authorization — ties a sales state change to a specific notarization
public struct NotarizedSaleToggle has store, copy, drop {
    /// The notarization backing this sales toggle authorization
    notarization_id: ID,
    /// The target sales state (true = open, false = closed)
    target_state: bool,
}

// ==================== Initialization ====================

/// Module initializer - called once when contract is published
/// Creates the registry and gives admin capability to publisher

#[allow(lint(share_owned))]
fun init(otw: REGISTRY, ctx: &mut TxContext) {
    // 1. Claim Publisher
    let publisher = package::claim(otw, ctx);

    // Create Display for Admin Cap
    display_utils::setup_display! <NPLEXAdminCap> (
        &publisher,
        vector[
            std::string::utf8(DISPLAY_KEY_NAME),
            std::string::utf8(DISPLAY_KEY_DESCRIPTION),
            std::string::utf8(DISPLAY_KEY_IMAGE_URL),
            std::string::utf8(DISPLAY_KEY_PROJECT_URL),
        ],
        vector[
            std::string::utf8(ADMIN_DISPLAY_NAME),
            std::string::utf8(ADMIN_DISPLAY_DESCRIPTION),
            std::string::utf8(ADMIN_DISPLAY_IMAGE_URL),
            std::string::utf8(ADMIN_DISPLAY_PROJECT_URL),
        ],
        ctx
    );

    // 3. Create admin capability and send to deployer
    let admin_cap = NPLEXAdminCap {
        id: object::new(ctx),
    };
    transfer::transfer(admin_cap, tx_context::sender(ctx));

    // 4. Create shared registry
    let registry = NPLEXRegistry {
        id: object::new(ctx),
        approved_notarizations: table::new(ctx),
        authorized_transfers: table::new(ctx),
        authorized_sales_toggles: table::new(ctx),
    };
    transfer::share_object(registry);

    // 5. Cleanup
    transfer::public_transfer(publisher, tx_context::sender(ctx));
}



// ==================== Admin Functions ====================

/// Register a new approved notarization in the registry
/// These are the documents which are used only for create_contract
/// Notarizations for other approvals are managed in other tables not in approved_notarizations
public entry fun register_notarization(
    registry: &mut NPLEXRegistry,
    _admin_cap: &NPLEXAdminCap,
    notarization_id: ID,
    document_hash: u256,
    authorized_creator: address,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(!table::contains(&registry.approved_notarizations, notarization_id), E_NOTARIZATION_ALREADY_USED);
    
    let notarization_info = NotarizationInfo {
        document_hash,
        approved_timestamp: clock::timestamp_ms(clock),
        auditor: tx_context::sender(ctx),
        is_revoked: false,
        contract_id: option::none(),
        authorized_creator,
    };
    
    table::add(&mut registry.approved_notarizations, notarization_id, notarization_info);

    events::emit_notarization_registered(
        notarization_id,
        document_hash,
        authorized_creator,
        tx_context::sender(ctx),
        clock::timestamp_ms(clock),
    );
}

/// Update the authorized creator for a registered notarization
public entry fun update_authorized_creator(
    registry: &mut NPLEXRegistry,
    _admin_cap: &NPLEXAdminCap,
    notarization_id: ID,
    new_creator: address
) {
    assert!(table::contains(&registry.approved_notarizations, notarization_id), E_NOTARIZATION_NOT_APPROVED);
    let hash_info = table::borrow_mut(&mut registry.approved_notarizations, notarization_id);
    assert!(option::is_none(&hash_info.contract_id), E_NOTARIZATION_ALREADY_USED);
    
    hash_info.authorized_creator = new_creator;

    events::emit_authorized_creator_updated(notarization_id, new_creator);
}

/// Revoke a previously approved notarization
public entry fun revoke_notarization(
    registry: &mut NPLEXRegistry,
    _admin_cap: &NPLEXAdminCap,
    notarization_id: ID
) {
    assert!(table::contains(&registry.approved_notarizations, notarization_id), E_NOTARIZATION_NOT_APPROVED);
    let hash_info = table::borrow_mut(&mut registry.approved_notarizations, notarization_id);
    assert!(!hash_info.is_revoked, E_NOTARIZATION_ALREADY_REVOKED);
    hash_info.is_revoked = true;

    events::emit_notarization_revoked(notarization_id);
}

/// Un-revoke a notarization
public entry fun unrevoke_notarization(
    registry: &mut NPLEXRegistry,
    _admin_cap: &NPLEXAdminCap,
    notarization_id: ID
) {
    assert!(table::contains(&registry.approved_notarizations, notarization_id), E_NOTARIZATION_NOT_APPROVED);
    let hash_info = table::borrow_mut(&mut registry.approved_notarizations, notarization_id);
    assert!(hash_info.is_revoked, E_NOTARIZATION_NOT_REVOKED);
    hash_info.is_revoked = false;

    events::emit_notarization_unrevoked(notarization_id);
}

/// Add an allowed executor module
/// Invariant: only callable by NPLEX admin
public entry fun add_executor<T>(
    registry: &mut NPLEXRegistry,
    _admin_cap: &NPLEXAdminCap,
) {
    if (!df::exists_(&registry.id, ExecutorKey<T> {})) {
        df::add(&mut registry.id, ExecutorKey<T> {}, true);
        events::emit_executor_added(std::type_name::get<T>().into_string());
    };
}

/// Remove an allowed executor module
/// Invariant: only callable by NPLEX admin
public entry fun remove_executor<T>(
    registry: &mut NPLEXRegistry,
    _admin_cap: &NPLEXAdminCap,
) {
    if (df::exists_(&registry.id, ExecutorKey<T> {})) {
        let _: bool = df::remove(&mut registry.id, ExecutorKey<T> {});
        events::emit_executor_removed(std::type_name::get<T>().into_string());
    };
}

/// Authorize a Bond Transfer for a specific contract
/// Invariant: only callable by NPLEX admin
public entry fun authorize_transfer(
    registry: &mut NPLEXRegistry,
    _admin_cap: &NPLEXAdminCap,
    contract_id: ID,
    new_owner: address,
    notarization_id: ID
) {
    if (table::contains(&registry.authorized_transfers, contract_id)) {
        table::remove(&mut registry.authorized_transfers, contract_id);
    };
    table::add(&mut registry.authorized_transfers, contract_id, NotarizedTransfer {
        notarization_id,
        new_owner,
    });

    events::emit_transfer_authorized(contract_id, new_owner, notarization_id);
}

/// Authorize a Sales Toggle for a specific contract
/// Invariant: only callable by NPLEX admin
/// new_state: true = open sales, false = close sales
public entry fun authorize_sales_toggle(
    registry: &mut NPLEXRegistry,
    _admin_cap: &NPLEXAdminCap,
    contract_id: ID,
    new_state: bool,
    notarization_id: ID
) {
    if (table::contains(&registry.authorized_sales_toggles, contract_id)) {
        table::remove(&mut registry.authorized_sales_toggles, contract_id);
    };
    table::add(&mut registry.authorized_sales_toggles, contract_id, NotarizedSaleToggle {
        notarization_id,
        target_state: new_state,
    });

    events::emit_sales_toggle_authorized(contract_id, new_state, notarization_id);
}

// ==================== Validation Functions ====================

/// Claim a notarization to start usage flow
public fun claim_notarization(
    registry: &mut NPLEXRegistry,
    notarization_id: ID,
    ctx: &mut TxContext
): NotarizationClaim {
    // Verify notarization is approved
    assert!(table::contains(&registry.approved_notarizations, notarization_id), E_NOTARIZATION_NOT_APPROVED);
    
    let notarization_info = table::borrow(&registry.approved_notarizations, notarization_id);
    
    // Verify not revoked
    assert!(!notarization_info.is_revoked, E_NOTARIZATION_REVOKED);
    
    // Verify not already used
    assert!(option::is_none(&notarization_info.contract_id), E_NOTARIZATION_ALREADY_USED);

    // Verify authorized creator
    assert!(tx_context::sender(ctx) == notarization_info.authorized_creator, E_UNAUTHORIZED_CREATOR);
    
    NotarizationClaim { notarization_id, document_hash: notarization_info.document_hash }
}

/// Finalize hash usage by binding it to an LTC1 contract ID
public fun bind_executor<T: drop>(
    registry: &mut NPLEXRegistry,
    claim: NotarizationClaim,
    new_contract_id: ID,
    _witness: T
) {
    // Verify witness type is allowed
    assert!(df::exists_(&registry.id, ExecutorKey<T> {}), E_UNAUTHORIZED_EXECUTOR);

    let NotarizationClaim { notarization_id, document_hash: _ } = claim;
    
    let notarization_info = table::borrow_mut(&mut registry.approved_notarizations, notarization_id);
    
    // Double check
    assert!(std::option::is_none(&notarization_info.contract_id), E_NOTARIZATION_ALREADY_USED);
    
    // Mark as used
    std::option::fill(&mut notarization_info.contract_id, new_contract_id);
}

/// Consume a transfer ticket to allow Bond transfer
/// Validates that the Caller (via Witness) is authorized, the Transfer is approved by NPLEX,
public fun consume_transfer_ticket<T: drop>(
    registry: &mut NPLEXRegistry,
    bond_id: ID,
    new_owner: address,
    _witness: T
) {
    // 1. Verify Witness (Caller) is an allowed executor
    assert!(df::exists_(&registry.id, ExecutorKey<T> {}), E_UNAUTHORIZED_EXECUTOR);

    // 2. Verify Transfer is Authorized
    assert!(table::contains(&registry.authorized_transfers, bond_id), E_TRANSFER_NOT_AUTHORIZED);
    
    // 3. Verify Recipient matches
    let authorization = *table::borrow(&registry.authorized_transfers, bond_id);
    assert!(authorization.new_owner == new_owner, E_TRANSFER_NOT_AUTHORIZED);

    // 4. Consume Ticket
    table::remove(&mut registry.authorized_transfers, bond_id);

    events::emit_transfer_consumed(bond_id, new_owner);
}

/// Consume a sales toggle ticket
/// Validates that the Caller (via Witness) is authorized, the toggle is approved by NPLEX,
/// Returns the target sales state (true = open, false = closed)
public fun consume_sales_toggle_ticket<T: drop>(
    registry: &mut NPLEXRegistry,
    contract_id: ID,
    _witness: T
): bool {
    // 1. Verify Witness (Caller) is an allowed executor
    assert!(df::exists_(&registry.id, ExecutorKey<T> {}), E_UNAUTHORIZED_EXECUTOR);

    // 2. Verify Toggle is Authorized
    assert!(table::contains(&registry.authorized_sales_toggles, contract_id), E_SALES_TOGGLE_NOT_AUTHORIZED);

    // 3. Consume Ticket and return target state
    let target_state = table::remove(&mut registry.authorized_sales_toggles, contract_id).target_state;

    events::emit_sales_toggle_consumed(contract_id, target_state);

    target_state
}

// ==================== Idempotent Functions ====================

/// Check if a notarization is approved and not revoked
public fun is_valid_notarization(
    registry: &NPLEXRegistry,
    notarization_id: ID
): bool {
    if (!table::contains(&registry.approved_notarizations, notarization_id)) {
        return false
    };
    
    let hash_info = table::borrow(&registry.approved_notarizations, notarization_id);
    !hash_info.is_revoked
}

/// Check if a notarization has already been used
public fun is_notarization_used(
    registry: &NPLEXRegistry,
    notarization_id: ID
): bool {
    if (!table::contains(&registry.approved_notarizations, notarization_id)) {
        return false
    };
    
    let notarization_info = table::borrow(&registry.approved_notarizations, notarization_id);
    option::is_some(&notarization_info.contract_id)
}

/// Check if a notarization is revoked
public fun is_notarization_revoked(
    registry: &NPLEXRegistry,
    notarization_id: ID
): bool {
    if (!table::contains(&registry.approved_notarizations, notarization_id)) {
        return false
    };
    
    let notarization_info = table::borrow(&registry.approved_notarizations, notarization_id);
    notarization_info.is_revoked
}

/// Get notarization info (for UI/debugging)
public fun get_notarization_info(
    registry: &NPLEXRegistry,
    notarization_id: ID
): NotarizationInfo {
    *table::borrow(&registry.approved_notarizations, notarization_id)
}

/// Accessor for NotarizationInfo.document_hash
public fun notarization_document_hash(info: &NotarizationInfo): u256 {
    info.document_hash
}

/// Accessor for NotarizationInfo.contract_id
public fun notarization_contract_id(info: &NotarizationInfo): Option<ID> {
    info.contract_id
}

/// Accessor for NotarizationInfo.is_revoked
public fun notarization_is_revoked(info: &NotarizationInfo): bool {
    info.is_revoked
}

/// Accessor for NotarizationInfo.auditor
public fun notarization_auditor(info: &NotarizationInfo): address {
    info.auditor
}

/// Accessor for NotarizationInfo.approved_timestamp
public fun notarization_approved_timestamp(info: &NotarizationInfo): u64 {
    info.approved_timestamp
}

/// Accessor for NotarizationInfo.authorized_creator
public fun notarization_authorized_creator(info: &NotarizationInfo): address {
    info.authorized_creator
}

// ==================== Testing Functions ====================

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(REGISTRY {}, ctx);
}

#[test_only]
public fun is_transfer_authorized(registry: &NPLEXRegistry, package_id: ID): bool {
    table::contains(&registry.authorized_transfers, package_id)
}

#[test_only]
public fun is_sales_toggle_authorized(registry: &NPLEXRegistry, contract_id: ID): bool {
    table::contains(&registry.authorized_sales_toggles, contract_id)
}

#[test_only]
public fun burn_notarization_claim(claim: NotarizationClaim) {
    let NotarizationClaim { notarization_id: _, document_hash: _ } = claim;
}
