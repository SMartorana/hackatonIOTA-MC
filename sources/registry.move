// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// NPLEX Registry - Manages approval and validation of NPL package hashes
/// 
/// This contract provides the validation layer for the NPLEX platform.
/// Only NPLEX admin can register and revoke package hashes.
/// LTC1 contracts must validate against this registry before creation.

module nplex::registry;

use nplex::display_utils;

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
    /// Maps notarization ID -> package information
    approved_notarizations: Table<ID, NotarizationInfo>,
    /// Maps Contract ID -> Authorized New Owner Address
    authorized_transfers: Table<ID, address>,
    /// Maps Contract ID -> Target sales state (true = open, false = closed)
    authorized_sales_toggles: Table<ID, bool>,
    /// List of registered notarization IDs (Iteratable index for Frontend)
    /// Only required due to the fact that Iota::table does not allow key iteration
    registered_notarization_ids: vector<ID>,
    // Dynamic Fields are used for allowed_executors
    // Key: ExecutorKey<T> -> Value: bool (true)
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
    authorized_creator: address,
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
        registered_notarization_ids: vector::empty(),
    };
    transfer::share_object(registry);

    // 5. Cleanup
    transfer::public_transfer(publisher, tx_context::sender(ctx));
}



// ==================== Admin Functions ====================

/// Register a new approved notarization in the registry
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
    vector::push_back(&mut registry.registered_notarization_ids, notarization_id);
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
}

/// Add an allowed executor module
/// Invariant: only callable by NPLEX admin
public entry fun add_executor<T>(
    registry: &mut NPLEXRegistry,
    _admin_cap: &NPLEXAdminCap,
) {
    if (!df::exists_(&registry.id, ExecutorKey<T> {})) {
        df::add(&mut registry.id, ExecutorKey<T> {}, true);
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
    };
}

/// Authorize a Bond Transfer for a specific contract
/// Invariant: only callable by NPLEX admin
public entry fun authorize_transfer(
    registry: &mut NPLEXRegistry,
    _admin_cap: &NPLEXAdminCap,
    contract_id: ID,
    new_owner: address
) {
    if (table::contains(&registry.authorized_transfers, contract_id)) {
        table::remove(&mut registry.authorized_transfers, contract_id);
    };
    table::add(&mut registry.authorized_transfers, contract_id, new_owner);
}

/// Authorize a Sales Toggle for a specific contract
/// Invariant: only callable by NPLEX admin
/// new_state: true = open sales, false = close sales
public entry fun authorize_sales_toggle(
    registry: &mut NPLEXRegistry,
    _admin_cap: &NPLEXAdminCap,
    contract_id: ID,
    new_state: bool
) {
    if (table::contains(&registry.authorized_sales_toggles, contract_id)) {
        table::remove(&mut registry.authorized_sales_toggles, contract_id);
    };
    table::add(&mut registry.authorized_sales_toggles, contract_id, new_state);
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
/// Validates that the Caller (via Witness) is authorized and the Transfer is approved by NPLEX
public fun consume_transfer_ticket<T: drop>(
    registry: &mut NPLEXRegistry,
    contract_id: ID,
    new_owner: address,
    _witness: T
) {
    // 1. Verify Witness (Caller) is an allowed executor
    assert!(df::exists_(&registry.id, ExecutorKey<T> {}), E_UNAUTHORIZED_EXECUTOR);

    // 2. Verify Transfer is Authorized
    assert!(table::contains(&registry.authorized_transfers, contract_id), E_TRANSFER_NOT_AUTHORIZED);
    
    // 3. Verify Recipient matches
    let authorized_recipient = *table::borrow(&registry.authorized_transfers, contract_id);
    assert!(authorized_recipient == new_owner, E_TRANSFER_NOT_AUTHORIZED);

    // 4. Consume Ticket
    table::remove(&mut registry.authorized_transfers, contract_id);
}

/// Consume a sales toggle ticket
/// Validates that the Caller (via Witness) is authorized and the toggle is approved by NPLEX
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
    table::remove(&mut registry.authorized_sales_toggles, contract_id)
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

/// Get ALL registered notarization info
public fun get_all_notarizations_info(registry: &NPLEXRegistry): vector<NotarizationInfo> {
    let mut list = vector::empty();
    let len = vector::length(&registry.registered_notarization_ids);
    let mut i = 0;
    while (i < len) {
        let id = *vector::borrow(&registry.registered_notarization_ids, i);
        let info = *table::borrow(&registry.approved_notarizations, id);
        vector::push_back(&mut list, info);
        i = i + 1;
    };
    list
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
