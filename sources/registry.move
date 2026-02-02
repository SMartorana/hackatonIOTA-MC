// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// NPLEX Registry - Manages approval and validation of NPL package hashes
/// 
/// This contract provides the validation layer for the NPLEX platform.
/// Only NPLEX admin can register and revoke package hashes.
/// LTC1 contracts must validate against this registry before creation.

module nplex::registry {
    use iota::table::{Self, Table};
    use std::type_name::{Self, TypeName};

    // ==================== Error Codes ====================

    /// Hash is not registered in the registry or has been revoked
    const E_HASH_NOT_APPROVED: u64 = 1;
    
    /// Hash has already been used to create an LTC1 contract
    const E_HASH_ALREADY_USED: u64 = 2;
    
    /// Hash has been revoked by NPLEX
    const E_HASH_REVOKED: u64 = 3;

    /// Executor module is not authorized to bind hashes
    const E_UNAUTHORIZED_EXECUTOR: u64 = 4;

    /// Bond transfer not authorized by NPLEX
    const E_TRANSFER_NOT_AUTHORIZED: u64 = 5;

    // ==================== Structs ====================
    /// One-Time Witness for the module
    public struct REGISTRY has drop {}

    /// Hot potato struct to ensure hash usage flow
    public struct HashClaim {
        document_hash: u256
    }

    /// Admin capability - only NPLEX holds this
    /// This is a "hot potato" pattern - whoever owns this can admin the registry
    public struct NPLEXAdminCap has key, store {
        id: UID,
    }

    /// Central registry of approved NPL package hashes
    /// Shared object - anyone can read, only admin can mutate
    public struct NPLEXRegistry has key {
        id: UID,
        /// Maps document hash -> package information
        approved_hashes: Table<u256, HashInfo>,
        /// Maps Contract ID -> Authorized New Owner Address
        authorized_transfers: Table<ID, address>,
        /// List of registered hash keys (Iteratable index for Frontend)
        registered_hash_keys: vector<u256>,
        /// Maps TypeName (of the executor witness) -> is_allowed, could probably be replaced with friend for the purpose of the mvp or the iota equivalent of public(package)
        allowed_executors: vector<TypeName>,
    }

    /// Information about an approved hash
    public struct HashInfo has store, copy, drop {
        /// When this hash was approved
        approved_timestamp: u64,
        /// Address that approved this hash (NPLEX auditor)
        auditor: address,
        /// Whether this hash has been revoked
        is_revoked: bool,
        /// ID of LTC1 contract created with this hash (None if not yet used)
        contract_id: option::Option<ID>,
    }

    // ==================== Initialization ====================

    /// Module initializer - called once when contract is published
    /// Creates the registry and gives admin capability to publisher
    fun init(otw: nplex::registry::REGISTRY, ctx: &mut TxContext) {
        let _ = otw; // Currently ignored, but keeps the door open for Publisher claim
        
        // Create admin capability and send to deployer
        let admin_cap = NPLEXAdminCap {
            id: object::new(ctx),
        };
        transfer::transfer(admin_cap, tx_context::sender(ctx));

        // Create shared registry
        let registry = NPLEXRegistry {
            id: object::new(ctx),
            approved_hashes: table::new(ctx),
            authorized_transfers: table::new(ctx),
            registered_hash_keys: vector::empty(),
            allowed_executors: vector::empty(),
        };
        transfer::share_object(registry);
    }

    // ==================== Admin Functions ====================

    /// Register a new approved hash in the registry
    /// Invarant: only callable by NPLEX admin and hash must have not been registered before
    public entry fun register_hash(
        registry: &mut NPLEXRegistry,
        _admin_cap: &NPLEXAdminCap,
        document_hash: u256,
        ctx: &TxContext
    ) {
        assert!(!table::contains(&registry.approved_hashes, document_hash), E_HASH_ALREADY_USED);
        
        let hash_info = HashInfo {
            approved_timestamp: tx_context::epoch(ctx),
            auditor: tx_context::sender(ctx),
            is_revoked: false,
            contract_id: option::none(),
        };
        
        table::add(&mut registry.approved_hashes, document_hash, hash_info);
        vector::push_back(&mut registry.registered_hash_keys, document_hash);
    }

    /// Revoke a previously approved hash (emergency use)
    /// This prevents new operations on LTC1 contracts with this hash
    /// Invariant: only callable by NPLEX admin and hash must have been registered before
    public entry fun revoke_hash(
        registry: &mut NPLEXRegistry,
        _admin_cap: &NPLEXAdminCap,
        document_hash: u256
    ) {
        assert!(table::contains(&registry.approved_hashes, document_hash), E_HASH_NOT_APPROVED);
        let hash_info = table::borrow_mut(&mut registry.approved_hashes, document_hash);
        hash_info.is_revoked = true;
    }

    /// Un-revoke a hash (if revocation was in error)
    /// Invariant: only callable by NPLEX admin and hash must have been registered before
    public entry fun unrevoke_hash(
        registry: &mut NPLEXRegistry,
        _admin_cap: &NPLEXAdminCap,
        document_hash: u256
    ) {
        assert!(table::contains(&registry.approved_hashes, document_hash), E_HASH_NOT_APPROVED);
        let hash_info = table::borrow_mut(&mut registry.approved_hashes, document_hash);
        hash_info.is_revoked = false;
    }

    /// Add an allowed executor module
    /// Invariant: only callable by NPLEX admin
    public entry fun add_executor<T>(
        registry: &mut NPLEXRegistry,
        _admin_cap: &NPLEXAdminCap,
    ) {
        let type_name = type_name::get<T>();
        if (!vector::contains(&registry.allowed_executors, &type_name)) {
            vector::push_back(&mut registry.allowed_executors, type_name);
        };
    }

    /// Remove an allowed executor module
    /// Invariant: only callable by NPLEX admin
    public entry fun remove_executor<T>(
        registry: &mut NPLEXRegistry,
        _admin_cap: &NPLEXAdminCap,
    ) {
        let type_name = type_name::get<T>();
        let (found, index) = vector::index_of(&registry.allowed_executors, &type_name);
        if (found) {
            vector::swap_remove(&mut registry.allowed_executors, index); // swap_remove is O(1) while remove is O(n)
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

    // ==================== Validation Functions ====================

    /// Claim a hash to start usage flow
    /// Returns a hot potato that must be consumed by bind_executor
    /// Invariant: hash must have been registered before and not revoked and not used yet by another ltc1 contract
    public fun claim_hash(
        registry: &mut NPLEXRegistry,
        document_hash: u256
    ): HashClaim {
        // Verify hash is approved
        assert!(table::contains(&registry.approved_hashes, document_hash), E_HASH_NOT_APPROVED);
        
        let hash_info = table::borrow(&registry.approved_hashes, document_hash);
        
        // Verify not revoked
        assert!(!hash_info.is_revoked, E_HASH_REVOKED);
        
        // Verify not already used
        assert!(option::is_none(&hash_info.contract_id), E_HASH_ALREADY_USED);
        
        HashClaim { document_hash }
    }

    /// Finalize hash usage by binding it to an LTC1 contract ID
    /// Consumes the hot potato
    /// Invariant: witness type must be allowed and hash must have been claimed before through claim_hash and not used yet by another ltc1 contract
    public fun bind_executor<T: drop>(
        registry: &mut NPLEXRegistry,
        claim: HashClaim,
        new_contract_id: ID,
        _witness: T
    ) {
        // Verify witness type is allowed
        let witness_type = type_name::get<T>();
        assert!(vector::contains(&registry.allowed_executors, &witness_type), E_UNAUTHORIZED_EXECUTOR);

        let HashClaim { document_hash } = claim;
        
        let hash_info = table::borrow_mut(&mut registry.approved_hashes, document_hash);
        
        // Double check
        assert!(std::option::is_none(&hash_info.contract_id), E_HASH_ALREADY_USED);
        
        // Mark as used
        std::option::fill(&mut hash_info.contract_id, new_contract_id); // fill will abort if contract_id is already Some
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
        let witness_type = type_name::get<T>();
        assert!(vector::contains(&registry.allowed_executors, &witness_type), E_UNAUTHORIZED_EXECUTOR);

        // 2. Verify Transfer is Authorized
        assert!(table::contains(&registry.authorized_transfers, contract_id), E_TRANSFER_NOT_AUTHORIZED);
        
        // 3. Verify Recipient matches
        let authorized_recipient = *table::borrow(&registry.authorized_transfers, contract_id);
        assert!(authorized_recipient == new_owner, E_TRANSFER_NOT_AUTHORIZED);

        // 4. Consume Ticket
        table::remove(&mut registry.authorized_transfers, contract_id);
    }

    // ==================== Idempotent Functions ====================

    /// Check if a hash is approved and not revoked
    /// Returns true if hash can be used to create LTC1
    public fun is_valid_hash(
        registry: &NPLEXRegistry,
        document_hash: u256
    ): bool {
        if (!table::contains(&registry.approved_hashes, document_hash)) {
            return false
        };
        
        let hash_info = table::borrow(&registry.approved_hashes, document_hash);
        !hash_info.is_revoked
    }

    /// Check if a hash has already been used to create an LTC1 contract
    public fun is_hash_used(
        registry: &NPLEXRegistry,
        document_hash: u256
    ): bool {
        if (!table::contains(&registry.approved_hashes, document_hash)) {
            return false
        };
        
        let hash_info = table::borrow(&registry.approved_hashes, document_hash);
        option::is_some(&hash_info.contract_id)
    }

    /// Check if a hash is revoked, just to check if an hash existed but was revoked (Could be useless)
    public fun is_hash_revoked(
        registry: &NPLEXRegistry,
        document_hash: u256
    ): bool {
        if (!table::contains(&registry.approved_hashes, document_hash)) {
            return false
        };
        
        let hash_info = table::borrow(&registry.approved_hashes, document_hash);
        hash_info.is_revoked
    }

    /// Get hash info (for UI/debugging)
    public fun get_hash_info(
        registry: &NPLEXRegistry,
        document_hash: u256
    ): HashInfo {
        *table::borrow(&registry.approved_hashes, document_hash)
        //we could unpack the struct and return the values but I think this is better for security, you have to explicitly write (a getter) what you want to be accessible
    }

    /// Accessor for HashInfo.contract_id
    public fun hash_contract_id(info: &HashInfo): Option<ID> {
        info.contract_id
    }

    /// Accessor for HashInfo.is_revoked
    public fun hash_is_revoked(info: &HashInfo): bool {
        info.is_revoked
    }

    /// Accessor for HashInfo.auditor
    public fun hash_auditor(info: &HashInfo): address {
        info.auditor
    }

    /// Accessor for HashInfo.approved_timestamp
    public fun hash_approved_timestamp(info: &HashInfo): u64 {
        info.approved_timestamp
    }

    /// Get ALL registered hash info (View Function UI/debugging)
    /// Iterates through the stored keys and returns the full list of info structs
    public fun get_all_hashes_info(registry: &NPLEXRegistry): vector<HashInfo> {
        let mut list = vector::empty();
        let len = vector::length(&registry.registered_hash_keys);
        let mut i = 0;
        while (i < len) {
            let key = *vector::borrow(&registry.registered_hash_keys, i);
            let info = *table::borrow(&registry.approved_hashes, key);
            vector::push_back(&mut list, info);
            i = i + 1;
        };
        list
    }

    // ==================== Testing Functions ====================

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(REGISTRY {}, ctx);
    }
}
