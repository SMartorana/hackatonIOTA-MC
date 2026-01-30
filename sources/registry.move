// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// NPLEX Registry - Manages approval and validation of NPL package hashes
/// 
/// This contract provides the validation layer for the NPLEX platform.
/// Only NPLEX admin can register and revoke package hashes.
/// LTC1 contracts must validate against this registry before creation.

module nplex::registry {
    use iota::table::{Self, Table};

    // ==================== Error Codes ====================

    /// Hash is not registered in the registry
    const E_HASH_NOT_APPROVED: u64 = 1;
    
    /// Hash has already been used to create an LTC1 contract
    const E_HASH_ALREADY_USED: u64 = 2;
    
    /// Hash has been revoked by NPLEX
    const E_HASH_REVOKED: u64 = 3;

    // ==================== Structs ====================

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
        approved_hashes: Table<vector<u8>, HashInfo>,
    }

    /// Information about an approved hash
    public struct HashInfo has store {
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
    fun init(ctx: &mut TxContext) {
        // Create admin capability and send to deployer
        let admin_cap = NPLEXAdminCap {
            id: object::new(ctx),
        };
        transfer::transfer(admin_cap, tx_context::sender(ctx));

        // Create shared registry
        let registry = NPLEXRegistry {
            id: object::new(ctx),
            approved_hashes: table::new(ctx),
        };
        transfer::share_object(registry);
    }

    // ==================== Admin Functions ====================

    /// Register a new approved hash in the registry
    /// Only callable by NPLEX admin
    public entry fun register_hash(
        registry: &mut NPLEXRegistry,
        _admin_cap: &NPLEXAdminCap,
        document_hash: vector<u8>,
        ctx: &TxContext
    ) {
        let hash_info = HashInfo {
            approved_timestamp: tx_context::epoch(ctx),
            auditor: tx_context::sender(ctx),
            is_revoked: false,
            contract_id: option::none(),
        };
        
        table::add(&mut registry.approved_hashes, document_hash, hash_info);
    }

    /// Revoke a previously approved hash (emergency use)
    /// This prevents new operations on LTC1 contracts with this hash
    public entry fun revoke_hash(
        registry: &mut NPLEXRegistry,
        _admin_cap: &NPLEXAdminCap,
        document_hash: vector<u8>
    ) {
        let hash_info = table::borrow_mut(&mut registry.approved_hashes, document_hash);
        hash_info.is_revoked = true;
    }

    /// Un-revoke a hash (if revocation was in error)
    public entry fun unrevoke_hash(
        registry: &mut NPLEXRegistry,
        _admin_cap: &NPLEXAdminCap,
        document_hash: vector<u8>
    ) {
        let hash_info = table::borrow_mut(&mut registry.approved_hashes, document_hash);
        hash_info.is_revoked = false;
    }

    // ==================== Validation Functions ====================

    /// Mark a hash as used (called by LTC1 contract during creation)
    /// Enforces uniqueness - only one LTC1 per hash
    public fun mark_hash_used(
        registry: &mut NPLEXRegistry,
        document_hash: vector<u8>,
        ltc1_id: ID
    ) {
        // Verify hash is approved
        assert!(table::contains(&registry.approved_hashes, document_hash), E_HASH_NOT_APPROVED);
        
        let hash_info = table::borrow_mut(&mut registry.approved_hashes, document_hash);
        
        // Verify not revoked
        assert!(!hash_info.is_revoked, E_HASH_REVOKED);
        
        // Verify not already used
        assert!(option::is_none(&hash_info.contract_id), E_HASH_ALREADY_USED);
        
        // Mark as used
        hash_info.contract_id = option::some(ltc1_id);
    }

    // ==================== Idempotent Functions ====================

    /// Check if a hash is approved and not revoked
    /// Returns true if hash can be used to create LTC1
    public fun is_valid_hash(
        registry: &NPLEXRegistry,
        document_hash: &vector<u8>
    ): bool {
        if (!table::contains(&registry.approved_hashes, *document_hash)) {
            return false
        };
        
        let hash_info = table::borrow(&registry.approved_hashes, *document_hash);
        !hash_info.is_revoked
    }

    /// Check if a hash has already been used to create an LTC1 contract
    public fun is_hash_used(
        registry: &NPLEXRegistry,
        document_hash: &vector<u8>
    ): bool {
        if (!table::contains(&registry.approved_hashes, *document_hash)) {
            return false
        };
        
        let hash_info = table::borrow(&registry.approved_hashes, *document_hash);
        option::is_some(&hash_info.contract_id)
    }

    /// Check if a hash is revoked, just to check if an hash existed but was revoked (Could be useless)
    public fun is_hash_revoked(
        registry: &NPLEXRegistry,
        document_hash: &vector<u8>
    ): bool {
        if (!table::contains(&registry.approved_hashes, *document_hash)) {
            return false
        };
        
        let hash_info = table::borrow(&registry.approved_hashes, *document_hash);
        hash_info.is_revoked
    }

    /// Get hash info (for UI/debugging)
    public fun get_hash_info(
        registry: &NPLEXRegistry,
        document_hash: &vector<u8>
    ): (u64, address, bool, option::Option<ID>) {
        let hash_info = table::borrow(&registry.approved_hashes, *document_hash);
        (
            hash_info.approved_timestamp,
            hash_info.auditor,
            hash_info.is_revoked,
            hash_info.contract_id
        )
    }

    // ==================== Testing Functions ====================

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }

    #[test_only]
    public fun is_valid_hash_for_testing(registry: &NPLEXRegistry, document_hash: &vector<u8>): bool {
        is_valid_hash(registry, document_hash)
    }

    #[test_only]
    public fun is_hash_used_for_testing(registry: &NPLEXRegistry, document_hash: &vector<u8>): bool {
        is_hash_used(registry, document_hash)
    }

    #[test_only]
    public fun mark_hash_used_for_testing(registry: &mut NPLEXRegistry, document_hash: vector<u8>, ltc1_id: ID) {
        mark_hash_used(registry, document_hash, ltc1_id)
    }

    #[test_only]
    public fun is_hash_revoked_for_testing(registry: &NPLEXRegistry, document_hash: &vector<u8>): bool {
        is_hash_revoked(registry, document_hash)
    }

    #[test_only]
    public fun get_hash_info_for_testing(registry: &NPLEXRegistry, document_hash: &vector<u8>): (u64, address, bool, option::Option<ID>) {
        get_hash_info(registry, document_hash)
    }
}
