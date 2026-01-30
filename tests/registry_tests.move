// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// Unit tests for NPLEX Registry
/// Tests hash registration, validation, revocation, and access control

#[test_only]
#[allow(implicit_const_copy)]
module nplex::registry_tests {
    use nplex::registry::{Self, NPLEXRegistry, NPLEXAdminCap};
    use iota::test_scenario;

    // Test addresses
    #[allow(unused_const)]
    const ADMIN: address = @0xAD;
    #[allow(unused_const)]
    const ALICE: address = @0xA;
    #[allow(unused_const)]
    const Verified_hash: vector<u8> = b"test_hash_1";
    #[allow(unused_const)]
    const Unverified_hash: vector<u8> = b"test_hash_2";
    #[allow(unused_const)]  
    const Revoked_hash: vector<u8> = b"test_hash_3";
    #[allow(unused_const)]
    const BOB: address = @0xB;

    // Fixture to initialize the registry and register a hashes
    #[test_only]
    fun fixture_init_registry_and_setup_hashes(scenario: &mut test_scenario::Scenario) {
        // 1. Initialize
        registry::init_for_testing(test_scenario::ctx(scenario));
        
        // 2. Commit initialization transaction
        test_scenario::next_tx(scenario, ADMIN);
        
        // 3. Register hash
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(scenario);
            
            registry::register_hash(&mut registry, &admin_cap, Verified_hash, test_scenario::ctx(scenario));
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario, admin_cap);
        };

        // 4. register Revoked_hash
        test_scenario::next_tx(scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(scenario);
            
            registry::register_hash(&mut registry, &admin_cap, Revoked_hash, test_scenario::ctx(scenario));
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario, admin_cap);
        };
        // 5. revoke Revoked_hash
        test_scenario::next_tx(scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(scenario);
            
            registry::revoke_hash(&mut registry, &admin_cap, Revoked_hash);
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario, admin_cap);
        };  
    }

    #[test]
    fun test_register_and_validate_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Verify hash is valid
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            assert!(registry::is_valid_hash(&registry, &Verified_hash), 0);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_unregistered_hash_is_invalid() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture to set up common state
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Check unregistered hash
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            // Should be invalid
            assert!(!registry::is_valid_hash(&registry, &Unverified_hash), 0);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_revoked_hash_is_invalid() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture (already contains Revoked_hash which is revoked)
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Verify Revoked_hash is invalid
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            assert!(!registry::is_valid_hash(&registry, &Revoked_hash), 1);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = test_scenario::EEmptyInventory)]
    fun test_non_admin_cannot_register_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize registry (ADMIN gets the admin_cap)
        {
            registry::init_for_testing(test_scenario::ctx(&mut scenario));
        };
        
        // Alice (non-admin) tries to register a hash
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            // Alice tries to take admin_cap but doesn't have it!
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            let document_hash = b"alice_unauthorized_hash";
            
            registry::register_hash(&mut registry, &admin_cap, document_hash, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = test_scenario::EEmptyInventory)]
    fun test_non_admin_cannot_revoke_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Alice tries to revoke the hash
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            // Alice tries to take admin_cap but doesn't have it!
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::revoke_hash(&mut registry, &admin_cap, Verified_hash);
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = test_scenario::EEmptyInventory)]
    fun test_non_admin_cannot_unrevoke_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Admin revokes first
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::revoke_hash(&mut registry, &admin_cap, Verified_hash);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };
        
        // Alice tries to unrevoke the hash
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            // Alice tries to take admin_cap but doesn't have it!
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::unrevoke_hash(&mut registry, &admin_cap, Verified_hash);
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_HASH_ALREADY_USED)]
    fun test_ltc1_cannot_use_same_hash_twice() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // mark_hash_used first time (Success)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            // In unit tests, we can generate IDs from addresses
            let id1 = object::id_from_address(@0x101);
            
            registry::mark_hash_used(&mut registry, Verified_hash, id1);
            
            test_scenario::return_shared(registry);
        };
        
        // mark_hash_used second time (Fail)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            let id2 = object::id_from_address(@0x102);
            
            // This should abort with E_HASH_ALREADY_USED
            registry::mark_hash_used(&mut registry, Verified_hash, id2);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = registry::E_HASH_NOT_APPROVED)]
    fun test_ltc1_cannot_use_unapproved_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Try to use unverified hash
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let id = object::id_from_address(@0x103);
            
            // This should abort with E_HASH_NOT_APPROVED
            registry::mark_hash_used(&mut registry, Unverified_hash, id);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    #[test]
    #[expected_failure(abort_code = registry::E_HASH_REVOKED)]
    fun test_ltc1_cannot_use_revoked_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Try to use revoked hash
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let id = object::id_from_address(@0x104);
            
            // This should abort with E_HASH_REVOKED
            registry::mark_hash_used(&mut registry, Revoked_hash, id);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
}
